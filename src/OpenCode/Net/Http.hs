-- | Shared HTTP substrate for networked tools (web_search, web_fetch,
-- github_*). One injectable backend so tests never touch the wire.
module OpenCode.Net.Http
  ( -- * Request / response types
    HttpRequest (..)
  , HttpError (..)
  , HttpBackend
    -- * Pure constructors
  , defaultRequest
  , withMethod
  , withHeader
  , withQuery
  , withBody
    -- * Pure helpers
  , httpErrorStatus
    -- * Live backend
  , runHttp
  ) where

import Control.Exception (SomeException, try)
import Data.ByteString (ByteString)
import qualified Data.ByteString.Char8 as BSC8
import qualified Data.CaseInsensitive as CI
import qualified Data.ByteString.Lazy as BSL
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Text.Encoding.Error (lenientDecode)
import qualified Data.Text.Encoding as TextEnc
import Network.HTTP.Simple
  ( getResponseBody
  , getResponseStatusCode
  , httpLBS
  , setRequestBodyLBS
  , setRequestHeaders
  , setRequestMethod
  )
import qualified Network.HTTP.Simple as HTTP
import System.Timeout (timeout)

-- ---------------------------------------------------------------------------
-- Request / response types
-- ---------------------------------------------------------------------------

-- | A tool's view of an HTTP request. Method/url/headers/body are kept as
-- 'Text'/'ByteString' so pure construction and the mock backend need no IO.
data HttpRequest = HttpRequest
  { hrMethod  :: Text          -- ^ "GET" | "POST"
  , hrUrl     :: Text
  , hrHeaders :: [(Text, Text)]
  , hrBody    :: Maybe ByteString
  }
  deriving stock (Show, Eq)

-- | A failure from the backend. @heStatus = 0@ means a transport-level
-- failure (DNS, TLS, connection refused, timeout); a real HTTP status means
-- the server responded but with a non-2xx code.
data HttpError = HttpError
  { heStatus :: Int
  , heBody   :: Text
  }
  deriving stock (Show, Eq)

-- | Injectable HTTP backend stored in 'AppEnv'. Production = 'runHttp';
-- tests supply a pure 'Map'-based function (see "OpenCode.Net.HttpMock").
type HttpBackend = HttpRequest -> IO (Either HttpError ByteString)

-- ---------------------------------------------------------------------------
-- Pure constructors
-- ---------------------------------------------------------------------------

-- | A GET request to the given URL with no headers and no body.
defaultRequest :: Text -> HttpRequest
defaultRequest url = HttpRequest
  { hrMethod  = "GET"
  , hrUrl     = url
  , hrHeaders = []
  , hrBody    = Nothing
  }

withMethod :: Text -> HttpRequest -> HttpRequest
withMethod m r = r { hrMethod = m }

withHeader :: Text -> Text -> HttpRequest -> HttpRequest
withHeader k v r = r { hrHeaders = hrHeaders r <> [(k, v)] }

withBody :: ByteString -> HttpRequest -> HttpRequest
withBody b r = r { hrBody = Just b }

-- | Append a query parameter, percent-encoding the value. Uses @?@ for the
-- first parameter and @&@ thereafter.
withQuery :: Text -> Text -> HttpRequest -> HttpRequest
withQuery key val r =
  let sep   = if Text.any (== '?') (hrUrl r) then "&" else "?"
      url'  = hrUrl r <> sep <> key <> "=" <> urlEncode val
  in r { hrUrl = url' }

-- ---------------------------------------------------------------------------
-- Pure percent-encoding (query values only)
-- ---------------------------------------------------------------------------

-- | Percent-encode a query value. Unreserved characters per RFC 3986
-- (@A-Za-z0-9-_.~@) pass through; everything else becomes @%XX@.
urlEncode :: Text -> Text
urlEncode = Text.concatMap encodeChar
  where
    encodeChar c
      | c `elem` unreserved = Text.singleton c
      | otherwise           = pct (fromEnum c)

    unreserved :: [Char]
    unreserved = ['A'..'Z'] <> ['a'..'z'] <> ['0'..'9'] <> "-_.~"

    pct n = "%" <> Text.justifyRight 2 '0' (Text.pack (showHexU n))

-- | Uppercase hex of a non-negative 'Int', no @0x@ prefix.
showHexU :: Int -> String
showHexU 0 = "0"
showHexU n = go n
  where
    go 0 = ""
    go k = go (k `div` 16) <> [hexDigit (k `mod` 16)]
    hexDigit d = "0123456789ABCDEF" !! d

-- ---------------------------------------------------------------------------
-- Pure helpers
-- ---------------------------------------------------------------------------

-- | The HTTP status carried by an 'HttpError' (0 for transport failures).
httpErrorStatus :: HttpError -> Int
httpErrorStatus = heStatus

-- ---------------------------------------------------------------------------
-- Live backend
-- ---------------------------------------------------------------------------

-- | Production HTTP backend. 30s timeout, TLS via the global TLS manager.
-- Non-2xx responses are returned as 'Left' carrying the status and response
-- body; transport failures (DNS, timeout, TLS, connection refused) become
-- 'Left' with @heStatus = 0@. The wall-clock timeout uses
-- 'System.Timeout.timeout' — the same idiom as 'OpenCode.MCP.Client' and
-- 'OpenCode.Tool.Bash'.
runHttp :: HttpRequest -> IO (Either HttpError ByteString)
runHttp req = do
  parsed <- try (HTTP.parseRequest (Text.unpack (hrUrl req)))
  case parsed of
    Left ex -> pure (Left (transportError ex))
    Right base -> do
      let applied = base
            & setRequestMethod (encodeBS (hrMethod req))
            & setRequestHeaders [ (CI.mk (encodeBS k), encodeBS v) | (k, v) <- hrHeaders req ]
            & setBody (hrBody req)
      mResp <- timeout requestTimeoutMicros (try (httpLBS applied))
      case mResp of
        Nothing            -> pure (Left timeoutError)
        Just (Left ex)     -> pure (Left (transportError ex))
        Just (Right r)     -> do
          let code = getResponseStatusCode r
              body = BSL.toStrict (getResponseBody r)
          if code >= 200 && code < 300
            then pure (Right body)
            else pure (Left (HttpError
              { heStatus = code
              , heBody   = TextEnc.decodeUtf8With lenientDecode body
              }))
  where
    encodeBS = BSC8.pack . Text.unpack
    setBody Nothing  r = r
    setBody (Just b) r = setRequestBodyLBS (BSL.fromStrict b) r

-- | Wall-clock timeout for a single 'runHttp' call, in microseconds (30s).
-- Matches 'OpenCode.MCP.Client.callTimeoutMicros' / 'OpenCode.Tool.Bash'.
requestTimeoutMicros :: Int
requestTimeoutMicros = 30 * 1_000_000

-- | The error returned when 'runHttp' exceeds the wall-clock timeout.
timeoutError :: HttpError
timeoutError = HttpError
  { heStatus = 0
  , heBody   = "http request timed out (30s)"
  }

transportError :: SomeException -> HttpError
transportError ex = HttpError
  { heStatus = 0
  , heBody   = Text.pack ("http transport error: " <> show ex)
  }

-- | Reverse-application for the builder chain above. Local to avoid pulling
-- in a dependency just for @(&)@.
infixl 1 &
(&) :: a -> (a -> b) -> b
x & f = f x
