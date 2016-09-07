{-# LANGUAGE DeriveGeneric #-}

-----------------------------------------------------------------------------
-- |
-- Module      :  Distribution.Verbosity
-- Copyright   :  Ian Lynagh 2007
-- License     :  BSD3
--
-- Maintainer  :  cabal-devel@haskell.org
-- Portability :  portable
--
-- A 'Verbosity' type with associated utilities.
--
-- There are 4 standard verbosity levels from 'silent', 'normal',
-- 'verbose' up to 'deafening'. This is used for deciding what logging
-- messages to print.
--
-- Verbosity also is equipped with some internal settings which can be
-- used to control at a fine granularity the verbosity of specific
-- settings (e.g., so that you can trace only particular things you
-- are interested in.)  It's important to note that the instances
-- for 'Verbosity' assume that this does not exist.

-- Verbosity for Cabal functions.

module Distribution.Verbosity (
  -- * Verbosity
  Verbosity,
  silent, normal, verbose, deafening,
  moreVerbose, lessVerbose,
  intToVerbosity, flagToVerbosity,
  showForCabal, showForGHC,

  -- * Call stacks
  verboseCallSite, verboseCallStack,
  isVerboseCallSite, isVerboseCallStack,
 ) where

import Prelude ()
import Distribution.Compat.Prelude

import Distribution.ReadE
import Distribution.Compat.ReadP

import Data.List (elemIndex)

data Verbosity = Verbosity {
    vLevel :: VerbosityLevel,
    vCallStack :: CallStackLevel
  } deriving (Generic)

mkVerbosity :: VerbosityLevel -> Verbosity
mkVerbosity l = Verbosity { vLevel = l, vCallStack = NoStack }

instance Show Verbosity where
    showsPrec n = showsPrec n . vLevel

instance Read Verbosity where
    readsPrec n s = map (\(x,y) -> (mkVerbosity x,y)) (readsPrec n s)

instance Eq Verbosity where
    x == y = vLevel x == vLevel y

instance Ord Verbosity where
    compare x y = compare (vLevel x) (vLevel y)

instance Enum Verbosity where
    toEnum = mkVerbosity . toEnum
    fromEnum = fromEnum . vLevel

instance Bounded Verbosity where
    minBound = mkVerbosity minBound
    maxBound = mkVerbosity maxBound

instance Binary Verbosity

data VerbosityLevel = Silent | Normal | Verbose | Deafening
    deriving (Generic, Show, Read, Eq, Ord, Enum, Bounded)

instance Binary VerbosityLevel

-- We shouldn't print /anything/ unless an error occurs in silent mode
silent :: Verbosity
silent = mkVerbosity Silent

-- Print stuff we want to see by default
normal :: Verbosity
normal = mkVerbosity Normal

-- Be more verbose about what's going on
verbose :: Verbosity
verbose = mkVerbosity Verbose

-- Not only are we verbose ourselves (perhaps even noisier than when
-- being "verbose"), but we tell everything we run to be verbose too
deafening :: Verbosity
deafening = mkVerbosity Deafening

moreVerbose :: Verbosity -> Verbosity
moreVerbose v =
    case vLevel v of
        Silent    -> v -- silent should stay silent
        Normal    -> v { vLevel = Verbose }
        Verbose   -> v { vLevel = Deafening }
        Deafening -> v

lessVerbose :: Verbosity -> Verbosity
lessVerbose v =
    case vLevel v of
        Deafening -> v -- deafening stays deafening
        Verbose   -> v { vLevel = Normal }
        Normal    -> v { vLevel = Silent }
        Silent    -> v

intToVerbosity :: Int -> Maybe Verbosity
intToVerbosity 0 = Just (mkVerbosity Silent)
intToVerbosity 1 = Just (mkVerbosity Normal)
intToVerbosity 2 = Just (mkVerbosity Verbose)
intToVerbosity 3 = Just (mkVerbosity Deafening)
intToVerbosity _ = Nothing

parseVerbosity :: ReadP r (Either Int Verbosity)
parseVerbosity = parseIntVerbosity <++ parseStringVerbosity
  where
    parseIntVerbosity = fmap Left (readS_to_P reads)
    parseStringVerbosity = fmap Right $ do
        level <- parseVerbosityLevel
        _ <- skipSpaces
        extras <- sepBy parseExtra skipSpaces
        return (foldr (.) id extras (mkVerbosity level))
    parseVerbosityLevel = choice
        [ string "silent" >> return Silent
        , string "normal" >> return Normal
        , string "verbose" >> return Verbose
        , string "debug"  >> return Deafening
        , string "deafening" >> return Deafening
        ]
    parseExtra = char '+' >> choice
        [ string "callsite"  >> return verboseCallSite
        , string "callstack" >> return verboseCallStack
        ]

flagToVerbosity :: ReadE Verbosity
flagToVerbosity = ReadE $ \s ->
   case readP_to_S (parseVerbosity >>= \r -> eof >> return r) s of
       [(Left i, "")] ->
           case intToVerbosity i of
               Just v -> Right v
               Nothing -> Left ("Bad verbosity: " ++ show i ++
                                     ". Valid values are 0..3")
       [(Right v, "")] -> Right v
       _ -> Left ("Can't parse verbosity " ++ s)

showForCabal, showForGHC :: Verbosity -> String

showForCabal v = maybe (error "unknown verbosity") show $
    elemIndex v [silent,normal,verbose,deafening]
showForGHC   v = maybe (error "unknown verbosity") show $
    elemIndex v [silent,normal,__,verbose,deafening]
        where __ = silent -- this will be always ignored by elemIndex

data CallStackLevel = NoStack | TopStackFrame | FullStack
    deriving (Generic, Show, Read, Eq, Ord, Enum, Bounded)

instance Binary CallStackLevel

-- | Turn on verbose call-site printing when we log.  Overrides 'verboseCallStack'.
verboseCallSite :: Verbosity -> Verbosity
verboseCallSite v = v { vCallStack = TopStackFrame }

-- | Turn on verbose call-stack printing when we log.  Overrides 'verboseCallSite'.
verboseCallStack :: Verbosity -> Verbosity
verboseCallStack v = v { vCallStack = FullStack }

-- | Test if we should output call sites when we log.
isVerboseCallSite :: Verbosity -> Bool
isVerboseCallSite = (== TopStackFrame) . vCallStack

-- | Test if we should output call stacks when we log.
isVerboseCallStack :: Verbosity -> Bool
isVerboseCallStack = (== FullStack) . vCallStack
