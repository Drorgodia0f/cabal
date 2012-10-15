-----------------------------------------------------------------------------
-- |
-- Module      :  Distribution.Client.PackageEnvironment
-- Maintainer  :  cabal-devel@haskell.org
-- Portability :  portable
--
-- Utilities for working with the package environment file. Patterned after
-- Distribution.Client.Config.
-----------------------------------------------------------------------------

module Distribution.Client.PackageEnvironment (
    PackageEnvironment(..)
  , loadOrCreatePackageEnvironment
  , tryLoadPackageEnvironment
  , readPackageEnvironmentFile
  , showPackageEnvironment
  , showPackageEnvironmentWithComments

  , basePackageEnvironment
  , initialPackageEnvironment
  , commentPackageEnvironment
  , defaultPackageEnvironmentFileName
  , userPackageEnvironmentFileName
  ) where

import Distribution.Client.Config      ( SavedConfig(..), commentSavedConfig,
                                         initialSavedConfig, loadConfig,
                                         configFieldDescriptions,
                                         installDirsFields, defaultCompiler )
import Distribution.Client.ParseUtils  ( parseFields, ppFields, ppSection )
import Distribution.Client.Setup       ( GlobalFlags(..), ConfigExFlags(..)
                                       , InstallFlags(..) )
import Distribution.Simple.Compiler    ( Compiler, PackageDB(..)
                                         , showCompilerId )
import Distribution.Simple.InstallDirs ( InstallDirs(..), PathTemplate,
                                         toPathTemplate )
import Distribution.Simple.Setup       ( Flag(..), ConfigFlags(..),
                                         fromFlagOrDefault, toFlag )
import Distribution.Simple.Utils       ( die, notice, warn, lowercase )
import Distribution.ParseUtils         ( FieldDescr(..), ParseResult(..),
                                         commaListField,
                                         liftField, lineNo, locatedErrorMsg,
                                         parseFilePathQ, readFields,
                                         showPWarning, simpleField, warning )
import Distribution.Verbosity          ( Verbosity, normal )
import Control.Monad                   ( foldM, when )
import Data.List                       ( partition )
import Data.Monoid                     ( Monoid(..) )
import Distribution.Compat.Exception   ( catchIO )
import System.Directory                ( renameFile )
import System.FilePath                 ( (<.>), (</>) )
import System.IO.Error                 ( isDoesNotExistError )
import Text.PrettyPrint                ( ($+$) )

import qualified Text.PrettyPrint          as Disp
import qualified Distribution.Compat.ReadP as Parse
import qualified Distribution.ParseUtils   as ParseUtils ( Field(..) )
import qualified Distribution.Text         as Text


--
-- * Configuration saved in the package environment file
--

-- TODO: would be nice to remove duplication between D.C.PackageEnvironment and
-- D.C.Config.
data PackageEnvironment = PackageEnvironment {
  pkgEnvInherit       :: Flag FilePath,
  pkgEnvSavedConfig   :: SavedConfig
}

instance Monoid PackageEnvironment where
  mempty = PackageEnvironment {
    pkgEnvInherit       = mempty,
    pkgEnvSavedConfig   = mempty
    }

  mappend a b = PackageEnvironment {
    pkgEnvInherit       = combine pkgEnvInherit,
    pkgEnvSavedConfig   = combine pkgEnvSavedConfig
    }
    where
      combine f = f a `mappend` f b

-- | The automatically-created package environment file that should not be
-- touched by the user.
defaultPackageEnvironmentFileName :: FilePath
defaultPackageEnvironmentFileName = "cabal.sandbox.config"

-- | Optional package environment file that can be used to customize the default
-- settings. Created by the user.
userPackageEnvironmentFileName :: FilePath
userPackageEnvironmentFileName = "cabal.config"

-- | Defaults common to 'initialPackageEnvironment' and
-- 'commentPackageEnvironment'.
commonPackageEnvironmentConfig :: FilePath -> SavedConfig
commonPackageEnvironmentConfig pkgEnvDir =
  mempty {
    savedConfigureFlags = mempty {
       configUserInstall = toFlag False,
       configInstallDirs = sandboxInstallDirs
       },
    savedUserInstallDirs   = sandboxInstallDirs,
    savedGlobalInstallDirs = sandboxInstallDirs,
    savedGlobalFlags = mempty {
      globalLogsDir = toFlag $ pkgEnvDir </> "logs",
      -- Is this right? cabal-dev uses the global world file.
      globalWorldFile = toFlag $ pkgEnvDir </> "world"
      }
    }
  where
    sandboxInstallDirs = mempty { prefix = toFlag (toPathTemplate pkgEnvDir) }

