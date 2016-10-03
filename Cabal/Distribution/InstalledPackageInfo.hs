{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE TypeFamilies #-}

-----------------------------------------------------------------------------
-- |
-- Module      :  Distribution.InstalledPackageInfo
-- Copyright   :  (c) The University of Glasgow 2004
--
-- Maintainer  :  libraries@haskell.org
-- Portability :  portable
--
-- This is the information about an /installed/ package that
-- is communicated to the @ghc-pkg@ program in order to register
-- a package.  @ghc-pkg@ now consumes this package format (as of version
-- 6.4). This is specific to GHC at the moment.
--
-- The @.cabal@ file format is for describing a package that is not yet
-- installed. It has a lot of flexibility, like conditionals and dependency
-- ranges. As such, that format is not at all suitable for describing a package
-- that has already been built and installed. By the time we get to that stage,
-- we have resolved all conditionals and resolved dependency version
-- constraints to exact versions of dependent packages. So, this module defines
-- the 'InstalledPackageInfo' data structure that contains all the info we keep
-- about an installed package. There is a parser and pretty printer. The
-- textual format is rather simpler than the @.cabal@ format: there are no
-- sections, for example.

-- This module is meant to be local-only to Distribution...

module Distribution.InstalledPackageInfo (
        InstalledPackageInfo(..),
        installedComponentId,
        installedPackageId,
        ExposedModule(..),
        ParseResult(..), PError(..), PWarning,
        emptyInstalledPackageInfo,
        parseInstalledPackageInfo,
        showInstalledPackageInfo,
        showInstalledPackageInfoField,
        showSimpleInstalledPackageInfoField,
        fieldsInstalledPackageInfo,
  ) where

import Prelude ()
import Distribution.Compat.Prelude

import Distribution.ParseUtils
import Distribution.License
import Distribution.Package hiding (installedUnitId, installedPackageId)
import Distribution.Backpack
import qualified Distribution.Package as Package
import Distribution.ModuleName
import Distribution.Version
import Distribution.Text
import qualified Distribution.Compat.ReadP as Parse
import Distribution.Compat.Graph

import Text.PrettyPrint as Disp
import qualified Data.Char as Char
import qualified Data.Map as Map

-- -----------------------------------------------------------------------------
-- The InstalledPackageInfo type

-- For BC reasons, we continue to name this record an InstalledPackageInfo;
-- but it would more accurately be called an InstalledUnitInfo with Backpack
data InstalledPackageInfo
   = InstalledPackageInfo {
        -- these parts are exactly the same as PackageDescription
        sourcePackageId   :: PackageId,
        installedUnitId   :: UnitId,
        -- INVARIANT: if this package is definite, IndefModule's
        -- IndefUnitId directly records UnitId.  If it is
        -- indefinite, IndefModule is always an IndefModuleVar
        -- with the same ModuleName as the key.
        instantiatedWith  :: [(ModuleName, IndefModule)],
        compatPackageKey  :: String,
        license           :: License,
        copyright         :: String,
        maintainer        :: String,
        author            :: String,
        stability         :: String,
        homepage          :: String,
        pkgUrl            :: String,
        synopsis          :: String,
        description       :: String,
        category          :: String,
        -- these parts are required by an installed package only:
        abiHash           :: AbiHash,
        exposed           :: Bool,
        -- INVARIANT: if the package is definite, IndefModule's
        -- IndefUnitId directly records UnitId.
        exposedModules    :: [ExposedModule],
        hiddenModules     :: [ModuleName],
        trusted           :: Bool,
        importDirs        :: [FilePath],
        libraryDirs       :: [FilePath],
        dataDir           :: FilePath,
        hsLibraries       :: [String],
        extraLibraries    :: [String],
        extraGHCiLibraries:: [String],    -- overrides extraLibraries for GHCi
        includeDirs       :: [FilePath],
        includes          :: [String],
        -- INVARIANT: if the package is definite, UnitId is NOT
        -- a ComponentId of an indefinite package
        depends           :: [UnitId],
        ccOptions         :: [String],
        ldOptions         :: [String],
        frameworkDirs     :: [FilePath],
        frameworks        :: [String],
        haddockInterfaces :: [FilePath],
        haddockHTMLs      :: [FilePath],
        pkgRoot           :: Maybe FilePath
    }
    deriving (Eq, Generic, Read, Show)

installedComponentId :: InstalledPackageInfo -> ComponentId
installedComponentId ipi = unitIdComponentId (installedUnitId ipi)

{-# DEPRECATED installedPackageId "Use installedUnitId instead" #-}
-- | Backwards compatibility with Cabal pre-1.24.
-- This type synonym is slightly awful because in cabal-install
-- we define an 'InstalledPackageId' but it's a ComponentId,
-- not a UnitId!
installedPackageId :: InstalledPackageInfo -> UnitId
installedPackageId = installedUnitId

instance Binary InstalledPackageInfo

instance Package.Package InstalledPackageInfo where
   packageId = sourcePackageId

instance Package.HasUnitId InstalledPackageInfo where
   installedUnitId = installedUnitId

instance Package.PackageInstalled InstalledPackageInfo where
   installedDepends = depends

instance IsNode InstalledPackageInfo where
    type Key InstalledPackageInfo = UnitId
    nodeKey       = installedUnitId
    nodeNeighbors = depends

emptyInstalledPackageInfo :: InstalledPackageInfo
emptyInstalledPackageInfo
   = InstalledPackageInfo {
        sourcePackageId   = PackageIdentifier (mkPackageName "") nullVersion,
        installedUnitId   = mkUnitId "",
        instantiatedWith  = [],
        compatPackageKey  = "",
        license           = UnspecifiedLicense,
        copyright         = "",
        maintainer        = "",
        author            = "",
        stability         = "",
        homepage          = "",
        pkgUrl            = "",
        synopsis          = "",
        description       = "",
        category          = "",
        abiHash           = mkAbiHash "",
        exposed           = False,
        exposedModules    = [],
        hiddenModules     = [],
        trusted           = False,
        importDirs        = [],
        libraryDirs       = [],
        dataDir           = "",
        hsLibraries       = [],
        extraLibraries    = [],
        extraGHCiLibraries= [],
        includeDirs       = [],
        includes          = [],
        depends           = [],
        ccOptions         = [],
        ldOptions         = [],
        frameworkDirs     = [],
        frameworks        = [],
        haddockInterfaces = [],
        haddockHTMLs      = [],
        pkgRoot           = Nothing
    }

-- -----------------------------------------------------------------------------
-- Exposed modules

data ExposedModule
   = ExposedModule {
       exposedName      :: ModuleName,
       exposedReexport  :: Maybe IndefModule
     }
  deriving (Eq, Generic, Read, Show)

instance Text ExposedModule where
    disp (ExposedModule m reexport) =
        Disp.hsep [ disp m
                  , case reexport of
                     Just m' -> Disp.hsep [Disp.text "from", disp m']
                     Nothing -> Disp.empty
                  ]
    parse = do
        m <- parseModuleNameQ
        Parse.skipSpaces
        reexport <- Parse.option Nothing $ do
            _ <- Parse.string "from"
            Parse.skipSpaces
            fmap Just parse
        return (ExposedModule m reexport)

instance Binary ExposedModule

-- To maintain backwards-compatibility, we accept both comma/non-comma
-- separated variants of this field.  You SHOULD use the comma syntax if you
-- use any new functions, although actually it's unambiguous due to a quirk
-- of the fact that modules must start with capital letters.

showExposedModules :: [ExposedModule] -> Disp.Doc
showExposedModules xs
    | all isExposedModule xs = fsep (map disp xs)
    | otherwise = fsep (Disp.punctuate comma (map disp xs))
    where isExposedModule (ExposedModule _ Nothing) = True
          isExposedModule _ = False

parseExposedModules :: Parse.ReadP r [ExposedModule]
parseExposedModules = parseOptCommaList parse

-- -----------------------------------------------------------------------------
-- Parsing

parseInstalledPackageInfo :: String -> ParseResult InstalledPackageInfo
parseInstalledPackageInfo =
    parseFieldsFlat (fieldsInstalledPackageInfo ++ deprecatedFieldDescrs)
    emptyInstalledPackageInfo

-- -----------------------------------------------------------------------------
-- Pretty-printing

showInstalledPackageInfo :: InstalledPackageInfo -> String
showInstalledPackageInfo = showFields fieldsInstalledPackageInfo

showInstalledPackageInfoField :: String -> Maybe (InstalledPackageInfo -> String)
showInstalledPackageInfoField = showSingleNamedField fieldsInstalledPackageInfo

showSimpleInstalledPackageInfoField :: String -> Maybe (InstalledPackageInfo -> String)
showSimpleInstalledPackageInfoField = showSimpleSingleNamedField fieldsInstalledPackageInfo

dispCompatPackageKey :: String -> Doc
dispCompatPackageKey = text

parseCompatPackageKey :: Parse.ReadP r String
parseCompatPackageKey = Parse.munch1 uid_char
    where uid_char c = Char.isAlphaNum c || c `elem` "-_.=[],:<>+"

-- -----------------------------------------------------------------------------
-- Description of the fields, for parsing/printing

fieldsInstalledPackageInfo :: [FieldDescr InstalledPackageInfo]
fieldsInstalledPackageInfo = basicFieldDescrs ++ installedFieldDescrs

basicFieldDescrs :: [FieldDescr InstalledPackageInfo]
basicFieldDescrs =
 [ simpleField "name"
                           disp                   parsePackageNameQ
                           packageName            (\name pkg -> pkg{sourcePackageId=(sourcePackageId pkg){pkgName=name}})
 , simpleField "version"
                           disp                   parseOptVersion
                           packageVersion         (\ver pkg -> pkg{sourcePackageId=(sourcePackageId pkg){pkgVersion=ver}})
 , simpleField "id"
                           disp                   parse
                           installedUnitId             (\pk pkg -> pkg{installedUnitId=pk})
 , simpleField "instantiated-with"
        (dispIndefModuleSubst . Map.fromList)    (fmap Map.toList parseIndefModuleSubst)
        instantiatedWith   (\iw    pkg -> pkg{instantiatedWith=iw})
 , simpleField "key"
                           dispCompatPackageKey   parseCompatPackageKey
                           compatPackageKey       (\pk pkg -> pkg{compatPackageKey=pk})
 , simpleField "license"
                           disp                   parseLicenseQ
                           license                (\l pkg -> pkg{license=l})
 , simpleField "copyright"
                           showFreeText           parseFreeText
                           copyright              (\val pkg -> pkg{copyright=val})
 , simpleField "maintainer"
                           showFreeText           parseFreeText
                           maintainer             (\val pkg -> pkg{maintainer=val})
 , simpleField "stability"
                           showFreeText           parseFreeText
                           stability              (\val pkg -> pkg{stability=val})
 , simpleField "homepage"
                           showFreeText           parseFreeText
                           homepage               (\val pkg -> pkg{homepage=val})
 , simpleField "package-url"
                           showFreeText           parseFreeText
                           pkgUrl                 (\val pkg -> pkg{pkgUrl=val})
 , simpleField "synopsis"
                           showFreeText           parseFreeText
                           synopsis               (\val pkg -> pkg{synopsis=val})
 , simpleField "description"
                           showFreeText           parseFreeText
                           description            (\val pkg -> pkg{description=val})
 , simpleField "category"
                           showFreeText           parseFreeText
                           category               (\val pkg -> pkg{category=val})
 , simpleField "author"
                           showFreeText           parseFreeText
                           author                 (\val pkg -> pkg{author=val})
 ]

installedFieldDescrs :: [FieldDescr InstalledPackageInfo]
installedFieldDescrs = [
   boolField "exposed"
        exposed            (\val pkg -> pkg{exposed=val})
 , simpleField "exposed-modules"
        showExposedModules parseExposedModules
        exposedModules     (\xs    pkg -> pkg{exposedModules=xs})
 , listField   "hidden-modules"
        disp               parseModuleNameQ
        hiddenModules      (\xs    pkg -> pkg{hiddenModules=xs})
 , simpleField "abi"
        disp               parse
        abiHash            (\abi    pkg -> pkg{abiHash=abi})
 , boolField   "trusted"
        trusted            (\val pkg -> pkg{trusted=val})
 , listField   "import-dirs"
        showFilePath       parseFilePathQ
        importDirs         (\xs pkg -> pkg{importDirs=xs})
 , listField   "library-dirs"
        showFilePath       parseFilePathQ
        libraryDirs        (\xs pkg -> pkg{libraryDirs=xs})
 , simpleField "data-dir"
        showFilePath       (parseFilePathQ Parse.<++ return "")
        dataDir            (\val pkg -> pkg{dataDir=val})
 , listField   "hs-libraries"
        showFilePath       parseTokenQ
        hsLibraries        (\xs pkg -> pkg{hsLibraries=xs})
 , listField   "extra-libraries"
        showToken          parseTokenQ
        extraLibraries     (\xs pkg -> pkg{extraLibraries=xs})
 , listField   "extra-ghci-libraries"
        showToken          parseTokenQ
        extraGHCiLibraries (\xs pkg -> pkg{extraGHCiLibraries=xs})
 , listField   "include-dirs"
        showFilePath       parseFilePathQ
        includeDirs        (\xs pkg -> pkg{includeDirs=xs})
 , listField   "includes"
        showFilePath       parseFilePathQ
        includes           (\xs pkg -> pkg{includes=xs})
 , listField   "depends"
        disp               parse
        depends            (\xs pkg -> pkg{depends=xs})
 , listField   "cc-options"
        showToken          parseTokenQ
        ccOptions          (\path  pkg -> pkg{ccOptions=path})
 , listField   "ld-options"
        showToken          parseTokenQ
        ldOptions          (\path  pkg -> pkg{ldOptions=path})
 , listField   "framework-dirs"
        showFilePath       parseFilePathQ
        frameworkDirs      (\xs pkg -> pkg{frameworkDirs=xs})
 , listField   "frameworks"
        showToken          parseTokenQ
        frameworks         (\xs pkg -> pkg{frameworks=xs})
 , listField   "haddock-interfaces"
        showFilePath       parseFilePathQ
        haddockInterfaces  (\xs pkg -> pkg{haddockInterfaces=xs})
 , listField   "haddock-html"
        showFilePath       parseFilePathQ
        haddockHTMLs       (\xs pkg -> pkg{haddockHTMLs=xs})
 , simpleField "pkgroot"
        (const Disp.empty)        parseFilePathQ
        (fromMaybe "" . pkgRoot)  (\xs pkg -> pkg{pkgRoot=Just xs})
 ]

deprecatedFieldDescrs :: [FieldDescr InstalledPackageInfo]
deprecatedFieldDescrs = [
   listField   "hugs-options"
        showToken          parseTokenQ
        (const [])        (const id)
  ]
