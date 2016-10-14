#!/usr/bin/env runhaskell

import Data.List                             (isPrefixOf, isSuffixOf, sort)
import Distribution.PackageDescription
import Distribution.PackageDescription.Parse (ParseResult (..), parsePackageDescription)
import Distribution.Verbosity                (silent)
import System.Environment                    (getArgs, getProgName)
import System.FilePath                       (takeExtension, takeFileName)
import System.Process                        (readProcess)

import qualified Distribution.ModuleName as ModuleName
import qualified System.IO               as IO

main' :: FilePath -> IO ()
main' fp = do
    -- Read cabal file, so we can determine test modules
    contents <- strictReadFile fp
    cabal <- case parsePackageDescription contents of
        ParseOk _ x      -> pure x
        ParseFailed errs -> fail (show errs)

    -- We skip some files
    let testModuleFiles = getOtherModulesFiles cabal
    let skipPredicates' = skipPredicates ++ map (==) testModuleFiles

    -- Read all files git knows about under tests/
    files0 <- lines <$> readProcess "git" ["ls-files", "tests"] ""

    -- Filter
    let files1 = filter (\f -> takeExtension f `elem` whitelistedExtensionss ||
                               takeFileName f `elem` whitelistedFiles)
                        files0
    let files2 = filter (\f -> not $ any ($ dropTestsDir f) skipPredicates') files1
    let files3 = sort files2
    let files = files3

    -- Read current file
    let inputLines  = lines contents
        linesBefore = takeWhile (/= topLine) inputLines
        linesAfter  = dropWhile (/= bottomLine) inputLines

    -- Output
    let outputLines = linesBefore ++ [topLine] ++ map ("  " ++) files ++ linesAfter
    writeFile fp (unlines outputLines)


topLine, bottomLine :: String
topLine = "  -- BEGIN gen-extra-source-files"
bottomLine = "  -- END gen-extra-source-files"

dropTestsDir :: FilePath -> FilePath
dropTestsDir fp
    | pfx `isPrefixOf` fp = drop (length pfx) fp
    | otherwise           = fp
  where
    pfx = "tests/"

whitelistedFiles :: [FilePath]
whitelistedFiles = [ "ghc", "ghc-pkg", "ghc-7.10", "ghc-pkg-7.10", "ghc-pkg-ghc-7.10" ]

whitelistedExtensionss :: [String]
whitelistedExtensionss = map ('.' : )
    [ "hs", "lhs", "c", "sh", "cabal", "hsc", "err", "out", "in", "project" ]

getOtherModulesFiles :: GenericPackageDescription -> [FilePath]
getOtherModulesFiles gpd = mainModules ++ map fromModuleName otherModules'
  where
    testSuites        :: [TestSuite]
    testSuites        = map (foldCondTree . snd) (condTestSuites gpd)

    mainModules       = concatMap (mainModule   . testInterface) testSuites
    otherModules'     = concatMap (otherModules . testBuildInfo) testSuites

    fromModuleName mn = ModuleName.toFilePath mn ++ ".hs"

    mainModule (TestSuiteLibV09 _ mn) = [fromModuleName mn]
    mainModule (TestSuiteExeV10 _ fp) = [fp]
    mainModule _                      = []

skipPredicates :: [FilePath -> Bool]
skipPredicates =
    [ isSuffixOf "register.sh"
    ]
  where
    -- eq = (==)

main :: IO ()
main = do
    args <- getArgs
    case args of
        [fp] -> main' fp
        _    -> do
            progName <- getProgName
            putStrLn "Error too few arguments!"
            putStrLn $ "Usage: " ++ progName ++ " FILE"
            putStrLn "  where FILE is Cabal.cabal or cabal-install.cabal"

strictReadFile :: FilePath -> IO String
strictReadFile fp = do
    handle <- IO.openFile fp IO.ReadMode
    contents <- get handle
    IO.hClose handle
    return contents
  where
    get h = IO.hGetContents h >>= \s -> length s `seq` return s

foldCondTree :: Monoid a => CondTree v c a -> a
foldCondTree (CondNode x _ cs)
    = mappend x
    -- list, 3-tuple, maybe
    $ (foldMap . foldMapTriple . foldMap) foldCondTree cs
  where
    foldMapTriple :: (c -> x) -> (a, b, c) -> x
    foldMapTriple f (_, _, x) = f x
