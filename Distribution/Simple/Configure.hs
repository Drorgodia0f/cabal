-----------------------------------------------------------------------------
-- |
-- Module      :  Distribution.Simple.Configure
-- Copyright   :  Isaac Jones 2003-2005
--
-- Maintainer  :  cabal-devel@haskell.org
-- Portability :  portable
--
-- This deals with the /configure/ phase. It provides the 'configure' action
-- which is given the package description and configure flags. It then tries
-- to: configure the compiler; resolves any conditionals in the package
-- description; resolve the package dependencies; check if all the extensions
-- used by this package are supported by the compiler; check that all the build
-- tools are available (including version checks if appropriate); checks for
-- any required @pkg-config@ packages (updating the 'BuildInfo' with the
-- results)
-- 
-- Then based on all this it saves the info in the 'LocalBuildInfo' and writes
-- it out to the @dist\/setup-config@ file. It also displays various details to
-- the user, the amount of information displayed depending on the verbosity
-- level.

{- All rights reserved.

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

module Distribution.Simple.Configure (configure,
                                      writePersistBuildConfig,
                                      getPersistBuildConfig,
                                      checkPersistBuildConfig,
                                      maybeGetPersistBuildConfig,
--                                      getConfiguredPkgDescr,
                                      localBuildInfoFile,
                                      getInstalledPackages,
                                      configDependency,
                                      configCompiler, configCompilerAux,
                                      ccLdOptionsBuildInfo,
                                      tryGetConfigStateFile,
                                      checkForeignDeps,
                                     )
    where

import Distribution.Simple.Compiler
    ( CompilerFlavor(..), Compiler(compilerId), compilerFlavor, compilerVersion
    , showCompilerId, unsupportedExtensions, PackageDB(..), PackageDBStack )
import Distribution.Package
    ( PackageName(PackageName), PackageId, PackageIdentifier(PackageIdentifier)
    , packageName, packageVersion, Package(..)
    , Dependency(Dependency), simplifyDependency )
import Distribution.InstalledPackageInfo
    ( InstalledPackageInfo, emptyInstalledPackageInfo )
import qualified Distribution.InstalledPackageInfo as Installed
    ( InstalledPackageInfo_(..) )
import qualified Distribution.Simple.PackageIndex as PackageIndex
import Distribution.Simple.PackageIndex (PackageIndex)
import Distribution.PackageDescription as PD
    ( PackageDescription(..), GenericPackageDescription(..)
    , Library(..), hasLibs, Executable(..), BuildInfo(..)
    , HookedBuildInfo, updatePackageDescription, allBuildInfo
    , FlagName(..) )
import Distribution.PackageDescription.Configuration
    ( finalizePackageDescription )
import Distribution.PackageDescription.Check
    ( PackageCheck(..), checkPackage, checkPackageFiles )
import Distribution.Simple.Program
    ( Program(..), ProgramLocation(..), ConfiguredProgram(..)
    , ProgramConfiguration, defaultProgramConfiguration
    , configureAllKnownPrograms, knownPrograms, lookupKnownProgram
    , userSpecifyArgss, userSpecifyPaths
    , lookupProgram, requireProgram, requireProgramVersion
    , pkgConfigProgram, gccProgram, rawSystemProgramStdoutConf )
import Distribution.Simple.Setup
    ( ConfigFlags(..), CopyDest(..), fromFlag, fromFlagOrDefault, flagToMaybe )
import Distribution.Simple.InstallDirs
    ( InstallDirs(..), defaultInstallDirs, combineInstallDirs )
import Distribution.Simple.LocalBuildInfo
    ( LocalBuildInfo(..), ComponentLocalBuildInfo(..)
    , absoluteInstallDirs, prefixRelativeInstallDirs, isInternalPackage )
import Distribution.Simple.Utils
    ( die, warn, info, setupMessage, createDirectoryIfMissingVerbose
    , intercalate, comparing, cabalVersion, cabalBootstrapping
    , withFileContents, writeFileAtomic 
    , withTempFile )
import Distribution.System
    ( OS(..), buildOS, buildArch )
import Distribution.Version
    ( Version(..), anyVersion, orLaterVersion, withinRange
    , isSpecificVersion, isAnyVersion
    , LowerBound(..), asVersionIntervals, simplifyVersionRange )
import Distribution.Verbosity
    ( Verbosity, lessVerbose )

import qualified Distribution.Simple.GHC  as GHC
import qualified Distribution.Simple.JHC  as JHC
import qualified Distribution.Simple.LHC  as LHC
import qualified Distribution.Simple.NHC  as NHC
import qualified Distribution.Simple.Hugs as Hugs

import Control.Monad
    ( when, unless, foldM, filterM )
import Data.List
    ( nub, partition, isPrefixOf, maximumBy, inits )
import Data.Maybe
    ( fromMaybe, isNothing )
import Data.Monoid
    ( Monoid(..) )
import System.Directory
    ( doesFileExist, getModificationTime, createDirectoryIfMissing, getTemporaryDirectory )
import System.Exit
    ( ExitCode(..), exitWith )
import System.FilePath
    ( (</>), isAbsolute )
import qualified System.Info
    ( compilerName, compilerVersion )
import System.IO
    ( hPutStrLn, stderr, hClose )
import Distribution.Text
    ( Text(disp), display, simpleParse )
import Text.PrettyPrint.HughesPJ
    ( comma, punctuate, render, nest, sep )
import Distribution.Compat.Exception ( catchExit, catchIO )

import Prelude hiding (catch)

tryGetConfigStateFile :: (Read a) => FilePath -> IO (Either String a)
tryGetConfigStateFile filename = do
  exists <- doesFileExist filename
  if not exists
    then return (Left missing)
    else withFileContents filename $ \str ->
      case lines str of
        [headder, rest] -> case checkHeader headder of
          Just msg -> return (Left msg)
          Nothing  -> case reads rest of
            [(bi,_)] -> return (Right bi)
            _        -> return (Left cantParse)
        _            -> return (Left cantParse)
  where
    checkHeader :: String -> Maybe String
    checkHeader header = case parseHeader header of
      Just (cabalId, compId)
        | cabalId
       == currentCabalId -> Nothing
        | otherwise      -> Just (badVersion cabalId compId)
      Nothing            -> Just cantParse

    missing   = "Run the 'configure' command first."
    cantParse = "Saved package config file seems to be corrupt. "
             ++ "Try re-running the 'configure' command."
    badVersion cabalId compId
              = "You need to re-run the 'configure' command. "
             ++ "The version of Cabal being used has changed (was "
             ++ display cabalId ++ ", now "
             ++ display currentCabalId ++ ")."
             ++ badcompiler compId
    badcompiler compId | compId == currentCompilerId = ""
                       | otherwise
              = " Additionally the compiler is different (was "
             ++ display compId ++ ", now "
             ++ display currentCompilerId
             ++ ") which is probably the cause of the problem."

-- internal function
tryGetPersistBuildConfig :: FilePath -> IO (Either String LocalBuildInfo)
tryGetPersistBuildConfig distPref
    = tryGetConfigStateFile (localBuildInfoFile distPref)

-- |Read the 'localBuildInfoFile'.  Error if it doesn't exist.  Also
-- fail if the file containing LocalBuildInfo is older than the .cabal
-- file, indicating that a re-configure is required.
getPersistBuildConfig :: FilePath -> IO LocalBuildInfo
getPersistBuildConfig distPref = do
  lbi <- tryGetPersistBuildConfig distPref
  either die return lbi

-- |Try to read the 'localBuildInfoFile'.
maybeGetPersistBuildConfig :: FilePath -> IO (Maybe LocalBuildInfo)
maybeGetPersistBuildConfig distPref = do
  lbi <- tryGetPersistBuildConfig distPref
  return $ either (const Nothing) Just lbi

-- |After running configure, output the 'LocalBuildInfo' to the
-- 'localBuildInfoFile'.
writePersistBuildConfig :: FilePath -> LocalBuildInfo -> IO ()
writePersistBuildConfig distPref lbi = do
  createDirectoryIfMissing False distPref
  writeFileAtomic (localBuildInfoFile distPref)
                  (showHeader pkgid ++ '\n' : show lbi)
  where
    pkgid   = packageId (localPkgDescr lbi)

showHeader :: PackageIdentifier -> String
showHeader pkgid =
     "Saved package config for " ++ display pkgid
  ++ " written by " ++ display currentCabalId
  ++      " using " ++ display currentCompilerId
  where

currentCabalId :: PackageIdentifier
currentCabalId = PackageIdentifier (PackageName "Cabal") currentVersion
  where currentVersion | cabalBootstrapping = Version [0] []
                       | otherwise          = cabalVersion

currentCompilerId :: PackageIdentifier
currentCompilerId = PackageIdentifier (PackageName System.Info.compilerName)
                                      System.Info.compilerVersion

parseHeader :: String -> Maybe (PackageIdentifier, PackageIdentifier)
parseHeader header = case words header of
  ["Saved", "package", "config", "for", pkgid,
   "written", "by", cabalid, "using", compilerid]
    -> case (simpleParse pkgid :: Maybe PackageIdentifier,
             simpleParse cabalid,
             simpleParse compilerid) of
        (Just _,
         Just cabalid',
         Just compilerid') -> Just (cabalid', compilerid')
        _                  -> Nothing
  _                        -> Nothing

-- |Check that localBuildInfoFile is up-to-date with respect to the
-- .cabal file.
checkPersistBuildConfig :: FilePath -> FilePath -> IO ()
checkPersistBuildConfig distPref pkg_descr_file = do
  t0 <- getModificationTime pkg_descr_file
  t1 <- getModificationTime $ localBuildInfoFile distPref
  when (t0 > t1) $
    die (pkg_descr_file ++ " has been changed, please re-configure.")

-- |@dist\/setup-config@
localBuildInfoFile :: FilePath -> FilePath
localBuildInfoFile distPref = distPref </> "setup-config"

-- -----------------------------------------------------------------------------
-- * Configuration
-- -----------------------------------------------------------------------------

-- |Perform the \"@.\/setup configure@\" action.
-- Returns the @.setup-config@ file.
configure :: (GenericPackageDescription, HookedBuildInfo)
          -> ConfigFlags -> IO LocalBuildInfo
configure (pkg_descr0, pbi) cfg
  = do  let distPref = fromFlag (configDistPref cfg)
            verbosity = fromFlag (configVerbosity cfg)

        setupMessage verbosity "Configuring" (packageId pkg_descr0)

        createDirectoryIfMissingVerbose (lessVerbose verbosity) True distPref

        let programsConfig = userSpecifyArgss (configProgramArgs cfg)
                           . userSpecifyPaths (configProgramPaths cfg)
                           $ configPrograms cfg
            userInstall = fromFlag (configUserInstall cfg)
            packageDbs = implicitPackageDbStack userInstall
                           (flagToMaybe $ configPackageDB cfg)

        -- detect compiler
        (comp, programsConfig') <- configCompiler
          (flagToMaybe $ configHcFlavor cfg)
          (flagToMaybe $ configHcPath cfg) (flagToMaybe $ configHcPkg cfg)
          programsConfig (lessVerbose verbosity)
        let version = compilerVersion comp
            flavor  = compilerFlavor comp

        -- Create a PackageIndex that makes *any libraries that might be*
        -- defined internally to this package look like installed packages, in
        -- case an executable should refer to any of them as dependencies.
        --
        -- It must be *any libraries that might be* defined rather than the
        -- actual definitions, because these depend on conditionals in the .cabal
        -- file, and we haven't resolved them yet.  finalizePackageDescription
        -- does the resolution of conditionals, and it takes internalPackageSet
        -- as part of its input.
        --
        -- Currently a package can define no more than one library (which has
        -- the same name as the package) but we could extend this later.
        -- If we later allowed private internal libraries, then here we would
        -- need to pre-scan the conditional data to make a list of all private
        -- libraries that could possibly be defined by the .cabal file.
        let internalPackageSet = PackageIndex.fromList [ emptyInstalledPackageInfo {
                  Installed.package = packageId pkg_descr0
              } ]
        maybeInstalledPackageSet <- getInstalledPackages (lessVerbose verbosity) comp
                                      packageDbs programsConfig'

        -- The merge of the internal and installed packages
        let maybePackageSet = fmap (PackageIndex.merge internalPackageSet) $
                              maybeInstalledPackageSet

        (pkg_descr0', flags) <-
                case finalizePackageDescription
                       (configConfigurationsFlags cfg)
                       maybePackageSet
                       Distribution.System.buildOS
                       Distribution.System.buildArch
                       (compilerId comp)
                       (configConstraints cfg)
                       pkg_descr0
                of Right r -> return r
                   Left missing ->
                       die $ "At least the following dependencies are missing:\n"
                         ++ (render . nest 4 . sep . punctuate comma)
                            [ disp (Dependency name range')
                            | Dependency name range <- missing
                            , let range' = simplifyVersionRange range ]

        -- add extra include/lib dirs as specified in cfg
        -- we do it here so that those get checked too
        let pkg_descr = addExtraIncludeLibDirs pkg_descr0'

        when (not (null flags)) $
          info verbosity $ "Flags chosen: "
                        ++ intercalate ", " [ name ++ "=" ++ display value
                                            | (FlagName name, value) <- flags ]

        checkPackageProblems verbosity pkg_descr0
          (updatePackageDescription pbi pkg_descr)

        let installedPackageSet = fromMaybe bogusPackageSet maybeInstalledPackageSet
            packageSet          = fromMaybe bogusPackageSet maybePackageSet
            -- FIXME: For Hugs, nhc98 and other compilers we do not know what
            -- packages are already installed, so we just make some up, pretend
            -- that they do exist and just hope for the best. We make them up
            -- based on what other package the package we're currently building
            -- happens to depend on. See 'inventBogusPackageId' below.
            -- Let's hope they really are installed... :-)
            bogusDependencies = map inventBogusPackageId (buildDepends pkg_descr)
            bogusPackageSet = PackageIndex.fromList
              [ emptyInstalledPackageInfo {
                  Installed.package = bogusPackageId
                  -- note that these bogus packages have no other dependencies
                }
              | bogusPackageId <- bogusDependencies ]

            configDependencies =
                 mapM (configDependency verbosity internalPackageSet
                       installedPackageSet) $
                 buildDepends pkg_descr

        allPkgDeps <- case flavor of
          GHC -> configDependencies
          JHC -> configDependencies
          LHC -> configDependencies
          _   -> return bogusDependencies

        let (internalPkgDeps, externalPkgDeps) = partition (isInternalPackage pkg_descr) allPkgDeps

        when (not (null internalPkgDeps) && not (newPackageDepsBehaviour pkg_descr)) $
            die $ "The field 'build-depends: "
               ++ intercalate ", " (map (display . packageName) internalPkgDeps)
               ++ "' refers to a library which is defined within the same "
               ++ "package. To use this feature the package must specify at "
               ++ "least 'cabal-version: >= 1.8'."

        packageDependsIndex <-
          case PackageIndex.dependencyClosure packageSet externalPkgDeps of
            Left packageDependsIndex -> return packageDependsIndex
            Right broken ->
              die $ "The following installed packages are broken because other"
                 ++ " packages they depend on are missing. These broken "
                 ++ "packages must be rebuilt before they can be used.\n"
                 ++ unlines [ "package "
                           ++ display (packageId pkg)
                           ++ " is broken due to missing package "
                           ++ intercalate ", " (map display deps)
                            | (pkg, deps) <- broken ]

        let pseudoTopPkg = emptyInstalledPackageInfo {
                Installed.package = packageId pkg_descr,
                Installed.depends = allPkgDeps
              }
        case PackageIndex.dependencyInconsistencies
           . PackageIndex.insert pseudoTopPkg
           $ packageDependsIndex of
          [] -> return ()
          inconsistencies ->
            warn verbosity $
                 "This package indirectly depends on multiple versions of the same "
              ++ "package. This is highly likely to cause a compile failure.\n"
              ++ unlines [ "package " ++ display pkg ++ " requires "
                        ++ display (PackageIdentifier name ver)
                         | (name, uses) <- inconsistencies
                         , (pkg, ver) <- uses ]

        -- installation directories
        defaultDirs <- defaultInstallDirs flavor userInstall (hasLibs pkg_descr)
        let installDirs = combineInstallDirs fromFlagOrDefault
                            defaultDirs (configInstallDirs cfg)

        -- check extensions
        let extlist = nub $ concatMap extensions (allBuildInfo pkg_descr)
        let exts = unsupportedExtensions comp extlist
        unless (null exts) $ warn verbosity $ -- Just warn, FIXME: Should this be an error?
            display flavor ++ " does not support the following extensions: " ++
            intercalate ", " (map display exts)

        let requiredBuildTools = concatMap buildTools (allBuildInfo pkg_descr)
        programsConfig'' <-
              configureAllKnownPrograms (lessVerbose verbosity) programsConfig'
          >>= configureRequiredPrograms verbosity requiredBuildTools

        (pkg_descr', programsConfig''') <- configurePkgconfigPackages verbosity
                                            pkg_descr programsConfig''

        split_objs <-
           if not (fromFlag $ configSplitObjs cfg)
                then return False
                else case flavor of
                            GHC | version >= Version [6,5] [] -> return True
                            _ -> do warn verbosity
                                         ("this compiler does not support " ++
                                          "--enable-split-objs; ignoring")
                                    return False

        -- The allPkgDeps contains all the package deps for the whole package
        -- but we need to select the subset for this specific component.
        -- we just take the subset for the package names this component
        -- needs. Note, this only works because we cannot yet depend on two
        -- versions of the same package.
        let configLib lib = configComponent (libBuildInfo lib)
            configExe exe = (exeName exe, configComponent(buildInfo exe))
            configComponent bi = ComponentLocalBuildInfo {
              componentPackageDeps =
                if newPackageDepsBehaviour pkg_descr'
                  then selectDependencies bi allPkgDeps
                  else allPkgDeps
            }
            selectDependencies :: BuildInfo -> [PackageId] -> [PackageId]
            selectDependencies bi pkgs =
                [ pkg | pkg <- pkgs, packageName pkg `elem` names ]
              where
                names = [ name | Dependency name _ <- targetBuildDepends bi ]

        let lbi = LocalBuildInfo{
                    installDirTemplates = installDirs,
                    compiler            = comp,
                    buildDir            = distPref </> "build",
                    scratchDir          = fromFlagOrDefault
                                            (distPref </> "scratch")
                                            (configScratchDir cfg),
                    libraryConfig       = configLib `fmap` library pkg_descr',
                    executableConfigs   = configExe `fmap` executables pkg_descr',
                    installedPkgs       = packageDependsIndex,
                    pkgDescrFile        = Nothing,
                    localPkgDescr       = pkg_descr',
                    withPrograms        = programsConfig''',
                    withVanillaLib      = fromFlag $ configVanillaLib cfg,
                    withProfLib         = fromFlag $ configProfLib cfg,
                    withSharedLib       = fromFlag $ configSharedLib cfg,
                    withProfExe         = fromFlag $ configProfExe cfg,
                    withOptimization    = fromFlag $ configOptimization cfg,
                    withGHCiLib         = fromFlag $ configGHCiLib cfg,
                    splitObjs           = split_objs,
                    stripExes           = fromFlag $ configStripExes cfg,
                    withPackageDB       = packageDbs,
                    progPrefix          = fromFlag $ configProgPrefix cfg,
                    progSuffix          = fromFlag $ configProgSuffix cfg
                  }

        let dirs = absoluteInstallDirs pkg_descr lbi NoCopyDest
            relative = prefixRelativeInstallDirs (packageId pkg_descr) lbi

        unless (isAbsolute (prefix dirs)) $ die $
            "expected an absolute directory name for --prefix: " ++ prefix dirs

        info verbosity $ "Using " ++ display currentCabalId
                      ++ " compiled by " ++ display currentCompilerId
        info verbosity $ "Using compiler: " ++ showCompilerId comp
        info verbosity $ "Using install prefix: " ++ prefix dirs

        let dirinfo name dir isPrefixRelative =
              info verbosity $ name ++ " installed in: " ++ dir ++ relNote
              where relNote = case buildOS of
                      Windows | not (hasLibs pkg_descr)
                             && isNothing isPrefixRelative
                             -> "  (fixed location)"
                      _      -> ""

        dirinfo "Binaries"         (bindir dirs)     (bindir relative)
        dirinfo "Libraries"        (libdir dirs)     (libdir relative)
        dirinfo "Private binaries" (libexecdir dirs) (libexecdir relative)
        dirinfo "Data files"       (datadir dirs)    (datadir relative)
        dirinfo "Documentation"    (docdir dirs)     (docdir relative)

        sequence_ [ reportProgram verbosity prog configuredProg
                  | (prog, configuredProg) <- knownPrograms programsConfig''' ]

        return lbi

    where
      addExtraIncludeLibDirs pkg_descr =
          let extraBi = mempty { extraLibDirs = configExtraLibDirs cfg
                               , PD.includeDirs = configExtraIncludeDirs cfg}
              modifyLib l        = l{ libBuildInfo = libBuildInfo l `mappend` extraBi }
              modifyExecutable e = e{ buildInfo    = buildInfo e    `mappend` extraBi}
          in pkg_descr{ library     = modifyLib        `fmap` library pkg_descr
                      , executables = modifyExecutable  `map` executables pkg_descr}


-- -----------------------------------------------------------------------------
-- Configuring package dependencies

-- |Converts build dependencies to a versioned dependency.  only sets
-- version information for exact versioned dependencies.
inventBogusPackageId :: Dependency -> PackageIdentifier
inventBogusPackageId (Dependency s vr) = case isSpecificVersion vr of
  -- if they specify the exact version, use that:
  Just v -> PackageIdentifier s v
  -- otherwise, just set it to empty
  Nothing -> PackageIdentifier s (Version [] [])

reportProgram :: Verbosity -> Program -> Maybe ConfiguredProgram -> IO ()
reportProgram verbosity prog Nothing
    = info verbosity $ "No " ++ programName prog ++ " found"
reportProgram verbosity prog (Just configuredProg)
    = info verbosity $ "Using " ++ programName prog ++ version ++ location
    where location = case programLocation configuredProg of
            FoundOnSystem p -> " found on system at: " ++ p
            UserSpecified p -> " given by user at: " ++ p
          version = case programVersion configuredProg of
            Nothing -> ""
            Just v  -> " version " ++ display v

hackageUrl :: String
hackageUrl = "http://hackage.haskell.org/cgi-bin/hackage-scripts/package/"

-- | Test for a package dependency and record the version we have installed.
configDependency :: Verbosity
                 -> PackageIndex InstalledPackageInfo  -- ^ Internally defined packages
                 -> PackageIndex InstalledPackageInfo  -- ^ Installed packages
                 -> Dependency
                 -> IO PackageIdentifier
configDependency verbosity internalIndex installedIndex dep@(Dependency pkgname _) =
  -- If the dependency specification matches anything in the internal package
  -- index, then we prefer that match to anything in the second.
  -- For example:
  --
  -- Name: MyLibrary
  -- Version: 0.1
  -- Library
  --     ..
  -- Executable my-exec
  --     build-depends: MyLibrary
  --
  -- We want "build-depends: MyLibrary" always to match the internal library
  -- even if there is a newer installed library "MyLibrary-0.2".
  -- However, "build-depends: MyLibrary >= 0.2" should match the installed one.
  case PackageIndex.lookupDependency internalIndex dep
                       `inPreferenceTo`
                   PackageIndex.lookupDependency installedIndex dep of
        [] -> die $ "cannot satisfy dependency "
                      ++ display (simplifyDependency dep) ++ "\n"
                      ++ "Perhaps you need to download and install it from\n"
                      ++ hackageUrl ++ display pkgname ++ "?"
        pkgs -> do let pkgid = maximumBy (comparing packageVersion) (map packageId pkgs)
                   info verbosity $ "Dependency "
                                 ++ display (simplifyDependency dep)
                                ++ ": using " ++ display pkgid
                   return pkgid
  where
    -- If there are any matches in the first set, return them, otherwise return
    -- the second set.
    inPreferenceTo :: [a] -> [a] -> [a]
    inPreferenceTo [] second = second
    inPreferenceTo first _   = first

getInstalledPackages :: Verbosity -> Compiler
                     -> PackageDBStack -> ProgramConfiguration
                     -> IO (Maybe (PackageIndex InstalledPackageInfo))
getInstalledPackages verbosity comp packageDBs progconf = do
  info verbosity "Reading installed packages..."
  case compilerFlavor comp of
    GHC -> Just `fmap` GHC.getInstalledPackages verbosity packageDBs progconf
    JHC -> Just `fmap` JHC.getInstalledPackages verbosity packageDBs progconf
    LHC -> Just `fmap` LHC.getInstalledPackages verbosity packageDBs progconf
    _   -> return Nothing

-- | Currently the user interface specifies the package dbs to use with just a
-- single valued option, a 'PackageDB'. However internally we represent the
-- stack of 'PackageDB's explictly as a list. This function converts encodes
-- the package db stack implicit in a single packagedb.
--
implicitPackageDbStack :: Bool -> Maybe PackageDB -> PackageDBStack
implicitPackageDbStack userInstall maybePackageDB
  | userInstall = GlobalPackageDB : UserPackageDB : extra
  | otherwise   = GlobalPackageDB : extra
  where
    extra = case maybePackageDB of
      Just (SpecificPackageDB db) -> [SpecificPackageDB db]
      _                           -> []

newPackageDepsBehaviourMinVersion :: Version
newPackageDepsBehaviourMinVersion = Version { versionBranch = [1,7,1], versionTags = [] }

-- In older cabal versions, there was only one set of package dependencies for
-- the whole package. In this version, we can have separate dependencies per
-- target, but we only enable this behaviour if the minimum cabal version
-- specified is >= a certain minimum. Otherwise, for compatibility we use the
-- old behaviour.
newPackageDepsBehaviour :: PackageDescription -> Bool
newPackageDepsBehaviour pkg_descr =
   minVersionRequired >= newPackageDepsBehaviourMinVersion
  where
    minVersionRequired =
      case asVersionIntervals (descCabalVersion pkg_descr) of
        []                      -> Version [0] []
        ((LowerBound v _, _):_) -> v

-- -----------------------------------------------------------------------------
-- Configuring program dependencies

configureRequiredPrograms :: Verbosity -> [Dependency] -> ProgramConfiguration -> IO ProgramConfiguration
configureRequiredPrograms verbosity deps conf =
  foldM (configureRequiredProgram verbosity) conf deps

configureRequiredProgram :: Verbosity -> ProgramConfiguration -> Dependency -> IO ProgramConfiguration
configureRequiredProgram verbosity conf (Dependency (PackageName progName) verRange) =
  case lookupKnownProgram progName conf of
    Nothing -> die ("Unknown build tool " ++ progName)
    Just prog
      -- requireProgramVersion always requires the program have a version
      -- but if the user says "build-depends: foo" ie no version constraint
      -- then we should not fail if we cannot discover the program version.
      | verRange == anyVersion -> do
          (_, conf') <- requireProgram verbosity prog conf
          return conf'
      | otherwise -> do
          (_, _, conf') <- requireProgramVersion verbosity prog verRange conf
          return conf'

-- -----------------------------------------------------------------------------
-- Configuring pkg-config package dependencies

configurePkgconfigPackages :: Verbosity -> PackageDescription
                           -> ProgramConfiguration
                           -> IO (PackageDescription, ProgramConfiguration)
configurePkgconfigPackages verbosity pkg_descr conf
  | null allpkgs = return (pkg_descr, conf)
  | otherwise    = do
    (_, _, conf') <- requireProgramVersion
                       (lessVerbose verbosity) pkgConfigProgram
                       (orLaterVersion $ Version [0,9,0] []) conf
    mapM_ requirePkg allpkgs
    lib'  <- updateLibrary (library pkg_descr)
    exes' <- mapM updateExecutable (executables pkg_descr)
    let pkg_descr' = pkg_descr { library = lib', executables = exes' }
    return (pkg_descr', conf')

  where
    allpkgs = concatMap pkgconfigDepends (allBuildInfo pkg_descr)
    pkgconfig = rawSystemProgramStdoutConf (lessVerbose verbosity)
                  pkgConfigProgram conf

    requirePkg dep@(Dependency (PackageName pkg) range) = do
      version <- pkgconfig ["--modversion", pkg]
                 `catchIO`   (\_ -> die notFound)
                 `catchExit` (\_ -> die notFound)
      case simpleParse version of
        Nothing -> die "parsing output of pkg-config --modversion failed"
        Just v | not (withinRange v range) -> die (badVersion v)
               | otherwise                 -> info verbosity (depSatisfied v)
      where
        notFound     = "The pkg-config package " ++ pkg ++ versionRequirement
                    ++ " is required but it could not be found."
        badVersion v = "The pkg-config package " ++ pkg ++ versionRequirement
                    ++ " is required but the version installed on the"
                    ++ " system is version " ++ display v
        depSatisfied v = "Dependency " ++ display dep
                      ++ ": using version " ++ display v

        versionRequirement
          | isAnyVersion range = ""
          | otherwise          = " version " ++ display range

    updateLibrary Nothing    = return Nothing
    updateLibrary (Just lib) = do
      bi <- pkgconfigBuildInfo (pkgconfigDepends (libBuildInfo lib))
      return $ Just lib { libBuildInfo = libBuildInfo lib `mappend` bi }

    updateExecutable exe = do
      bi <- pkgconfigBuildInfo (pkgconfigDepends (buildInfo exe))
      return exe { buildInfo = buildInfo exe `mappend` bi }

    pkgconfigBuildInfo :: [Dependency] -> IO BuildInfo
    pkgconfigBuildInfo []      = return mempty
    pkgconfigBuildInfo pkgdeps = do
      let pkgs = nub [ display pkg | Dependency pkg _ <- pkgdeps ]
      ccflags <- pkgconfig ("--cflags" : pkgs)
      ldflags <- pkgconfig ("--libs"   : pkgs)
      return (ccLdOptionsBuildInfo (words ccflags) (words ldflags))

-- | Makes a 'BuildInfo' from C compiler and linker flags.
--
-- This can be used with the output from configuration programs like pkg-config
-- and similar package-specific programs like mysql-config, freealut-config etc.
-- For example:
--
-- > ccflags <- rawSystemProgramStdoutConf verbosity prog conf ["--cflags"]
-- > ldflags <- rawSystemProgramStdoutConf verbosity prog conf ["--libs"]
-- > return (ccldOptionsBuildInfo (words ccflags) (words ldflags))
--
ccLdOptionsBuildInfo :: [String] -> [String] -> BuildInfo
ccLdOptionsBuildInfo cflags ldflags =
  let (includeDirs',  cflags')   = partition ("-I" `isPrefixOf`) cflags
      (extraLibs',    ldflags')  = partition ("-l" `isPrefixOf`) ldflags
      (extraLibDirs', ldflags'') = partition ("-L" `isPrefixOf`) ldflags'
  in mempty {
       PD.includeDirs  = map (drop 2) includeDirs',
       PD.extraLibs    = map (drop 2) extraLibs',
       PD.extraLibDirs = map (drop 2) extraLibDirs',
       PD.ccOptions    = cflags',
       PD.ldOptions    = ldflags''
     }

-- -----------------------------------------------------------------------------
-- Determining the compiler details

configCompilerAux :: ConfigFlags -> IO (Compiler, ProgramConfiguration)
configCompilerAux cfg = configCompiler (flagToMaybe $ configHcFlavor cfg)
                                       (flagToMaybe $ configHcPath cfg)
                                       (flagToMaybe $ configHcPkg cfg)
                                       programsConfig
                                       (fromFlag (configVerbosity cfg))
  where
    programsConfig = userSpecifyArgss (configProgramArgs cfg)
                   . userSpecifyPaths (configProgramPaths cfg)
                   $ defaultProgramConfiguration

configCompiler :: Maybe CompilerFlavor -> Maybe FilePath -> Maybe FilePath
               -> ProgramConfiguration -> Verbosity
               -> IO (Compiler, ProgramConfiguration)
configCompiler Nothing _ _ _ _ = die "Unknown compiler"
configCompiler (Just hcFlavor) hcPath hcPkg conf verbosity = do
  case hcFlavor of
      GHC  -> GHC.configure  verbosity hcPath hcPkg conf
      JHC  -> JHC.configure  verbosity hcPath hcPkg conf
      LHC  -> do (_,ghcConf) <- GHC.configure  verbosity Nothing hcPkg conf
                 LHC.configure  verbosity hcPath Nothing ghcConf
      Hugs -> Hugs.configure verbosity hcPath hcPkg conf
      NHC  -> NHC.configure  verbosity hcPath hcPkg conf
      _    -> die "Unknown compiler"


checkForeignDeps :: PackageDescription -> LocalBuildInfo -> Verbosity -> IO ()
checkForeignDeps pkg lbi verbosity = do
  ifBuildsWith allHeaders (commonCcArgs ++ makeLdArgs allLibs) -- I'm feeling lucky
           (return ())
           (do missingLibs <- findMissingLibs
               missingHdr  <- findOffendingHdr
               explainErrors missingHdr missingLibs)
      where
        allHeaders = collectField PD.includes
        allLibs    = collectField PD.extraLibs

        ifBuildsWith headers args success failure = do
            ok <- builds (makeProgram headers) args
            if ok then success else failure

        -- NOTE: if some package-local header has errors,
        -- we will report that this header is missing.
        -- Maybe additional tests for local headers are needed
        -- for better diagnostics
        findOffendingHdr =
            ifBuildsWith allHeaders cppArgs
                         (return Nothing)
                         (go . tail . inits $ allHeaders)
            where
              go [] = return Nothing       -- cannot happen
              go (hdrs:hdrsInits) = do
                    ifBuildsWith hdrs cppArgs
                                 (go hdrsInits)
                                 (return . Just . last $ hdrs)

              cppArgs = "-c":commonCcArgs -- don't try to link

        findMissingLibs = ifBuildsWith [] (makeLdArgs allLibs)
                                       (return [])
                                       (filterM (fmap not . libExists) allLibs)

        libExists lib = builds (makeProgram []) (makeLdArgs [lib])

        commonCcArgs  = programArgs gccProg
                     ++ hcDefines (compiler lbi)
                     ++ [ "-I" ++ dir | dir <- collectField PD.includeDirs ]
                     ++ ["-I."]
                     ++ collectField PD.cppOptions
                     ++ collectField PD.ccOptions
                     ++ [ "-I" ++ dir
                        | dep <- deps
                        , dir <- Installed.includeDirs dep ]
                     ++ [ opt
                        | dep <- deps
                        , opt <- Installed.ccOptions dep ]

        commonLdArgs  = [ "-L" ++ dir | dir <- collectField PD.extraLibDirs ]
                     ++ collectField PD.ldOptions
                     --TODO: do we also need dependent packages' ld options?
        makeLdArgs libs = [ "-l"++lib | lib <- libs ] ++ commonLdArgs

        makeProgram hdrs = unlines $
                           [ "#include \""  ++ hdr ++ "\"" | hdr <- hdrs ] ++
                           ["int main(int argc, char** argv) { return 0; }"]

        collectField f = concatMap f allBi
        allBi = allBuildInfo pkg
        Just gccProg = lookupProgram  gccProgram (withPrograms lbi)
        deps = PackageIndex.topologicalOrder (installedPkgs lbi)

        builds program args = do
            tempDir <- getTemporaryDirectory
            withTempFile tempDir ".c" $ \cName cHnd ->
              withTempFile tempDir "" $ \oNname oHnd -> do
                hPutStrLn cHnd program
                hClose cHnd
                hClose oHnd
                _ <- rawSystemProgramStdoutConf verbosity
                  gccProgram (withPrograms lbi) (cName:"-o":oNname:args)
                return True
           `catchIO`   (\_ -> return False)
           `catchExit` (\_ -> return False)

        explainErrors Nothing [] = return ()
        explainErrors hdr libs   = die $ unlines $
             (if plural then "Missing dependencies on foreign libraries:"
                        else "Missing dependency on a foreign library:")
           : case hdr of
               Nothing -> []
               Just h  -> ["* Missing header file: " ++ h ]
          ++ case libs of
               []    -> []
               [lib] -> ["* Missing C library: " ++ lib]
               _     -> ["* Missing C libraries: " ++ intercalate ", " libs]
          ++ [if plural then messagePlural else messageSingular]
          where
            plural = length libs >= 2
            messageSingular =
                 "This problem can usually be solved by installing the system "
              ++ "package that provides this library (you may need the "
              ++ "\"-dev\" version). If the library is already installed "
              ++ "but in a non-standard location then you can use the flags "
              ++ "--extra-include-dirs= and --extra-lib-dirs= to specify "
              ++ "where it is."
            messagePlural =
                 "This problem can usually be solved by installing the system "
              ++ "packages that provide these libraries (you may need the "
              ++ "\"-dev\" versions). If the libraries are already installed "
              ++ "but in a non-standard location then you can use the flags "
              ++ "--extra-include-dirs= and --extra-lib-dirs= to specify "
              ++ "where they are."

        --FIXME: share this with the PreProcessor module
        hcDefines :: Compiler -> [String]
        hcDefines comp =
          case compilerFlavor comp of
            GHC  -> ["-D__GLASGOW_HASKELL__=" ++ versionInt version]
            JHC  -> ["-D__JHC__=" ++ versionInt version]
            NHC  -> ["-D__NHC__=" ++ versionInt version]
            Hugs -> ["-D__HUGS__"]
            _    -> []
          where
            version = compilerVersion comp
                      -- TODO: move this into the compiler abstraction
            -- FIXME: this forces GHC's crazy 4.8.2 -> 408 convention on all
            -- the other compilers. Check if that's really what they want.
            versionInt :: Version -> String
            versionInt (Version { versionBranch = [] }) = "1"
            versionInt (Version { versionBranch = [n] }) = show n
            versionInt (Version { versionBranch = n1:n2:_ })
              = -- 6.8.x -> 608
                -- 6.10.x -> 610
                let s1 = show n1
                    s2 = show n2
                    middle = case s2 of
                             _ : _ : _ -> ""
                             _         -> "0"
                in s1 ++ middle ++ s2

-- | Output package check warnings and errors. Exit if any errors.
checkPackageProblems :: Verbosity
                     -> GenericPackageDescription
                     -> PackageDescription
                     -> IO ()
checkPackageProblems verbosity gpkg pkg = do
  ioChecks      <- checkPackageFiles pkg "."
  let pureChecks = checkPackage gpkg (Just pkg)
      errors   = [ e | PackageBuildImpossible e <- pureChecks ++ ioChecks ]
      warnings = [ w | PackageBuildWarning    w <- pureChecks ++ ioChecks ]
  if null errors
    then mapM_ (warn verbosity) warnings
    else do mapM_ (hPutStrLn stderr . ("Error: " ++)) errors
            exitWith (ExitFailure 1)
