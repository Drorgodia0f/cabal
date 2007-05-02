-----------------------------------------------------------------------------
-- |
-- Module      :  Distribution.PreProcess
-- 
-- Maintainer  :  Isaac Jones <ijones@syntaxpolice.org>
-- Stability   :  alpha
-- Portability :  portable
--
--
-- PreProcessors are programs or functions which input a filename and
-- output a Haskell file.  The general form of a preprocessor is input
-- Foo.pp and output Foo.hs (where /pp/ is a unique extension that
-- tells us which preprocessor to use eg. gc, ly, cpphs, x, y, etc.).
-- Once a PreProcessor has been added to Cabal, either here or with
-- 'Distribution.Simple.UserHooks', if Cabal finds a Foo.pp, it'll run the given
-- preprocessor which should output a Foo.hs.

{- Copyright (c) 2003-2005, Isaac Jones, Malcolm Wallace
All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are
met:

    * Redistributions of source code must retain the above copyright
      notice, this list of conditions and the following disclaimer.

    * Redistributions in binary form must reproduce the above
      copyright notice, this list of conditions and the following
      disclaimer in the documentation and/or other materials provided
      with the distribution.

    * Neither the name of Isaac Jones nor the names of other
      contributors may be used to endorse or promote products derived
      from this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
"AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE. -}

module Distribution.PreProcess (preprocessSources, knownSuffixHandlers,
                                ppSuffixes, PPSuffixHandler, PreProcessor,
                                runSimplePreProcessor,
                                removePreprocessed, removePreprocessedPackage,
                                ppCpp, ppCpp', ppGreenCard, ppC2hs, ppHsc2hs,
				ppHappy, ppAlex, ppUnlit
                               )
    where


import Distribution.Simple.Configure (haddockVersion)
import Distribution.PreProcess.Unlit(unlit)
import Distribution.PackageDescription (setupMessage, PackageDescription(..),
                                        BuildInfo(..), Executable(..), withExe,
					Library(..), withLib, libModules)
import Distribution.Compiler (CompilerFlavor(..), Compiler(..))
import Distribution.Simple.LocalBuildInfo (LocalBuildInfo(..))
import Distribution.Simple.Utils (rawSystemExit, die, dieWithLocation,
                                  moduleToFilePath, moduleToFilePath2)
import Distribution.Version (Version(..))
import Control.Monad (when, unless)
import Data.Maybe (fromMaybe)
import Data.List (nub)
import System.Directory (removeFile, getModificationTime)
import System.Info (os, arch)
import Distribution.Compat.FilePath
	(splitFileExt, joinFileName, joinFileExt, dirName)
import Distribution.Compat.Directory ( createDirectoryIfMissing )

-- |The interface to a preprocessor, which may be implemented using an
-- external program, but need not be.  The arguments are the name of
-- the input file, the name of the output file and a verbosity level.
-- Here is a simple example that merely prepends a comment to the given
-- source file:
--
-- > ppTestHandler :: PreProcessor
-- > ppTestHandler =
-- >   PreProcessor {
-- >     platformIndependent = True,
-- >     runPreProcessor = mkSimplePreProcessor $ \inFile outFile verbose ->
-- >       do when (verbose > 0) $
-- >            putStrLn (inFile++" has been preprocessed to "++outFile)
-- >          stuff <- readFile inFile
-- >          writeFile outFile ("-- preprocessed as a test\n\n" ++ stuff)
-- >          return ExitSuccess
--
-- We split the input and output file names into a base directory and the
-- rest of the file name. The input base dir is the path in the list of search
-- dirs that this file was found in. The output base dir is the build dir where
-- all the generated source files are put.
--
-- The reason for splitting it up this way is that some pre-processors don't
-- simply generate one output .hs file from one input file but have
-- dependencies on other genereated files (notably c2hs, where building one
-- .hs file may require reading other .chi files, and then compiling the .hs
-- file may require reading a generated .h file). In these cases the generated
-- files need to embed relative path names to each other (eg the generated .hs
-- file mentions the .h file in the FFI imports). This path must be relative to
-- the base directory where the genereated files are located, it cannot be
-- relative to the top level of the build tree because the compilers do not
-- look for .h files relative to there, ie we do not use "-I .", instead we use
-- "-I dist\/build" (or whatever dist dir has been set by the user)
--
-- Most pre-processors do not care of course, so mkSimplePreProcessor and
-- runSimplePreProcessor functions handle the simple case.
--
data PreProcessor = PreProcessor {

  -- Is the output of the pre-processor platform independent? eg happy output
  -- is portable haskell but c2hs's output is platform dependent.
  -- This matters since only platform independent generated code can be
  -- inlcuded into a source tarball.
  platformIndependent :: Bool,
                              
  -- TODO: deal with pre-processors that have implementaion dependent output
  --       eg alex and happy have --ghc flags. However we can't really inlcude
  --       ghc-specific code into supposedly portable source tarballs.

  runPreProcessor :: (FilePath, FilePath) -- Location of the source file relative to a base dir
                  -> (FilePath, FilePath) -- Output file name, relative to an output base dir
                  -> Int      -- verbosity
                  -> IO ()    -- Should exit if the preprocessor fails
  }

mkSimplePreProcessor :: (FilePath -> FilePath -> Int -> IO ())
                      -> (FilePath, FilePath)
                      -> (FilePath, FilePath) -> Int -> IO ()
mkSimplePreProcessor simplePP
  (inBaseDir, inRelativeFile)
  (outBaseDir, outRelativeFile) verbosity = simplePP inFile outFile verbosity
  where inFile  = inBaseDir  `joinFileName` inRelativeFile
        outFile = outBaseDir `joinFileName` outRelativeFile

runSimplePreProcessor :: PreProcessor -> FilePath -> FilePath -> Int -> IO ()
runSimplePreProcessor pp inFile outFile verbosity =
  runPreProcessor pp (".", inFile) (".", outFile) verbosity

-- |A preprocessor for turning non-Haskell files with the given extension
-- into plain Haskell source files.
type PPSuffixHandler
    = (String, BuildInfo -> LocalBuildInfo -> PreProcessor)

-- |Apply preprocessors to the sources from 'hsSourceDirs', to obtain
-- a Haskell source file for each module.
preprocessSources :: PackageDescription 
		  -> LocalBuildInfo 
		  -> Int                -- ^ verbose
                  -> [PPSuffixHandler]  -- ^ preprocessors to try
		  -> IO ()

preprocessSources pkg_descr lbi verbose handlers = do
    withLib pkg_descr () $ \ lib -> do
        setupMessage verbose "Preprocessing library" pkg_descr
        let bi = libBuildInfo lib
        let biHandlers = localHandlers bi
        sequence_ [ preprocessModule (hsSourceDirs bi) (buildDir lbi) modu
                                     verbose builtinSuffixes biHandlers
                  | modu <- libModules pkg_descr]
    unless (null (executables pkg_descr)) $
        setupMessage verbose "Preprocessing executables for" pkg_descr
    withExe pkg_descr $ \ theExe -> do
        let bi = buildInfo theExe
        let biHandlers = localHandlers bi
        sequence_ [ preprocessModule (nub $ (hsSourceDirs bi)
                                  ++ (maybe [] (hsSourceDirs . libBuildInfo) (library pkg_descr)))
                                     (buildDir lbi)
                                     modu verbose builtinSuffixes biHandlers
                  | modu <- otherModules bi]
  where hc = compilerFlavor (compiler lbi)
	builtinSuffixes
	  | hc == NHC = ["hs", "lhs", "gc"]
	  | otherwise = ["hs", "lhs"]
	localHandlers bi = [(ext, h bi lbi) | (ext, h) <- handlers]

-- |Find the first extension of the file that exists, and preprocess it
-- if required.
preprocessModule
    :: [FilePath]			-- ^source directories
    -> FilePath                         -- ^build directory
    -> String				-- ^module name
    -> Int				-- ^verbose
    -> [String]				-- ^builtin suffixes
    -> [(String, PreProcessor)]		-- ^possible preprocessors
    -> IO ()
preprocessModule searchLoc buildLoc modu verbose builtinSuffixes handlers = do
    -- look for files in the various source dirs with this module name
    -- and a file extension of a known preprocessor
    psrcFiles  <- moduleToFilePath2 searchLoc modu (map fst handlers)
    case psrcFiles of
        -- no preprocessor file exists, look for an ordinary source file
	[] -> do bsrcFiles  <- moduleToFilePath searchLoc modu builtinSuffixes
                 case bsrcFiles of
	          [] -> die ("can't find source for " ++ modu ++ " in " ++ show searchLoc)
	          _  -> return ()
        -- found a pre-processable file in one of the source dirs
        ((psrcLoc, psrcRelFile):_) -> do
            let (srcStem, ext) = splitFileExt psrcRelFile
                psrcFile = psrcLoc `joinFileName` psrcRelFile
	        pp = fromMaybe (error "Internal error in preProcess module: Just expected")
	                       (lookup ext handlers)
            -- Currently we put platform independent generated .hs files back
            -- into the source dirs and put platform dependent ones into the
            -- build dir. Really they should all go in the build dir, or at
            -- least not in the source dirs (which should be considred
            -- read-only), however for the moment we have no other way of
            -- tracking which files should be included in the source
            -- distribution tarball. Hopefully we can fix that soon.
            let destLoc = if platformIndependent pp
                            then psrcLoc
                            else buildLoc
            -- look for existing pre-processed source file in the dest dir to
            -- see if we really have to re-run the preprocessor.
	    ppsrcFiles <- moduleToFilePath [destLoc] modu builtinSuffixes
	    recomp <- case ppsrcFiles of
	                  [] -> return True
	                  (ppsrcFile:_) -> do
                              btime <- getModificationTime ppsrcFile
	                      ptime <- getModificationTime psrcFile
	                      return (btime < ptime)
	    when recomp $ do
              let destDir = destLoc `joinFileName` dirName srcStem
              createDirectoryIfMissing True destDir
              runPreProcessor pp
                 (psrcLoc, psrcRelFile)
                 (destLoc, srcStem `joinFileExt` "hs") verbose

removePreprocessedPackage :: PackageDescription
                          -> FilePath -- ^root of source tree (where to look for hsSources)
                          -> [String] -- ^suffixes
                          -> IO ()
removePreprocessedPackage  pkg_descr r suff
    = do withLib pkg_descr () (\lib -> do
                     let bi = libBuildInfo lib
                     removePreprocessed (map (joinFileName r) (hsSourceDirs bi)) (libModules pkg_descr) suff)
         withExe pkg_descr (\theExe -> do
                     let bi = buildInfo theExe
                     removePreprocessed (map (joinFileName r) (hsSourceDirs bi)) (otherModules bi) suff)

-- |Remove the preprocessed .hs files. (do we need to get some .lhs files too?)
removePreprocessed :: [FilePath] -- ^search Location
                   -> [String] -- ^Modules
                   -> [String] -- ^suffixes
                   -> IO ()
removePreprocessed searchLocs mods suffixesIn
    = mapM_ removePreprocessedModule mods
  where removePreprocessedModule m = do
	    -- collect related files
	    fs <- moduleToFilePath searchLocs m otherSuffixes
	    -- does M.hs also exist?
	    hs <- moduleToFilePath searchLocs m ["hs"]
	    unless (null fs) (mapM_ removeFile hs)
	otherSuffixes = filter (/= "hs") suffixesIn

-- ------------------------------------------------------------
-- * known preprocessors
-- ------------------------------------------------------------

ppGreenCard :: BuildInfo -> LocalBuildInfo -> PreProcessor
ppGreenCard = ppGreenCard' []

ppGreenCard' :: [String] -> BuildInfo -> LocalBuildInfo -> PreProcessor
ppGreenCard' inputArgs _ lbi
    = maybe (ppNone "greencard") pp (withGreencard lbi)
    where pp greencard =
            PreProcessor {
              platformIndependent = False,
              runPreProcessor = mkSimplePreProcessor $ \inFile outFile verbose ->
                rawSystemExit verbose greencard
                    (["-tffi", "-o" ++ outFile, inFile] ++ inputArgs)
            }

-- This one is useful for preprocessors that can't handle literate source.
-- We also need a way to chain preprocessors.
ppUnlit :: PreProcessor
ppUnlit =
  PreProcessor {
    platformIndependent = True,
    runPreProcessor = mkSimplePreProcessor $ \inFile outFile _verbose -> do
      contents <- readFile inFile
      writeFile outFile (unlit inFile contents)
  }

ppCpp :: BuildInfo -> LocalBuildInfo -> PreProcessor
ppCpp = ppCpp' []

ppCpp' :: [String] -> BuildInfo -> LocalBuildInfo -> PreProcessor
ppCpp' inputArgs bi lbi =
  case withCpphs lbi of
     Just path  -> PreProcessor {
                     platformIndependent = False,
                     runPreProcessor = mkSimplePreProcessor (use_cpphs path)
                   }
     Nothing | compilerFlavor hc == GHC 
                -> PreProcessor {
                     platformIndependent = False,
                     runPreProcessor = mkSimplePreProcessor use_ghc
                   }
     _otherwise -> ppNone "cpphs (or GHC)"
  where 
	hc = compiler lbi

	use_cpphs cpphs inFile outFile verbose
	  = rawSystemExit verbose cpphs cpphsArgs
	  where cpphsArgs = ("-O" ++ outFile) : inFile : "--noline" : "--strip"
				 : extraArgs

        extraArgs = sysDefines ++ cppOptions bi lbi ++ inputArgs

        sysDefines =
                ["-D" ++ os ++ "_" ++ loc ++ "_OS" | loc <- locations] ++
                ["-D" ++ arch ++ "_" ++ loc ++ "_ARCH" | loc <- locations]
        locations = ["BUILD", "HOST"]

	use_ghc inFile outFile verbose
	  = do p_p <- use_optP_P lbi
               rawSystemExit verbose (compilerPath hc) 
                   (["-E", "-cpp"] ++
                    -- This is a bit of an ugly hack. We're going to
                    -- unlit the file ourselves later on if appropriate,
                    -- so we need GHC not to unlit it now or it'll get
                    -- double-unlitted. In the future we might switch to
                    -- using cpphs --unlit instead.
                    ["-x", "hs"] ++
                    (if p_p then ["-optP-P"] else []) ++
                    ["-o", outFile, inFile] ++ extraArgs)

-- Haddock versions before 0.8 choke on #line and #file pragmas.  Those
-- pragmas are necessary for correct links when we preprocess.  So use
-- -optP-P only if the Haddock version is prior to 0.8.
use_optP_P :: LocalBuildInfo -> IO Bool
use_optP_P lbi = fmap (< Version [0,8] []) (haddockVersion lbi)

ppHsc2hs :: BuildInfo -> LocalBuildInfo -> PreProcessor
ppHsc2hs bi lbi
    = maybe (ppNone "hsc2hs") pp (withHsc2hs lbi)
  where pp n = standardPP n flags
        flags = hcDefines (compiler lbi)
             ++ map ("--cflag=" ++) (getCcFlags bi)
             ++ map ("--lflag=" ++) (getLdFlags bi)

-- XXX This should probably be in a utils place, and used more widely
getCcFlags :: BuildInfo -> [String]
getCcFlags bi = map ("-I" ++) (includeDirs bi)
             ++ ccOptions bi

-- XXX This should probably be in a utils place, and used more widely
getLdFlags :: BuildInfo -> [String]
getLdFlags bi = map ("-L" ++) (extraLibDirs bi)
             ++ map ("-l" ++) (extraLibs bi)
             ++ ldOptions bi

ppC2hs :: BuildInfo -> LocalBuildInfo -> PreProcessor
ppC2hs bi lbi = maybe (ppNone "c2hs") pp (withC2hs lbi)
  where
    pp name =
      PreProcessor {
        platformIndependent = False,
        runPreProcessor = \(inBaseDir, inRelativeFile)
                           (outBaseDir, outRelativeFile) verbosity ->
          rawSystemExit verbosity name $
               ["--include=" ++ dir | dir <- hsSourceDirs bi ]
            ++ ["--cppopts=" ++ opt | opt <- cppOptions bi lbi]
            ++ ["--output-dir=" ++ outBaseDir,
                "--output=" ++ outRelativeFile,
                inBaseDir `joinFileName` inRelativeFile]
      }

cppOptions :: BuildInfo -> LocalBuildInfo -> [String]
cppOptions bi lbi
    = hcDefines (compiler lbi) ++
            ["-I" ++ dir | dir <- includeDirs bi] ++
            [opt | opt@('-':c:_) <- ccOptions bi, c `elem` "DIU"]

hcDefines :: Compiler -> [String]
hcDefines Compiler { compilerFlavor=GHC, compilerVersion=version }
  = ["-D__GLASGOW_HASKELL__=" ++ versionInt version]
hcDefines Compiler { compilerFlavor=JHC, compilerVersion=version }
  = ["-D__JHC__=" ++ versionInt version]
hcDefines Compiler { compilerFlavor=NHC, compilerVersion=version }
  = ["-D__NHC__=" ++ versionInt version]
hcDefines Compiler { compilerFlavor=Hugs }
  = ["-D__HUGS__"]
hcDefines _ = []

versionInt :: Version -> String
versionInt (Version { versionBranch = [] }) = "1"
versionInt (Version { versionBranch = [n] }) = show n
versionInt (Version { versionBranch = n1:n2:_ })
  = show n1 ++ take 2 ('0' : show n2)

ppHappy :: BuildInfo -> LocalBuildInfo -> PreProcessor
ppHappy _ lbi
    = maybe (ppNone "happy") pp (withHappy lbi)
  where pp n = (standardPP n (hcFlags hc)) { platformIndependent = True }
        hc = compilerFlavor (compiler lbi)
	hcFlags GHC = ["-agc"]
	hcFlags _ = []

ppAlex :: BuildInfo -> LocalBuildInfo -> PreProcessor
ppAlex _ lbi
    = maybe (ppNone "alex") pp (withAlex lbi)
  where pp n = (standardPP n (hcFlags hc)) { platformIndependent = True }
        hc = compilerFlavor (compiler lbi)
	hcFlags GHC = ["-g"]
	hcFlags _ = []

standardPP :: String -> [String] -> PreProcessor
standardPP eName args =
  PreProcessor {
    platformIndependent = False,
    runPreProcessor = mkSimplePreProcessor $ \inFile outFile verbose ->
      rawSystemExit verbose eName (args ++ ["-o", outFile, inFile])
  }

ppNone :: String -> PreProcessor
ppNone name = 
  PreProcessor {
    platformIndependent = False,
    runPreProcessor = mkSimplePreProcessor $ \inFile _ _ ->
      dieWithLocation inFile Nothing $
        "no " ++ name ++ " preprocessor available"
  }

-- |Convenience function; get the suffixes of these preprocessors.
ppSuffixes :: [ PPSuffixHandler ] -> [String]
ppSuffixes = map fst

-- |Standard preprocessors: GreenCard, c2hs, hsc2hs, happy, alex and cpphs.
knownSuffixHandlers :: [ PPSuffixHandler ]
knownSuffixHandlers =
  [ ("gc",     ppGreenCard)
  , ("chs",    ppC2hs)
  , ("hsc",    ppHsc2hs)
  , ("x",      ppAlex)
  , ("y",      ppHappy)
  , ("ly",     ppHappy)
  , ("cpphs",  ppCpp)
  ]
