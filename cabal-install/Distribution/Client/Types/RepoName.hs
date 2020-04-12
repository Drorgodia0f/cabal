{-# LANGUAGE DeriveGeneric #-}
module Distribution.Client.Types.RepoName (
    RepoName (..),
    unRepoName,
) where

import Distribution.Client.Compat.Prelude
import Prelude ()

import Distribution.FieldGrammar.Described (Described (..), GrammarRegex (..), csAlpha, csAlphaNum, reMunchCS)
import Distribution.Parsec                 (Parsec (..))
import Distribution.Pretty                 (Pretty (..))

import qualified Distribution.Compat.CharParsing as P
import qualified Text.PrettyPrint                as Disp

-- $setup
-- >>> import Distribution.Parsec

-- | Repository name.
--
-- May be used as path segment.
--
newtype RepoName = RepoName String
  deriving (Show, Eq, Ord, Generic)

unRepoName :: RepoName -> String
unRepoName (RepoName n) = n

instance Binary RepoName
instance Structured RepoName
instance NFData RepoName

instance Pretty RepoName where
    pretty = Disp.text . unRepoName

-- |
--
-- >>> simpleParsec "hackage.haskell.org" :: Maybe RepoName
-- Just (RepoName "hackage.haskell.org")
--
-- >>> simpleParsec "0123" :: Maybe RepoName
-- Nothing
--
instance Parsec RepoName where
    parsec = RepoName <$> parser where
        parser = (:) <$> lead <*> rest
        lead = P.satisfy (\c -> isAlpha    c || c == '_' || c == '-' || c == '.')
        rest = P.munch   (\c -> isAlphaNum c || c == '_' || c == '-' || c == '.')

instance Described RepoName where
    describe _ = lead <> rest where
        lead = RECharSet $ csAlpha    <> fromString "_-."
        rest = reMunchCS $ csAlphaNum <> fromString "_-."
