-----------------------------------------------------------------------------

-- |
-- Module      :  Distribution.ModuleTest
-- Copyright   :  Isaac Jones 2003-2004
-- 
-- Maintainer  :  Isaac Jones <ijones@syntaxpolice.org>
-- Stability   :  alpha
-- Portability :  GHC
--
-- Explanation: <FIX>
-- WHERE DOES THIS MODULE FIT IN AT A HIGH-LEVEL <FIX>

{- Copyright (c) 2003-2004, Isaac Jones
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

module Main where

-- Import everything, since we want to test the compilation of them:

import qualified Distribution.Version as D.V (hunitTests)
-- import qualified Distribution.InstalledPackageInfo(hunitTests)
import qualified Distribution.Misc as D.M (hunitTests)
import qualified Distribution.Package as D.P (hunitTests)
import qualified Distribution.Setup as D.Setup (hunitTests)

import qualified Distribution.Simple as D.S (simpleHunitTests)
import qualified Distribution.Simple.Install as D.S.I (hunitTests)
import qualified Distribution.Simple.Build as D.S.B (hunitTests)
import qualified Distribution.Simple.SrcDist as D.S.S (hunitTests)
import qualified Distribution.Simple.Utils as D.S.U (hunitTests)
import Distribution.Simple.Utils(pathJoin)
import qualified Distribution.Simple.Configure as D.S.C (hunitTests)
import qualified Distribution.Simple.Register as D.S.R (hunitTests)

-- base
import Control.Monad(when)
import Directory(setCurrentDirectory, doesFileExist,
                 doesDirectoryExist, getCurrentDirectory)
import System.Cmd(system)
import System.Exit(ExitCode(..))

import HUnit(runTestTT, Test(..), Counts, assertBool, assertEqual, Assertion)

label :: String -> String
label t = "-= " ++ t ++ " =-"

runTestTT' :: Test -> IO Counts
runTestTT' t@(TestList _) = runTestTT t
runTestTT'  (TestLabel l t)
    = putStrLn (label l) >> runTestTT t
runTestTT' t = runTestTT t


checkTargetDir :: FilePath
               -> [String] -- ^suffixes
               -> IO ()
checkTargetDir targetDir suffixes
    = do doesDirectoryExist targetDir >>=
           assertBool "target dir exists"
         let files = [x++y |
                      x <- ["A", "B/A"],
                      y <- suffixes]
         allFilesE <- sequence [doesFileExist (targetDir ++ t)
                                | t <- files]

         sequence [assertBool ("target file missing: " ++ targetDir ++ f) e
                   | (e, f) <- zip allFilesE files]
         return ()

-- |Run this command, and assert it returns a successful error code.
assertCmd :: String -- ^Command
          -> String -- ^Comment
          -> Assertion
assertCmd command comment
    = system command >>= assertEqual (command ++ ":" ++ comment) ExitSuccess

tests :: [Test]
tests = [TestLabel "testing the HUnit package" $ TestCase $ 
         do oldDir <- getCurrentDirectory
            setCurrentDirectory "test/HUnit-1.0"
--            assertCmd "make semiclean" "make semiclean"
            system "ghc-pkg --config-file=$HOME/.ghc-packages -r HUnit-1.0"
            assertCmd "./setup configure --prefix=\",tmp\"" "hunit configure"
            assertCmd "./setup build" "hunit build"
            assertCmd "./setup install --user" "hunit install"
            assertCmd "ghc -package-conf $HOME/.ghc-packages  -package HUnit-1.0 HUnitTester.hs -o ./hunitTest" "compile w/ hunit"
            assertCmd "./hunitTest" "hunit test"
            assertCmd "ghc-pkg --config-file=$HOME/.ghc-packages -r HUnit-1.0" "package remove"
            setCurrentDirectory oldDir,

         TestLabel "configure GHC, sdist" $ TestCase $
         do system "ghc-pkg -r test-1.0 --config-file=$HOME/.ghc-packages"
            setCurrentDirectory "test/A"
            dirE1 <- doesDirectoryExist ",tmp"
            when dirE1 (system "rm -r ,tmp">>return())
            dirE2 <- doesDirectoryExist "dist"
            when dirE2 (system "rm -r dist">>return())
            system "./setup configure --ghc --prefix=,tmp"
             >>= assertEqual "configure returned error code" ExitSuccess
            system "./setup build"
             >>= assertEqual "build returned error code" ExitSuccess

            system "./setup sdist"
             >>= assertEqual "setup sdist returned error code" ExitSuccess
            doesFileExist "dist/test-1.0.tgz" >>= 
              assertBool "sdist did not put the expected file in place"
            doesFileExist "dist/src" >>=
              assertEqual "dist/src exists" False
            doesDirectoryExist "dist/build" >>=
              assertBool "dist/build doesn't exists",
         TestLabel "GHC and install-prefix" $ TestCase $ -- (uses above config)
         do let targetDir = ",tmp2"
            instRetCode <- system $ "./setup install --install-prefix=" ++ targetDir
            checkTargetDir ",tmp2/lib/test-1.0/" [".hi"]
            doesFileExist (pathJoin [",tmp2/lib/test-1.0/", "libHStest-1.0.a"])
              >>= assertBool "library doesn't exist"
            assertEqual "install returned error code" ExitSuccess instRetCode,
         TestLabel "GHC and install w/ no prefix" $ TestCase $
         do let targetDir = ",tmp/lib/test-1.0/"
            instRetCode <- system $ "./setup install --user"
            checkTargetDir targetDir [".hi"]
            doesFileExist (pathJoin [targetDir, "libHStest-1.0.a"])
              >>= assertBool "library doesn't exist"
            assertEqual "install returned error code" ExitSuccess instRetCode,
         TestLabel "no install-prefix and hugs" $ TestCase $
         do system "./setup configure --hugs --prefix=,tmp"
             >>= assertEqual "HUGS configure returned error code" ExitSuccess
            system "./setup build"
             >>= assertEqual "HUGS build returned error code" ExitSuccess
            instRetCode <- system "./setup install --user"
            let targetDir = ",tmp/lib/test-1.0/"
            checkTargetDir targetDir [".hs"]
            assertEqual "install HUGS returned error code" ExitSuccess instRetCode
         ]

main :: IO ()
main = do putStrLn "compile successful"
          putStrLn "-= Setup Tests =-"
          runTestTT' $ TestList $
                        (TestLabel "Utils Tests" $ TestList D.S.U.hunitTests):
                        (TestLabel "Setup Tests" $ TestList D.Setup.hunitTests):
                        (TestLabel "config Tests" $ TestList D.S.C.hunitTests):
                          (D.S.R.hunitTests ++ D.V.hunitTests ++
                           D.S.S.hunitTests ++ D.S.B.hunitTests ++
                           D.S.I.hunitTests ++ D.S.simpleHunitTests ++
                           D.P.hunitTests ++ D.M.hunitTests)
          runTestTT' $ TestList tests
          return ()

-- Local Variables:
-- compile-command: "ghc -i../:/usr/local/src/HUnit-1.0 -Wall --make ModuleTest.hs -o moduleTest"
-- End:

