{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE DeriveGeneric      #-}
module Distribution.Types.PackageVersionConstraint (
    PackageVersionConstraint(..),
    thisPackageVersionConstraint,
) where

import Distribution.Compat.Prelude
import Prelude ()

import Distribution.Parsec
import Distribution.Pretty
import Distribution.Types.PackageName
import Distribution.Types.PackageId
import Distribution.Types.Version
import Distribution.Types.VersionRange.Internal
import Distribution.FieldGrammar.Described

import qualified Distribution.Compat.CharParsing as P
import           Text.PrettyPrint                ((<+>))

-- | A version constraint on a package. Different from 'ExeDependency' and
-- 'Dependency' since it does not specify the need for a component, not even
-- the main library.
-- There are a few places in the codebase where 'Dependency' was used where
-- 'PackageVersionConstraint' is not used instead (#5570).
data PackageVersionConstraint = PackageVersionConstraint PackageName VersionRange
                  deriving (Generic, Read, Show, Eq, Typeable, Data)

instance Binary PackageVersionConstraint
instance Structured PackageVersionConstraint
instance NFData PackageVersionConstraint where rnf = genericRnf

instance Pretty PackageVersionConstraint where
  -- Cannot do: PackageVersionConstraint have to be parseable
  -- as Dependency, due roundtrip problems. (e.g. talking to old ./Setup).
  --
  -- pretty (PackageVersionConstraint name (ThisVersion ver)) =
  --     pretty (PackageIdentifier name ver)
  pretty (PackageVersionConstraint name ver) =
      pretty name <+> pretty ver

-- |
--
-- >>> simpleParsec "foo" :: Maybe PackageVersionConstraint
-- Just (PackageVersionConstraint (PackageName "foo") (OrLaterVersion (mkVersion [0])))
--
-- >>> simpleParsec "foo >=2.0" :: Maybe PackageVersionConstraint
-- Just (PackageVersionConstraint (PackageName "foo") (OrLaterVersion (mkVersion [2,0])))
--
-- >>> simpleParsec "foo-2.0" :: Maybe PackageVersionConstraint
-- Just (PackageVersionConstraint (PackageName "foo") (ThisVersion (mkVersion [2,0])))
--
instance Parsec PackageVersionConstraint where
  parsec = do
      PackageIdentifier name ver <- parsec
      if ver == nullVersion
      then do
          P.spaces
          vr <- parsec <|> return anyVersion
          P.spaces
          return (PackageVersionConstraint name vr)
      else
          pure (PackageVersionConstraint name (thisVersion ver))

instance Described PackageVersionConstraint where
    describe _ = describe (Proxy :: Proxy PackageName) <> REUnion
        [ fromString "-" <> describe (Proxy :: Proxy Version)
        , RESpaces <> describe (Proxy :: Proxy VersionRange)
        ]

thisPackageVersionConstraint :: PackageIdentifier -> PackageVersionConstraint
thisPackageVersionConstraint (PackageIdentifier pn vr) =
    PackageVersionConstraint pn (thisVersion vr)
