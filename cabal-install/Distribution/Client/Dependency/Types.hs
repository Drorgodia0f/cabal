{-# LANGUAGE DeriveGeneric #-}
-----------------------------------------------------------------------------
-- |
-- Module      :  Distribution.Client.Dependency.Types
-- Copyright   :  (c) Duncan Coutts 2008
-- License     :  BSD-like
--
-- Maintainer  :  cabal-devel@haskell.org
-- Stability   :  provisional
-- Portability :  portable
--
-- Common types for dependency resolution.
-----------------------------------------------------------------------------
module Distribution.Client.Dependency.Types (
    PreSolver(..),
    Solver(..),

    DependencyResolver,

    PackagePreferences(..),
    InstalledPreference(..),
    PackagesPreferenceDefault(..),

    LabeledPackageConstraint(..),
    unlabelPackageConstraint

  ) where

import Data.Char
         ( isAlpha, toLower )

import Distribution.Solver.Types.ConstraintSource
import Distribution.Solver.Types.OptionalStanza
import Distribution.Solver.Types.PkgConfigDb ( PkgConfigDb )
import Distribution.Solver.Types.PackageConstraint ( PackageConstraint )
import Distribution.Solver.Types.PackageIndex ( PackageIndex )
import Distribution.Solver.Types.Progress
import Distribution.Solver.Types.ResolverPackage
import Distribution.Solver.Types.SourcePackage

import qualified Distribution.Compat.ReadP as Parse
         ( pfail, munch1 )
import Distribution.Simple.PackageIndex ( InstalledPackageIndex )
import Distribution.Package
         ( PackageName )
import Distribution.Version
         ( VersionRange )
import Distribution.Compiler
         ( CompilerInfo )
import Distribution.System
         ( Platform )
import Distribution.Text
         ( Text(..) )

import Text.PrettyPrint
         ( text )
import GHC.Generics (Generic)
import Distribution.Compat.Binary (Binary(..))

import Prelude hiding (fail)


-- | All the solvers that can be selected.
data PreSolver = AlwaysTopDown | AlwaysModular | Choose
  deriving (Eq, Ord, Show, Bounded, Enum, Generic)

-- | All the solvers that can be used.
data Solver = TopDown | Modular
  deriving (Eq, Ord, Show, Bounded, Enum, Generic)

instance Binary PreSolver
instance Binary Solver

instance Text PreSolver where
  disp AlwaysTopDown = text "topdown"
  disp AlwaysModular = text "modular"
  disp Choose        = text "choose"
  parse = do
    name <- Parse.munch1 isAlpha
    case map toLower name of
      "topdown" -> return AlwaysTopDown
      "modular" -> return AlwaysModular
      "choose"  -> return Choose
      _         -> Parse.pfail

-- | A dependency resolver is a function that works out an installation plan
-- given the set of installed and available packages and a set of deps to
-- solve for.
--
-- The reason for this interface is because there are dozens of approaches to
-- solving the package dependency problem and we want to make it easy to swap
-- in alternatives.
--
type DependencyResolver loc = Platform
                           -> CompilerInfo
                           -> InstalledPackageIndex
                           -> PackageIndex (SourcePackage loc)
                           -> PkgConfigDb
                           -> (PackageName -> PackagePreferences)
                           -> [LabeledPackageConstraint]
                           -> [PackageName]
                           -> Progress String String [ResolverPackage loc]

-- | Per-package preferences on the version. It is a soft constraint that the
-- 'DependencyResolver' should try to respect where possible. It consists of
-- an 'InstalledPreference' which says if we prefer versions of packages
-- that are already installed. It also has (possibly multiple)
-- 'PackageVersionPreference's which are suggested constraints on the version
-- number. The resolver should try to use package versions that satisfy
-- the maximum number of the suggested version constraints.
--
-- It is not specified if preferences on some packages are more important than
-- others.
--
data PackagePreferences = PackagePreferences [VersionRange]
                                             InstalledPreference
                                             [OptionalStanza]

-- | Whether we prefer an installed version of a package or simply the latest
-- version.
--
data InstalledPreference = PreferInstalled | PreferLatest
  deriving Show

-- | Global policy for all packages to say if we prefer package versions that
-- are already installed locally or if we just prefer the latest available.
--
data PackagesPreferenceDefault =

     -- | Always prefer the latest version irrespective of any existing
     -- installed version.
     --
     -- * This is the standard policy for upgrade.
     --
     PreferAllLatest

     -- | Always prefer the installed versions over ones that would need to be
     -- installed. Secondarily, prefer latest versions (eg the latest installed
     -- version or if there are none then the latest source version).
   | PreferAllInstalled

     -- | Prefer the latest version for packages that are explicitly requested
     -- but prefers the installed version for any other packages.
     --
     -- * This is the standard policy for install.
     --
   | PreferLatestForSelected
  deriving Show

-- | 'PackageConstraint' labeled with its source.
data LabeledPackageConstraint
   = LabeledPackageConstraint PackageConstraint ConstraintSource

unlabelPackageConstraint :: LabeledPackageConstraint -> PackageConstraint
unlabelPackageConstraint (LabeledPackageConstraint pc _) = pc
