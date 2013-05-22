-----------------------------------------------------------------------------
-- | Separate module for HTTP actions, using a proxy server if one exists 
-----------------------------------------------------------------------------
module Distribution.Client.HttpUtils (
    downloadURI,
    getHTTP,
    cabalBrowse,
    proxy,
    isOldHackageURI
  ) where

import Network.HTTP
         ( Request (..), Response (..), RequestMethod (..)
         , Header(..), HeaderName(..), lookupHeader )
import Network.HTTP.Proxy ( Proxy(..), fetchProxy)
import Network.URI
         ( URI (..), URIAuth (..) )
import Network.Browser
         ( BrowserAction, browse
         , setOutHandler, setErrHandler, setProxy, setAuthorityGen, request)
import Network.Stream
         ( Result, ConnError(..) )
import Control.Monad
         ( liftM )
import qualified Data.ByteString.Lazy.Char8 as ByteString
import Data.ByteString.Lazy (ByteString)

import qualified Paths_cabal_install (version)
import Distribution.Verbosity (Verbosity)
import Distribution.Simple.Utils
         ( die, info, warn, debug, notice
         , copyFileVerbose, writeFileAtomic )
import Distribution.Text
         ( display )
import Data.Char ( isSpace )
import qualified System.FilePath.Posix as FilePath.Posix
         ( splitDirectories )
import System.FilePath
         ( (<.>) )
import System.Directory
         ( doesFileExist )

-- Trime
trim :: String -> String
trim = f . f
      where f = reverse . dropWhile isSpace

-- |Get the local proxy settings  
--TODO: print info message when we're using a proxy based on verbosity
proxy :: Verbosity -> IO Proxy
proxy _verbosity = do
  p <- fetchProxy True
  -- Handle empty proxy strings
  return $ case p of
    Proxy uri auth ->
      let uri' = trim uri in
      if uri' == "" then NoProxy else Proxy uri' auth
    _ -> p

mkRequest :: URI
          -> Maybe String -- ^ optional etag to be set in the If-None-Match HTTP header
          -> Request ByteString
mkRequest uri etag = Request{ rqURI     = uri
                            , rqMethod  = GET
                            , rqHeaders = Header HdrUserAgent userAgent : ifNoneMatchHdr
                            , rqBody    = ByteString.empty }
  where userAgent = "cabal-install/" ++ display Paths_cabal_install.version
        ifNoneMatchHdr = maybe [] (\t -> [Header HdrIfNoneMatch t]) etag

-- |Carry out a GET request, using the local proxy settings
getHTTP :: Verbosity
        -> URI
        -> Maybe String -- ^ optional etag to check if we already have the latest file
        -> IO (Result (Response ByteString))
getHTTP verbosity uri etag = liftM (\(_, resp) -> Right resp) $
                                   cabalBrowse verbosity (return ()) (request (mkRequest uri etag))

cabalBrowse :: Verbosity
            -> BrowserAction s ()
            -> BrowserAction s a
            -> IO a
cabalBrowse verbosity auth act = do
    p   <- proxy verbosity
    browse $ do
        setProxy p
        setErrHandler (warn verbosity . ("http error: "++))
        setOutHandler (debug verbosity)
        auth
        setAuthorityGen (\_ _ -> return Nothing)
        act

downloadURI :: Verbosity
            -> URI      -- ^ What to download
            -> FilePath -- ^ Where to put it
            -> IO ()
downloadURI verbosity uri path | uriScheme uri == "file:" =
  copyFileVerbose verbosity (uriPath uri) path
downloadURI verbosity uri path = do
  let etagPath = path <.> "etag"
  etagPathExists <- doesFileExist etagPath
  etag <- if etagPathExists
            then liftM Just $ readFile etagPath
            else return Nothing

  result <- getHTTP verbosity uri etag
  let result' = case result of
        Left  err -> Left err
        Right rsp -> case rspCode rsp of
          (2,0,0) -> Right rsp
          (3,0,4) -> Right rsp
          (a,b,c) -> Left err
            where
              err = ErrorMisc $ "Unsucessful HTTP code: " 
                            ++ concatMap show [a,b,c]

  -- only write the etag if we get a 200 response code
  -- since a 304 still sends us an etag header
  case result' of
    Left _ -> return ()
    Right rsp -> case rspCode rsp of
      (2,0,0) -> case lookupHeader HdrETag (rspHeaders rsp) of
        Nothing -> return ()
        Just newEtag -> writeFile etagPath newEtag
      (_,_,_) -> return ()

  case result' of
    Left err   -> die $ "Failed to download " ++ show uri ++ " : " ++ show err
    Right rsp -> case rspCode rsp of
      (2,0,0) -> do
        info verbosity ("Downloaded to " ++ path)
        writeFileAtomic path $ rspBody rsp
      (3,0,4) -> notice verbosity "Skipping download: Local and remote files match."
      (_,_,_) -> return ()
      --FIXME: check the content-length header matches the body length.
      --TODO: stream the download into the file rather than buffering the whole
      --      thing in memory.

-- Utility function for legacy support.
isOldHackageURI :: URI -> Bool
isOldHackageURI uri
    = case uriAuthority uri of
        Just (URIAuth {uriRegName = "hackage.haskell.org"}) ->
            FilePath.Posix.splitDirectories (uriPath uri) == ["/","packages","archive"]
        _ -> False
