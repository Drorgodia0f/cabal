module PackageTests.BenchmarkStanza.Check where

import Test.Tasty.HUnit
import System.FilePath
import PackageTests.PackageTester
import Distribution.Version
import Distribution.PackageDescription.Parse
        ( readPackageDescription )
import Distribution.PackageDescription.Configuration
        ( finalizePackageDescription )
import Distribution.Package
        ( PackageName(..), Dependency(..) )
import Distribution.PackageDescription
        ( PackageDescription(..), BuildInfo(..), Benchmark(..)
        , BenchmarkInterface(..)
        , emptyBuildInfo
        , emptyBenchmark )
import Distribution.Verbosity (silent)
import Distribution.System (buildPlatform)
import Distribution.Compiler
        ( CompilerId(..), CompilerFlavor(..), unknownCompilerInfo, AbiTag(..) )
import Distribution.Text

suite :: SuiteConfig -> Assertion
suite config = do
    let dir = "PackageTests" </> "BenchmarkStanza"
        pdFile = dir </> "my" <.> "cabal"
        spec = PackageSpec { directory = dir, configOpts = [], distPref = Nothing }
    result <- cabal_configure config spec
    assertOutputDoesNotContain "unknown section type" result
    genPD <- readPackageDescription silent pdFile
    let compiler = unknownCompilerInfo (CompilerId GHC $ Version [6, 12, 2] []) NoAbiTag
        anticipatedBenchmark = emptyBenchmark
            { benchmarkName = "dummy"
            , benchmarkInterface = BenchmarkExeV10 (Version [1,0] []) "dummy.hs"
            , benchmarkBuildInfo = emptyBuildInfo
                    { targetBuildDepends =
                            [ Dependency (PackageName "base") anyVersion ]
                    , hsSourceDirs = ["."]
                    }
            , benchmarkEnabled = False
            }
    case finalizePackageDescription [] (const True) buildPlatform compiler [] genPD of
        Left xs -> let depMessage = "should not have missing dependencies:\n" ++
                                    (unlines $ map (show . disp) xs)
                   in assertEqual depMessage True False
        Right (f, _) -> let gotBenchmark = head $ benchmarks f
                        in assertEqual "parsed benchmark stanza does not match anticipated"
                                gotBenchmark anticipatedBenchmark