-- | These are the absolute basic defaults, the fields that must be
-- initialised. When we load the package environment from the file we layer the
-- loaded values over these ones.
basePackageEnvironment :: FilePath -> PackageEnvironment
basePackageEnvironment pkgEnvDir = do
  let baseConf = commonPackageEnvironmentConfig pkgEnvDir in
    mempty {
      pkgEnvSavedConfig = baseConf {
         savedConfigureFlags = (savedConfigureFlags baseConf) {
            configHcFlavor    = toFlag defaultCompiler,
            configVerbosity   = toFlag normal
            }
         }
      }

-- | Initial configuration that we write out to the package environment file if
-- it does not exist. When the package environment gets loaded this
-- configuration gets layered on top of 'basePackageEnvironment'.
initialPackageEnvironment :: FilePath -> Compiler -> IO PackageEnvironment
initialPackageEnvironment pkgEnvDir compiler = do
  initialConf' <- initialSavedConfig
  let baseConf =  commonPackageEnvironmentConfig pkgEnvDir
  let initialConf = initialConf' `mappend` baseConf
  return $ mempty {
    pkgEnvSavedConfig = initialConf {
       savedGlobalFlags = (savedGlobalFlags initialConf) {
          globalLocalRepos = [pkgEnvDir </> "packages"]
          },
       savedConfigureFlags = setPackageDB pkgEnvDir compiler
                             (savedConfigureFlags initialConf),
       savedInstallFlags = (savedInstallFlags initialConf) {
         installSummaryFile = [toPathTemplate (pkgEnvDir </>
                                               "logs" </> "build.log")]
         }
       }
    }

-- | Use the package DB location specific for this compiler.
setPackageDB :: FilePath -> Compiler -> ConfigFlags -> ConfigFlags
setPackageDB pkgEnvDir compiler configFlags =
  configFlags {
    configPackageDBs = [Just (SpecificPackageDB $ pkgEnvDir
                              </> (showCompilerId compiler ++
                                   "-packages.conf.d"))]
    }

-- | Default values that get used if no value is given. Used here to include in
-- comments when we write out the initial package environment.
commentPackageEnvironment :: FilePath -> IO PackageEnvironment
commentPackageEnvironment pkgEnvDir = do
  commentConf  <- commentSavedConfig
  let baseConf =  commonPackageEnvironmentConfig pkgEnvDir
  return $ mempty {
    pkgEnvSavedConfig = commentConf `mappend` baseConf
    }

-- | Given a package environment, layer it on top of the base package
-- environment.
addBasePkgEnv :: Verbosity -> FilePath -> PackageEnvironment
                 -> IO PackageEnvironment
