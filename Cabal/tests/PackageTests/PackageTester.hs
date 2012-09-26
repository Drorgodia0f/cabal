module PackageTests.PackageTester (
        PackageSpec(..),
        Success(..),
        Result(..),
        cabal_configure,
        cabal_build,
        cabal_test,
        cabal_bench,
        cabal_install,
        unregister,
        run,
        assertBuildSucceeded,
        assertBuildFailed,
        assertTestSucceeded,
        assertInstallSucceeded,
        assertOutputContains
    ) where

import qualified Control.Exception.Extensible as E
import System.Directory
import System.FilePath
import System.IO
import System.Posix.IO
import System.Process
import System.Exit
import Control.Concurrent.Chan
import Control.Concurrent.MVar
import Control.Concurrent
import Control.Monad
import Data.List
import Data.Maybe
import qualified Data.ByteString.Char8 as C
import Test.HUnit


data PackageSpec =
    PackageSpec {
        directory  :: FilePath,
        configOpts :: [String]
    }

data Success = Failure
             | ConfigureSuccess
             | BuildSuccess
             | InstallSuccess
             | TestSuccess
             | BenchSuccess
             deriving (Eq, Show)

data Result = Result {
        successful :: Bool,
        success    :: Success,
        outputText :: String
    }
    deriving Show

nullResult :: Result
nullResult = Result True Failure ""

recordRun :: (String, ExitCode, String) -> Success -> Result -> Result
recordRun (cmd, exitCode, exeOutput) thisSucc res =
    res {
        successful = successful res && exitCode == ExitSuccess,
        success = if exitCode == ExitSuccess then thisSucc
                                             else success res,
        outputText =
            (if null $ outputText res then "" else outputText res ++ "\n") ++
                cmd ++ "\n" ++ exeOutput
    }

cabal_configure :: PackageSpec -> IO Result
cabal_configure spec = do
    res <- doCabalConfigure spec
    record spec res
    return res

doCabalConfigure :: PackageSpec -> IO Result
doCabalConfigure spec = do
    cleanResult@(_, _, cleanOutput) <- cabal spec ["clean"]
    requireSuccess cleanResult
    res <- cabal spec $ ["configure", "--user"] ++ configOpts spec
    return $ recordRun res ConfigureSuccess nullResult

doCabalBuild :: PackageSpec -> IO Result
doCabalBuild spec = do
    configResult <- doCabalConfigure spec
    if successful configResult
        then do
            res <- cabal spec ["build"]
            return $ recordRun res BuildSuccess configResult
        else
            return configResult

cabal_build :: PackageSpec -> IO Result
cabal_build spec = do
    res <- doCabalBuild spec
    record spec res
    return res

unregister :: String -> IO ()
unregister libraryName = do
    res@(_, _, output) <- run Nothing "ghc-pkg" ["unregister", "--user", libraryName]
    if "cannot find package" `isInfixOf` output
        then return ()
        else requireSuccess res

-- | Install this library in the user area
cabal_install :: PackageSpec -> IO Result
cabal_install spec = do
    buildResult <- doCabalBuild spec
    res <- if successful buildResult
        then do
            res <- cabal spec ["install"]
            return $ recordRun res InstallSuccess buildResult
        else
            return buildResult
    record spec res
    return res

cabal_test :: PackageSpec -> [String] -> IO Result
cabal_test spec extraArgs = do
    res <- cabal spec $ "test" : extraArgs
    let r = recordRun res TestSuccess nullResult
    record spec r
    return r

cabal_bench :: PackageSpec -> [String] -> IO Result
cabal_bench spec extraArgs = do
    res <- cabal spec $ "bench" : extraArgs
    let r = recordRun res BenchSuccess nullResult
    record spec r
    return r

-- | Returns the command that was issued, the return code, and hte output text
cabal :: PackageSpec -> [String] -> IO (String, ExitCode, String)
cabal spec cabalArgs = do
    wd <- getCurrentDirectory
    r <- run (Just $ directory spec) "ghc"
             [ "--make"
-- HPC causes trouble -- see #1012
--             , "-fhpc"
             , "-package-conf " ++ wd </> "../dist/package.conf.inplace"
             , "Setup.hs"
             ]
    requireSuccess r
    run (Just $ directory spec) (wd </> directory spec </> "Setup") cabalArgs

-- | Returns the command that was issued, the return code, and hte output text
run :: Maybe FilePath -> String -> [String] -> IO (String, ExitCode, String)
run cwd cmd args = do
    -- Posix-specific
    (outf, outf0) <- createPipe
    outh <- fdToHandle outf
    outh0 <- fdToHandle outf0
    pid <- runProcess cmd args cwd Nothing Nothing (Just outh0) (Just outh0)

    -- fork off a thread to start consuming the output
    output <- suckH [] outh
    hClose outh

    -- wait on the process
    ex <- waitForProcess pid
    let fullCmd = intercalate " " $ cmd:args
    return ("\"" ++ fullCmd ++ "\" in " ++ fromMaybe "" cwd,
        ex, output)
  where
    suckH output h = do
        eof <- hIsEOF h
        if eof
            then return (reverse output)
            else do
                c <- hGetChar h
                suckH (c:output) h

requireSuccess :: (String, ExitCode, String) -> IO ()
requireSuccess (cmd, exitCode, output) =
    unless (exitCode == ExitSuccess) $
        assertFailure $ "Command " ++ cmd ++ " failed.\n" ++
        "output: " ++ output

record :: PackageSpec -> Result -> IO ()
record spec res = do
    C.writeFile (directory spec </> "test-log.txt") (C.pack $ outputText res)

-- Test helpers:

assertBuildSucceeded :: Result -> Assertion
assertBuildSucceeded result = unless (successful result) $
    assertFailure $
    "expected: \'setup build\' should succeed\n" ++
    "  output: " ++ outputText result

assertBuildFailed :: Result -> Assertion
assertBuildFailed result = when (successful result) $
    assertFailure $
    "expected: \'setup build\' should fail\n" ++
    "  output: " ++ outputText result

assertTestSucceeded :: Result -> Assertion
assertTestSucceeded result = unless (successful result) $
    assertFailure $
    "expected: \'setup test\' should succeed\n" ++
    "  output: " ++ outputText result

assertInstallSucceeded :: Result -> Assertion
assertInstallSucceeded result = unless (successful result) $
    assertFailure $
    "expected: \'setup install\' should succeed\n" ++
    "  output: " ++ outputText result

assertOutputContains :: String -> Result -> Assertion
assertOutputContains needle result =
    unless (needle `isInfixOf` (intercalate " " $ lines output)) $
    assertFailure $
    " expected: " ++ needle ++
    "in output: " ++ output
  where output = outputText result
