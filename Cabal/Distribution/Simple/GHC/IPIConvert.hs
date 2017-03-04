-----------------------------------------------------------------------------
-- |
-- Module      :  Distribution.Simple.GHC.IPI642
-- Copyright   :  (c) The University of Glasgow 2004
-- License     :  BSD3
--
-- Maintainer  :  cabal-devel@haskell.org
-- Portability :  portable
--
-- Helper functions for 'Distribution.Simple.GHC.IPI642'.
module Distribution.Simple.GHC.IPIConvert (
    MungedPackageId, convertMungedPackageId,
    License, convertLicense,
    convertModuleName
  ) where

import Prelude ()
import Distribution.Compat.Prelude

import qualified Distribution.Types.MungedPackageId as Current
import qualified Distribution.Types.MungedPackageName as Current
import qualified Distribution.License as Current

import Distribution.Version
import Distribution.ModuleName
import Distribution.Text

-- | This is a indeed a munged package id, but the constructor name cannot be
-- changed or the Read instance (the entire point of this type) will break.
data MungedPackageId = PackageIdentifier {
    pkgName    :: String,
    pkgVersion :: Version
  }
  deriving Read

convertMungedPackageId :: MungedPackageId -> Current.MungedPackageId
convertMungedPackageId PackageIdentifier { pkgName = n, pkgVersion = v } =
  Current.MungedPackageId (Current.mkMungedPackageName n) v

data License = GPL | LGPL | BSD3 | BSD4
             | PublicDomain | AllRightsReserved | OtherLicense
  deriving Read

convertModuleName :: String -> ModuleName
convertModuleName s = fromMaybe (error "convertModuleName") $ simpleParse s

convertLicense :: License -> Current.License
convertLicense GPL  = Current.GPL  Nothing
convertLicense LGPL = Current.LGPL Nothing
convertLicense BSD3 = Current.BSD3
convertLicense BSD4 = Current.BSD4
convertLicense PublicDomain = Current.PublicDomain
convertLicense AllRightsReserved = Current.AllRightsReserved
convertLicense OtherLicense = Current.OtherLicense
