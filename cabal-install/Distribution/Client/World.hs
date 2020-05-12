{-# LANGUAGE DeriveGeneric #-}
-----------------------------------------------------------------------------
-- |
-- Module      :  Distribution.Client.World
-- Copyright   :  (c) Peter Robinson 2009
-- License     :  BSD-like
--
-- Maintainer  :  thaldyron@gmail.com
-- Stability   :  provisional
-- Portability :  portable
--
-- Interface to the world-file that contains a list of explicitly
-- requested packages. Meant to be imported qualified.
--
-- A world file entry stores the package-name, package-version, and
-- user flags.
-- For example, the entry generated by
-- # cabal install stm-io-hooks --flags="-debug"
-- looks like this:
-- # stm-io-hooks -any --flags="-debug"
-- To rebuild/upgrade the packages in world (e.g. when updating the compiler)
-- use
-- # cabal install world
--
-----------------------------------------------------------------------------
module Distribution.Client.World (
    WorldPkgInfo(..),
    insert,
    delete,
    getContents,
  ) where

import Prelude (sequence)
import Distribution.Client.Compat.Prelude hiding (getContents)

import Distribution.Types.Dependency
import Distribution.Types.Flag
         ( FlagAssignment, unFlagAssignment
         , unFlagName, parsecFlagAssignmentNonEmpty )
import Distribution.Verbosity
         ( Verbosity )
import Distribution.Simple.Utils
         ( die', info, chattyTry, writeFileAtomic )
import Distribution.Parsec (Parsec (..), CabalParsing, simpleParsec)
import Distribution.Pretty (Pretty (..), prettyShow)
import qualified Distribution.Compat.CharParsing as P
import Distribution.Compat.Exception ( catchIO )
import qualified Text.PrettyPrint as Disp

import Data.List
         ( unionBy, deleteFirstsBy )
import System.IO.Error
         ( isDoesNotExistError )
import qualified Data.ByteString.Lazy.Char8 as B


data WorldPkgInfo = WorldPkgInfo Dependency FlagAssignment
  deriving (Show,Eq, Generic)

-- | Adds packages to the world file; creates the file if it doesn't
-- exist yet. Version constraints and flag assignments for a package are
-- updated if already present. IO errors are non-fatal.
insert :: Verbosity -> FilePath -> [WorldPkgInfo] -> IO ()
insert = modifyWorld $ unionBy equalUDep

-- | Removes packages from the world file.
-- Note: Currently unused as there is no mechanism in Cabal (yet) to
-- handle uninstalls. IO errors are non-fatal.
delete :: Verbosity -> FilePath -> [WorldPkgInfo] -> IO ()
delete = modifyWorld $ flip (deleteFirstsBy equalUDep)

-- | WorldPkgInfo values are considered equal if they refer to
-- the same package, i.e., we don't care about differing versions or flags.
equalUDep :: WorldPkgInfo -> WorldPkgInfo -> Bool
equalUDep (WorldPkgInfo (Dependency pkg1 _ _) _)
          (WorldPkgInfo (Dependency pkg2 _ _) _) = pkg1 == pkg2

-- | Modifies the world file by applying an update-function ('unionBy'
-- for 'insert', 'deleteFirstsBy' for 'delete') to the given list of
-- packages. IO errors are considered non-fatal.
modifyWorld :: ([WorldPkgInfo] -> [WorldPkgInfo]
                -> [WorldPkgInfo])
                        -- ^ Function that defines how
                        -- the list of user packages are merged with
                        -- existing world packages.
            -> Verbosity
            -> FilePath               -- ^ Location of the world file
            -> [WorldPkgInfo] -- ^ list of user supplied packages
            -> IO ()
modifyWorld _ _         _     []   = return ()
modifyWorld f verbosity world pkgs =
  chattyTry "Error while updating world-file. " $ do
    pkgsOldWorld <- getContents verbosity world
    -- Filter out packages that are not in the world file:
    let pkgsNewWorld = nubBy equalUDep $ f pkgs pkgsOldWorld
    -- 'Dependency' is not an Ord instance, so we need to check for
    -- equivalence the awkward way:
    if not (all (`elem` pkgsOldWorld) pkgsNewWorld &&
            all (`elem` pkgsNewWorld) pkgsOldWorld)
      then do
        info verbosity "Updating world file..."
        writeFileAtomic world . B.pack $ unlines
            [ (prettyShow pkg) | pkg <- pkgsNewWorld]
      else
        info verbosity "World file is already up to date."


-- | Returns the content of the world file as a list
getContents :: Verbosity -> FilePath -> IO [WorldPkgInfo]
getContents verbosity world = do
  content <- safelyReadFile world
  let result = map simpleParsec (lines $ B.unpack content)
  case sequence result of
    Nothing -> die' verbosity "Could not parse world file."
    Just xs -> return xs
  where
  safelyReadFile :: FilePath -> IO B.ByteString
  safelyReadFile file = B.readFile file `catchIO` handler
    where
      handler e | isDoesNotExistError e = return B.empty
                | otherwise             = ioError e


instance Pretty WorldPkgInfo where
  pretty (WorldPkgInfo dep flags) = pretty dep Disp.<+> dispFlags (unFlagAssignment flags)
    where
      dispFlags [] = Disp.empty
      dispFlags fs = Disp.text "--flags="
                  <<>> Disp.doubleQuotes (flagAssToDoc fs)
      flagAssToDoc = foldr (\(fname,val) flagAssDoc ->
                             (if not val then Disp.char '-'
                                         else Disp.char '+')
                             <<>> Disp.text (unFlagName fname)
                             Disp.<+> flagAssDoc)
                           Disp.empty

instance Parsec WorldPkgInfo where
  parsec = do
      dep <- parsec
      P.spaces
      flagAss <- P.option mempty parseFlagAssignment
      return $ WorldPkgInfo dep flagAss
    where
      parseFlagAssignment :: CabalParsing m => m FlagAssignment
      parseFlagAssignment = do
          _ <- P.string "--flags="
          inDoubleQuotes parsecFlagAssignmentNonEmpty
        where
          inDoubleQuotes = P.between (P.char '"') (P.char '"')
