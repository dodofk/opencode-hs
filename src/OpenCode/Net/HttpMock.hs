-- | A pure, URL-keyed HTTP backend for tests. Never touches the network.
module OpenCode.Net.HttpMock
  ( mockBackend
  , mockBackendExact
  ) where

import Data.ByteString (ByteString)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as Text

import OpenCode.Net.Http (HttpBackend, HttpError (..), HttpRequest (..))

-- | Build a backend that returns the first response whose key is a
-- /substring/ of the request URL. The first match wins, in ascending key
-- order. Substring matching keeps fixtures robust to query-string
-- reordering (Brave/GitHub append params we don't always care about).
--
-- Unmatched URLs return a 404-style 'HttpError', so a missing fixture fails
-- loudly rather than silently returning empty.
mockBackend :: [(Text, Either HttpError ByteString)] -> HttpBackend
mockBackend pairs =
  let table = Map.fromList pairs
  in \req -> pure (lookupSubstring table (hrUrl req))

lookupSubstring :: Map.Map Text (Either HttpError ByteString) -> Text -> Either HttpError ByteString
lookupSubstring table url =
  case [ resp | (key, resp) <- Map.toAscList table, Text.isInfixOf key url ] of
    (r : _) -> r
    []      -> Left (HttpError 404 ("mock: no response matches URL " <> url))

-- | A stricter alternative: match the URL /exactly/. Use when a test cares
-- about the precise request (including query string).
mockBackendExact :: [(Text, Either HttpError ByteString)] -> HttpBackend
mockBackendExact pairs = \req -> pure $
  case lookup (hrUrl req) pairs of
    Just r  -> r
    Nothing -> Left (HttpError 404 ("mock: no exact match for " <> hrUrl req))