addBasePkgEnv verbosity pkgEnvDir extra = do
  let base     = basePackageEnvironment pkgEnvDir
      baseConf = pkgEnvSavedConfig base
  -- Does this package environment inherit from some config file?
  case pkgEnvInherit extra of
    NoFlag          ->
      return $ base `mappend` extra
    (Flag confPath) -> do
      conf <- loadConfig verbosity (Flag confPath) NoFlag
      let conf' = baseConf `mappend` conf `mappend` (pkgEnvSavedConfig extra)
      return $ extra { pkgEnvSavedConfig = conf' }

-- | Given a package environment, layer it on top of the user package
-- environment (the one loaded from the optional "cabal.config" file).
addUserPkgEnv :: Verbosity -> FilePath -> PackageEnvironment
                 -> IO PackageEnvironment
addUserPkgEnv verbosity pkgEnvDir pkgEnv = do
  let path = pkgEnvDir </> userPackageEnvironmentFileName
  minp <- readPackageEnvironmentFile mempty path
  userPkgEnv <- case minp of
    Nothing -> return mempty
    Just (ParseOk warns parseResult) -> do
      when (not $ null warns) $ warn verbosity $
        unlines (map (showPWarning path) warns)
      return parseResult
    Just (ParseFailed err) -> do
      let (line, msg) = locatedErrorMsg err
      warn verbosity $ "Error parsing user package environment file " ++ path
        ++ maybe "" (\n -> ":" ++ show n) line ++ ":\n" ++ msg
      return mempty
  return $ userPkgEnv `mappend` pkgEnv

-- | Try to load a package environment file, exiting with error if it doesn't
-- exist.
tryLoadPackageEnvironment :: Verbosity -> FilePath -> IO PackageEnvironment
tryLoadPackageEnvironment verbosity pkgEnvDir = do
  let path = pkgEnvDir </> defaultPackageEnvironmentFileName
  minp <- readPackageEnvironmentFile mempty path
  pkgEnv <- case minp of
    Nothing -> die $
      "The package environment file '" ++ path ++ "' doesn't exist"
    Just (ParseOk warns parseResult) -> do
      when (not $ null warns) $ warn verbosity $
        unlines (map (showPWarning path) warns)
      return parseResult
    Just (ParseFailed err) -> do
      let (line, msg) = locatedErrorMsg err
      die $ "Error parsing package environment file " ++ path
        ++ maybe "" (\n -> ":" ++ show n) line ++ ":\n" ++ msg
  pkgEnv' <- addUserPkgEnv verbosity pkgEnvDir pkgEnv
  addBasePkgEnv verbosity pkgEnvDir pkgEnv'

-- | Load a package environment file, creating one if it doesn't exist. Note
-- that the path parameter should be a name of an existing directory.
loadOrCreatePackageEnvironment :: Verbosity -> FilePath
                                  -> ConfigFlags -> Compiler
                                  -> IO PackageEnvironment
loadOrCreatePackageEnvironment verbosity pkgEnvDir configFlags compiler = do
  let path = pkgEnvDir </> defaultPackageEnvironmentFileName
  minp <- readPackageEnvironmentFile mempty path
  pkgEnv <- case minp of
    Nothing -> do
      notice verbosity $ "Writing default package environment to " ++ path
      commentPkgEnv <- commentPackageEnvironment pkgEnvDir
      initialPkgEnv <- initialPackageEnvironment pkgEnvDir compiler
      let pkgEnv = updateConfigFlags initialPkgEnv
                   (\flags -> flags `mappend` configFlags)
      writePackageEnvironmentFile path commentPkgEnv pkgEnv
      return initialPkgEnv
    Just (ParseOk warns parseResult) -> do
      when (not $ null warns) $ warn verbosity $
        unlines (map (showPWarning path) warns)

      -- Update the package environment file in case the user has changed some
      -- settings via the command-line (otherwise 'configure -w compiler-B' will
      -- fail for a sandbox already configured to use compiler-A).
      notice verbosity $ "Writing the updated package environment to " ++ path
      commentPkgEnv <- commentPackageEnvironment pkgEnvDir
      let pkgEnv = updateConfigFlags parseResult
                   (\flags ->
                     setPackageDB pkgEnvDir compiler flags
                     `mappend` configFlags)
      writePackageEnvironmentFile path commentPkgEnv pkgEnv

      return pkgEnv
    Just (ParseFailed err) -> do
      let (line, msg) = locatedErrorMsg err
      warn verbosity $
        "Error parsing package environment file " ++ path
        ++ maybe "" (\n -> ":" ++ show n) line ++ ":\n" ++ msg
      warn verbosity $ "Using default package environment."
      initialPackageEnvironment pkgEnvDir compiler
  pkgEnv' <- addUserPkgEnv verbosity pkgEnvDir pkgEnv
  addBasePkgEnv verbosity pkgEnvDir pkgEnv'

  where
    updateConfigFlags :: PackageEnvironment -> (ConfigFlags -> ConfigFlags)
                         -> PackageEnvironment
    updateConfigFlags pkgEnv f =
      let pkgEnvConfig      = pkgEnvSavedConfig pkgEnv
          pkgEnvConfigFlags = savedConfigureFlags pkgEnvConfig
      in pkgEnv {
        pkgEnvSavedConfig = pkgEnvConfig {
           savedConfigureFlags = f pkgEnvConfigFlags
           }
        }

-- | Descriptions of all fields in the package environment file.
pkgEnvFieldDescrs :: [FieldDescr PackageEnvironment]
pkgEnvFieldDescrs = [
  simpleField "inherit"
    (fromFlagOrDefault Disp.empty . fmap Disp.text) (optional parseFilePathQ)
    pkgEnvInherit (\v pkgEnv -> pkgEnv { pkgEnvInherit = v })

    -- FIXME: Should we make these fields part of ~/.cabal/config ?
  , commaListField "constraints"
    Text.disp Text.parse
    (configExConstraints . savedConfigureExFlags . pkgEnvSavedConfig)
    (\v pkgEnv -> updateConfigureExFlags pkgEnv
                  (\flags -> flags { configExConstraints = v }))

  , commaListField "preferences"
    Text.disp Text.parse
    (configPreferences . savedConfigureExFlags . pkgEnvSavedConfig)
    (\v pkgEnv -> updateConfigureExFlags pkgEnv
                  (\flags -> flags { configPreferences = v }))
  ]
  ++ map toPkgEnv configFieldDescriptions'
  where
    optional = Parse.option mempty . fmap toFlag

    configFieldDescriptions' :: [FieldDescr SavedConfig]
    configFieldDescriptions' = filter
      (\(FieldDescr name _ _) -> name /= "preference" && name /= "constraint")
      configFieldDescriptions

    toPkgEnv :: FieldDescr SavedConfig -> FieldDescr PackageEnvironment
    toPkgEnv fieldDescr =
      liftField pkgEnvSavedConfig
      (\savedConfig pkgEnv -> pkgEnv { pkgEnvSavedConfig = savedConfig})
      fieldDescr

    updateConfigureExFlags :: PackageEnvironment
                              -> (ConfigExFlags -> ConfigExFlags)
                              -> PackageEnvironment
    updateConfigureExFlags pkgEnv f = pkgEnv {
      pkgEnvSavedConfig = (pkgEnvSavedConfig pkgEnv) {
         savedConfigureExFlags = f . savedConfigureExFlags . pkgEnvSavedConfig
                                 $ pkgEnv
         }
      }

-- | Read the package environment file.
readPackageEnvironmentFile :: PackageEnvironment -> FilePath
                              -> IO (Maybe (ParseResult PackageEnvironment))
readPackageEnvironmentFile initial file =
  handleNotExists $
  fmap (Just . parsePackageEnvironment initial) (readFile file)
  where
    handleNotExists action = catchIO action $ \ioe ->
      if isDoesNotExistError ioe
        then return Nothing
        else ioError ioe

-- | Parse the package environment file.
parsePackageEnvironment :: PackageEnvironment -> String
                           -> ParseResult PackageEnvironment
parsePackageEnvironment initial str = do
  fields <- readFields str
  let (knownSections, others) = partition isKnownSection fields
  pkgEnv <- parse others
  let config       = pkgEnvSavedConfig pkgEnv
      installDirs0 = savedUserInstallDirs config
  -- 'install-dirs' is the only section that we care about.
  installDirs <- foldM parseSection installDirs0 knownSections
  return pkgEnv {
    pkgEnvSavedConfig = config {
       savedUserInstallDirs   = installDirs,
       savedGlobalInstallDirs = installDirs
       }
    }

  where
    isKnownSection :: ParseUtils.Field -> Bool
    isKnownSection (ParseUtils.Section _ "install-dirs" _ _) = True
    isKnownSection _                                         = False

    parse :: [ParseUtils.Field] -> ParseResult PackageEnvironment
    parse = parseFields pkgEnvFieldDescrs initial

    parseSection :: InstallDirs (Flag PathTemplate)
                    -> ParseUtils.Field
                    -> ParseResult (InstallDirs (Flag PathTemplate))
    parseSection accum (ParseUtils.Section _ "install-dirs" name fs)
      | name' == "" = do accum' <- parseFields installDirsFields accum fs
                         return accum'
      | otherwise   = do warning "The install-dirs section should be unnamed"
                         return accum
      where name' = lowercase name
    parseSection accum f = do
      warning $ "Unrecognized stanza on line " ++ show (lineNo f)
      return accum

-- | Write out the package environment file.
writePackageEnvironmentFile :: FilePath -> PackageEnvironment
                               -> PackageEnvironment -> IO ()
writePackageEnvironmentFile path comments pkgEnv = do
  let tmpPath = (path <.> "tmp")
  writeFile tmpPath $ explanation
    ++ showPackageEnvironmentWithComments comments pkgEnv ++ "\n"
  renameFile tmpPath path
  where
    explanation = unlines
      ["-- This is a Cabal package environment file."
      ,"-- THIS FILE IS AUTO-GENERATED. DO NOT EDIT DIRECTLY."
      ,"-- Please create a 'cabal.config' file in the same directory"
      ,"-- if you want to change the default settings for this sandbox."
      ,""
      ,"-- The available configuration options are listed below."
      ,"-- Some of them have default values listed."
      ,""
      ,"-- Lines (like this one) beginning with '--' are comments."
      ,"-- Be careful with spaces and indentation because they are"
      ,"-- used to indicate layout for nested sections."
      ,"",""
      ]

-- | Pretty-print the package environment data.
showPackageEnvironment :: PackageEnvironment -> String
showPackageEnvironment = showPackageEnvironmentWithComments mempty

showPackageEnvironmentWithComments :: PackageEnvironment -> PackageEnvironment
                                      -> String
showPackageEnvironmentWithComments defPkgEnv pkgEnv = Disp.render $
      ppFields pkgEnvFieldDescrs defPkgEnv pkgEnv
  $+$ Disp.text ""
  $+$ ppSection "install-dirs" "" installDirsFields
                (field defPkgEnv) (field pkgEnv)
  where
    field = savedUserInstallDirs . pkgEnvSavedConfig
