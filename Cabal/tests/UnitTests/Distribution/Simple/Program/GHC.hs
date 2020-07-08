module UnitTests.Distribution.Simple.Program.GHC (tests) where

import Test.Tasty       (TestTree, testGroup)
import Test.Tasty.HUnit
import Data.Algorithm.Diff (PolyDiff (..), getDiff)

import Distribution.Simple.Program.GHC (normaliseGhcArgs)
import Distribution.PackageDescription (emptyPackageDescription)
import Distribution.Version (mkVersion)

tests :: TestTree
tests = testGroup "Distribution.Simple.Program.GHC"
    [ testGroup "normaliseGhcArgs"
        [ testCase "options added in GHC-8.8" $ do
            let flags :: [String]
                flags = normaliseGhcArgs
                    (Just $ mkVersion [8,8,1])
                    emptyPackageDescription
                    options_8_8_all

            assertListEquals flags options_8_8_affects

        , testCase "options added in GHC-8.10" $ do
            let flags :: [String]
                flags = normaliseGhcArgs
                    (Just $ mkVersion [8,10,1])
                    emptyPackageDescription
                    options_8_10_all

            assertListEquals flags options_8_10_affects

        , testCase "options added in GHC-8.12" $ do
            let flags :: [String]
                flags = normaliseGhcArgs
                    (Just $ mkVersion [8,12,1])
                    emptyPackageDescription
                    options_8_12_all

            assertListEquals flags options_8_12_affects
        ]
    ]

assertListEquals :: (Eq a, Show a) => [a] -> [a] -> Assertion
assertListEquals xs ys
    | xs == ys = return ()
    | otherwise = assertFailure $ unlines $
        "Lists are not equal" :
        [ case d of
            First x  -> "- " ++ show x
            Second y -> "+ " ++ show y
            Both x _ -> "  " ++ show x
        | d <- getDiff xs ys
        ]

-------------------------------------------------------------------------------
-- GHC 8.8
-------------------------------------------------------------------------------

-- | Options added in GHC-8.8, to generate:
--
-- @
-- ghc-8.6.5 --show-options | sort > 8.6.5.txt
-- ghc-8.8.1 --show-options | sort > 8.8.1.txt
-- diff -u 8.6.5 8.8.1
-- @
--
-- - remove -W(no-)error=, -W(no-)warn flags.
-- - split into all and flags which may affect artifacts
options_8_8_all :: [String]
options_8_8_all =
    [ "-ddump-cfg-weights"
    , "-dno-suppress-stg-exts"
    , "-dsuppress-stg-exts"
    , "-Wmissed-extra-shared-lib"
    , "-Wmissing-deriving-strategies"
    , "-Wmissing-space-after-bang"
    , "-Wno-missed-extra-shared-lib"
    , "-Wno-missing-deriving-strategies"
    , "-Wno-missing-space-after-bang"
    , "-fno-show-docs-of-hole-fits"
    , "-fshow-docs-of-hole-fits"
    ] ++ options_8_8_affects

options_8_8_affects :: [String]
options_8_8_affects =
    [ "-fblock-layout-cfg"
    , "-fblock-layout-weightless"
    , "-fblock-layout-weights"
    , "-fclear-plugins"
    , "-fkeep-cafs"
    , "-fno-block-layout-cfg"
    , "-fno-block-layout-weightless"
    , "-fno-keep-cafs"
    , "-fno-safe-haskell"
    , "-fno-stg-lift-lams"
    , "-fno-stg-lift-lams-known"
    , "-fno-validate-ide-info"
    , "-fno-write-ide-info"
    , "-fstg-lift-lams"
    , "-fstg-lift-lams-known"
    , "-fstg-lift-lams-non-rec-args"
    , "-fstg-lift-lams-non-rec-args-any"
    , "-fstg-lift-lams-rec-args"
    , "-fstg-lift-lams-rec-args-any"
    , "-fvalidate-ide-info"
    , "-fwrite-ide-info"
    , "-hiedir"
    , "-hiesuf"
    , "-keep-hscpp-file"
    , "-keep-hscpp-files"
    ]

-------------------------------------------------------------------------------
-- GHC 8.10
-------------------------------------------------------------------------------

options_8_10_all :: [String]
options_8_10_all =
    [ "-ddump-cmm-verbose-by-proc"
    , "-ddump-stg-final"
    , "-ddump-stg-unarised"
    , "-Wderiving-defaults"
    , "-Winferred-safe-imports"
    , "-Wmissing-safe-haskell-mode"
    , "-Wno-deriving-defaults"
    , "-Wno-inferred-safe-imports"
    , "-Wno-missing-safe-haskell-mode"
    , "-Wno-prepositive-qualified-module"
    , "-Wno-redundant-record-wildcards"
    , "-Wno-unused-packages"
    , "-Wno-unused-record-wildcards"
    , "-Wprepositive-qualified-module"
    , "-Wredundant-record-wildcards"
    , "-Wunused-packages"
    , "-Wunused-record-wildcards"
    , "-fdefer-diagnostics"
    , "-fkeep-going"
    , "-fprint-axiom-incomps"
    , "-fno-defer-diagnostics"
    , "-fno-keep-going"
    , "-fno-print-axiom-incomps"
    ] ++ options_8_10_affects

options_8_10_affects :: [String]
options_8_10_affects =
    [ "-dno-typeable-binds"
    , "-fbinary-blob-threshold"
    , "-fmax-pmcheck-models"
    , "-fplugin-trustworthy"
    , "-include-cpp-deps"
    , "-optcxx"
    ]

-------------------------------------------------------------------------------
-- GHC-8.12
-------------------------------------------------------------------------------

options_8_12_all :: [String]
options_8_12_all =
    [ "-ddump-cmm-opt"
    , "-ddump-cpranal"
    , "-ddump-cpr-signatures"
    , "-ddump-hie"
    -- NOTE: we filter out -dlinear-core-lint
    -- we filter, -dcore-lint, -dstg-lint etc.
    , "-dlinear-core-lint"
    ] ++ options_8_12_affects

options_8_12_affects :: [String]
options_8_12_affects =
    [ "-fcmm-static-pred"
    ]
