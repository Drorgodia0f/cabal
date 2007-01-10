module Network.Hackage.Client where

import Network.URI (URI,parseURI,uriScheme,uriPath)
import Distribution.Package
import Distribution.PackageDescription
import Distribution.Version
import Data.Version
import Data.Maybe
import Text.ParserCombinators.ReadP
import Distribution.ParseUtils
import Network.Hackage.CabalInstall.Types
import Network.Hackage.CabalInstall.Fetch (readURI,packagesDirectory)

import Data.List (isSuffixOf)
import Data.Tree (Forest(..), Tree(..), flatten)
import System.Directory (getDirectoryContents, doesDirectoryExist, doesFileExist)
import System.IO.Unsafe (unsafeInterleaveIO)

type PathName = String

-- XXX remove
-- data Pkg = Pkg String [String] String
--     deriving (Show, Read)

getPkgDescription :: String -> PackageIdentifier -> IO (Maybe String)
getPkgDescription url pkgId = do
    fmap Just ( getFrom url (pathOf pkgId "cabal") )

getPkgDescriptions :: String -> [PackageIdentifier] -> IO [Maybe String]
getPkgDescriptions url pkgIds = mapM (getPkgDescription url) pkgIds

getDependencies :: String -> [Dependency] -> IO [(Dependency, Maybe ResolvedDependency)]
getDependencies _ _ = fail "getDependencies unimplemented" -- remote url "getDependencies"

-- Scans the packages directory recursively collecting informations from all the .cabal files found.
listPackages :: ConfigFlags -> String -> IO [PkgInfo]
listPackages cfg url = do
    dirTree <- lazyDirTree (packagesDirectory cfg)
    let cabalFiles = filter (".cabal" `isSuffixOf`) (concatMap flatten dirTree)
    pkgs <- mapM readPackageDescription cabalFiles
    return (map parsePkg pkgs)
    where lazyDirTree :: FilePath -> IO (Forest FilePath)
          lazyDirTree dir = unsafeInterleaveIO $ do
                              entries <- getDirectoryContents dir
                              sequence [ do let filePath = dir ++ "/" ++ entry
                                            isDirectory <- doesDirectoryExist filePath
                                            if isDirectory
                                              then do entries <- lazyDirTree filePath
                                                      return Node {
                                                          rootLabel = "",
                                                          subForest = entries
                                                        }
                                              else return Node {
                                                       rootLabel = filePath,
                                                       subForest = []
                                                     }
                                       | entry <- entries
                                       , entry /= "."
                                       , entry /= ".." ]
          parsePkg :: PackageDescription -> PkgInfo
          parsePkg pkgDescription = PkgInfo
              { infoId        = package pkgDescription
              , infoDeps      = buildDepends pkgDescription
              , infoSynopsis  = synopsis pkgDescription
              , infoURL       = pkgURL
              }
              where
                pkgURL  = url ++ "/" ++ pathOf (package pkgDescription) "tar.gz"

{-
listPackages url = do
    x    <- getFrom url "00-latest.txt" -- remote url "listPackages"
    pkgs <- readIO x
    return $ map parsePkg pkgs
    where
    parsePkg :: Pkg -> PkgInfo
    parsePkg (Pkg ident deps pkgSynopsis) = PkgInfo
        { infoId        = pkgId
        , infoDeps      = pkgDeps
        , infoSynopsis  = pkgSynopsis
        , infoURL       = pkgURL
        }
        where
        pkgId   = parseWith parsePackageId ident
        pkgDeps = map (parseWith parseDependency) deps
        pkgURL  = url ++ "/" ++ pathOf pkgId "tar.gz"
-}

pathOf :: PackageIdentifier -> String -> PathName
pathOf pkgId ext = concat [pkgName pkgId, "/", showPackageId pkgId, ".", ext]

parseWith :: Show a => ReadP a -> String -> a
parseWith f s = case reverse (readP_to_S f s) of
    ((x, _):_) -> x
    _          -> error s

-- XXX - check for existence?
getPkgLocation :: String -> PackageIdentifier -> IO (Maybe String)
getPkgLocation url pkgId = return . Just $ url ++ "/" ++ pathOf pkgId "tar.gz"

getServerVersion :: String -> IO Version
getServerVersion url = fail "getServerVersion not implemented" -- remote url "getServerVersion"

getFrom :: String -> String -> IO String
getFrom base path = case parseURI uri of
    Just parsed -> readURI parsed
    Nothing -> fail $ "Failed to parse url: " ++ show uri
    where
    uri = base ++ "/" ++ path

{-
isCompatible :: String -> IO Bool
isCompatible = fmap ((==) clientVersion) . getServerVersion
-}
