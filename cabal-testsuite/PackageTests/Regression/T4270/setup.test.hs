import Test.Cabal.Prelude
-- Test if detailed-0.9 builds correctly and runs
-- when linked dynamically
-- See https://github.com/haskell/cabal/issues/4270
main = setupAndCabalTest $ do
  skipUnless "no shared libs"   =<< hasSharedLibraries
  skipUnless "no shared Cabal"  =<< hasCabalShared
  skipUnless "no Cabal for GHC" =<< hasCabalForGhc
  setup_build ["--enable-tests", "--enable-executable-dynamic"]
  setup "test" []
