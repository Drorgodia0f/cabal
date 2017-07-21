{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE RankNTypes #-}
-----------------------------------------------------------------------------
-- |
-- Module      :  Distribution.Simple.BuildPaths
-- Copyright   :  Isaac Jones 2003-2004,
--                Duncan Coutts 2008
-- License     :  BSD3
--
-- Maintainer  :  cabal-devel@haskell.org
-- Portability :  portable
--
-- A bunch of dirs, paths and file names used for intermediate build steps.
--

module Distribution.Simple.BuildPaths (
    defaultDistPref, srcPref,
    haddockDirName, hscolourPref, haddockPref,
    autogenModulesDir,
    autogenPackageModulesDir,
    autogenComponentModulesDir,

    autogenModuleName,
    autogenPathsModuleName,
    cppHeaderName,
    haddockName,

    mkLibName,
    mkProfLibName,
    mkSharedLibName,
    mkStaticLibName,
    
    exeExtension,
    objExtension,
    dllExtension,
    staticLibExtension,
    -- * Source files & build directories
    getSourceFiles, getLibSourceFiles, getExeSourceFiles,
    getFLibSourceFiles, exeBuildDir, flibBuildDir,
  ) where

import Prelude ()
import Distribution.Compat.Prelude

import Distribution.Types.ForeignLib
import Distribution.Types.UnqualComponentName (unUnqualComponentName)
import Distribution.Package
import Distribution.ModuleName as ModuleName
import Distribution.Compiler
import Distribution.PackageDescription
import Distribution.Simple.LocalBuildInfo
import Distribution.Simple.Setup
import Distribution.Text
import Distribution.System
import Distribution.Verbosity
import Distribution.Simple.Utils

import System.FilePath ((</>), (<.>), normalise)

-- ---------------------------------------------------------------------------
-- Build directories and files

srcPref :: FilePath -> FilePath
srcPref distPref = distPref </> "src"

hscolourPref :: HaddockTarget -> FilePath -> PackageDescription -> FilePath
hscolourPref = haddockPref

-- | This is the name of the directory in which the generated haddocks
-- should be stored. It does not include the @<dist>/doc/html@ prefix.
haddockDirName :: HaddockTarget -> PackageDescription -> FilePath
haddockDirName ForDevelopment = display . packageName
haddockDirName ForHackage = (++ "-docs") . display . packageId

-- | The directory to which generated haddock documentation should be written.
haddockPref :: HaddockTarget -> FilePath -> PackageDescription -> FilePath
haddockPref haddockTarget distPref pkg_descr
    = distPref </> "doc" </> "html" </> haddockDirName haddockTarget pkg_descr

-- | The directory in which we put auto-generated modules for EVERY
-- component in the package.  See deprecation notice.
{-# DEPRECATED autogenModulesDir "If you can, use 'autogenComponentModulesDir' instead, but if you really wanted package-global generated modules, use 'autogenPackageModulesDir'.  In Cabal 2.0, we avoid using autogenerated files which apply to all components, because the information you often want in these files, e.g., dependency information, is best specified per component, so that reconfiguring a different component (e.g., enabling tests) doesn't force the entire to be rebuilt.  'autogenPackageModulesDir' still provides a place to put files you want to apply to the entire package, but most users of 'autogenModulesDir' should seriously consider 'autogenComponentModulesDir' if you really wanted the module to apply to one component." #-}
autogenModulesDir :: LocalBuildInfo -> String
autogenModulesDir = autogenPackageModulesDir

-- | The directory in which we put auto-generated modules for EVERY
-- component in the package.
autogenPackageModulesDir :: LocalBuildInfo -> String
autogenPackageModulesDir lbi = buildDir lbi </> "global-autogen"

-- | The directory in which we put auto-generated modules for a
-- particular component.
autogenComponentModulesDir :: LocalBuildInfo -> ComponentLocalBuildInfo -> String
autogenComponentModulesDir lbi clbi = componentBuildDir lbi clbi </> "autogen"
-- NB: Look at 'checkForeignDeps' for where a simplified version of this
-- has been copy-pasted.

cppHeaderName :: String
cppHeaderName = "cabal_macros.h"

{-# DEPRECATED autogenModuleName "Use autogenPathsModuleName instead" #-}
-- |The name of the auto-generated module associated with a package
autogenModuleName :: PackageDescription -> ModuleName
autogenModuleName = autogenPathsModuleName

-- | The name of the auto-generated Paths_* module associated with a package
autogenPathsModuleName :: PackageDescription -> ModuleName
autogenPathsModuleName pkg_descr =
  ModuleName.fromString $
    "Paths_" ++ map fixchar (display (packageName pkg_descr))
  where fixchar '-' = '_'
        fixchar c   = c

haddockName :: PackageDescription -> FilePath
haddockName pkg_descr = display (packageName pkg_descr) <.> "haddock"

-- -----------------------------------------------------------------------------
-- Source File helper

getLibSourceFiles :: Verbosity
                     -> LocalBuildInfo
                     -> Library
                     -> ComponentLocalBuildInfo
                     -> IO [(ModuleName.ModuleName, FilePath)]
getLibSourceFiles verbosity lbi lib clbi = getSourceFiles verbosity searchpaths modules
  where
    bi               = libBuildInfo lib
    modules          = allLibModules lib clbi
    searchpaths      = componentBuildDir lbi clbi : hsSourceDirs bi ++
                     [ autogenComponentModulesDir lbi clbi
                     , autogenPackageModulesDir lbi ]

getExeSourceFiles :: Verbosity
                     -> LocalBuildInfo
                     -> Executable
                     -> ComponentLocalBuildInfo
                     -> IO [(ModuleName.ModuleName, FilePath)]
getExeSourceFiles verbosity lbi exe clbi = do
    moduleFiles <- getSourceFiles verbosity searchpaths modules
    srcMainPath <- findFile (hsSourceDirs bi) (modulePath exe)
    return ((ModuleName.main, srcMainPath) : moduleFiles)
  where
    bi          = buildInfo exe
    modules     = otherModules bi
    searchpaths = autogenComponentModulesDir lbi clbi
                : autogenPackageModulesDir lbi
                : exeBuildDir lbi exe : hsSourceDirs bi

getFLibSourceFiles :: Verbosity
                   -> LocalBuildInfo
                   -> ForeignLib
                   -> ComponentLocalBuildInfo
                   -> IO [(ModuleName.ModuleName, FilePath)]
getFLibSourceFiles verbosity lbi flib clbi = getSourceFiles verbosity searchpaths modules
  where
    bi          = foreignLibBuildInfo flib
    modules     = otherModules bi
    searchpaths = autogenComponentModulesDir lbi clbi
                : autogenPackageModulesDir lbi
                : flibBuildDir lbi flib : hsSourceDirs bi

getSourceFiles :: Verbosity -> [FilePath]
                  -> [ModuleName.ModuleName]
                  -> IO [(ModuleName.ModuleName, FilePath)]
getSourceFiles verbosity dirs modules = flip traverse modules $ \m -> fmap ((,) m) $
    findFileWithExtension ["hs", "lhs", "hsig", "lhsig"] dirs (ModuleName.toFilePath m)
      >>= maybe (notFound m) (return . normalise)
  where
    notFound module_ = die' verbosity $ "can't find source for module " ++ display module_

-- | The directory where we put build results for an executable
exeBuildDir :: LocalBuildInfo -> Executable -> FilePath
exeBuildDir lbi exe = buildDir lbi </> nm </> nm ++ "-tmp"
  where
    nm = unUnqualComponentName $ exeName exe

-- | The directory where we put build results for a foreign library
flibBuildDir :: LocalBuildInfo -> ForeignLib -> FilePath
flibBuildDir lbi flib = buildDir lbi </> nm </> nm ++ "-tmp"
  where
    nm = unUnqualComponentName $ foreignLibName flib

-- ---------------------------------------------------------------------------
-- Library file names

-- TODO: Should this use staticLibExtension?
mkLibName :: UnitId -> String
mkLibName lib = "lib" ++ getHSLibraryName lib <.> "a"

-- TODO: Should this use staticLibExtension?
mkProfLibName :: UnitId -> String
mkProfLibName lib =  "lib" ++ getHSLibraryName lib ++ "_p" <.> "a"

-- Implement proper name mangling for dynamical shared objects
-- libHS<packagename>-<compilerFlavour><compilerVersion>
-- e.g. libHSbase-2.1-ghc6.6.1.so
mkSharedLibName :: CompilerId -> UnitId -> String
mkSharedLibName (CompilerId compilerFlavor compilerVersion) lib
  = "lib" ++ getHSLibraryName lib ++ "-" ++ comp <.> dllExtension
  where comp = display compilerFlavor ++ display compilerVersion

mkStaticLibName :: CompilerId -> UnitId -> String
mkStaticLibName (CompilerId compilerFlavor compilerVersion) lib
  = "lib" ++ getHSLibraryName lib ++ "-" ++ comp <.> staticLibExtension
  where comp = display compilerFlavor ++ display compilerVersion

-- ------------------------------------------------------------
-- * Platform file extensions
-- ------------------------------------------------------------

-- | Default extension for executable files on the current platform.
-- (typically @\"\"@ on Unix and @\"exe\"@ on Windows or OS\/2)
exeExtension :: String
exeExtension = case buildOS of
                   Windows -> "exe"
                   _       -> ""

-- | Extension for object files. For GHC the extension is @\"o\"@.
objExtension :: String
objExtension = "o"

-- | Extension for dynamically linked (or shared) libraries
-- (typically @\"so\"@ on Unix and @\"dll\"@ on Windows)
dllExtension :: String
dllExtension = case buildOS of
                   Windows -> "dll"
                   OSX     -> "dylib"
                   _       -> "so"

-- | Extension for static libraries
--
-- TODO: Here, as well as in dllExtension, it's really the target OS that we're
-- interested in, not the build OS.
staticLibExtension :: String
staticLibExtension = case buildOS of
                       Windows -> "lib"
                       _       -> "a"
