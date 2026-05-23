-- | OpenAI provider: streaming completions via SSE.
module OpenCode.LLM.OpenAI
  ( -- * Provider
    OpenAIProvider (..)
  , defaultOpenAI
    -- * Wire types (internal — exposed for tests)
  , ChatCompletionChunk (..)
  , Choice (..)
  , Delta (..)
  , ToolCallDelta (..)
  , FunctionDelta (..)
  , ChatCompletionUsage (..)
  , decodeChunk
    -- * Streaming pipeline (internal — exposed for tests)
  , ToolCallAccum
  , processChunk
  , interpretOpenAIStream
    -- * Streaming
  , streamOpenAI
  , streamErrorFromHttp
  ) where

import Conduit (ConduitT, MonadIO, await, yield, (.|))
import Conduit qualified
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Trans.Resource (ResourceT)
import Data.Aeson (FromJSON (..), withObject, (.:), (.:?))
import Data.Aeson qualified as Aeson
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Foldable (foldl')
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (isJust)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEnc
import Data.Text.Encoding.Error (lenientDecode)
import Network.HTTP.Conduit (responseTimeout, responseTimeoutNone)
import Network.HTTP.Simple (setRequestBodyLBS, setRequestHeaders, setRequestMethod)
import Network.HTTP.Simple qualified as HTTP
import Network.HTTP.Types (statusCode)

import OpenCode.LLM.Request qualified as Request
import OpenCode.LLM.Schema qualified as Schema
import OpenCode.LLM.Types (LLMProvider (..), LLMRequest)
import OpenCode.Types (ApiKey, StreamEvent (..), Usage (..), unApiKey)

-- ---------------------------------------------------------------------------
-- Provider record
-- ---------------------------------------------------------------------------

data OpenAIProvider = OpenAIProvider
  { apiKey  :: ApiKey
  , baseUrl :: Text         -- ^ defaults to "https://api.openai.com"
  }
  deriving stock (Show, Eq)

-- ---------------------------------------------------------------------------
-- Wire types (internal — exposed for tests)
-- ---------------------------------------------------------------------------

-- | One chunk of OpenAI's streaming chat-completion response.
-- Field names mirror the OpenAI JSON shape (snake_case → camelCase prefix).
data ChatCompletionChunk = ChatCompletionChunk
  { cccId      :: Text
  , cccChoices :: [Choice]
  , cccUsage   :: Maybe ChatCompletionUsage
  }
  deriving stock (Show, Eq)

data Choice = Choice
  { choiceIndex        :: Int
  , choiceDelta        :: Delta
  , choiceFinishReason :: Maybe Text
  }
  deriving stock (Show, Eq)

data Delta = Delta
  { deltaContent   :: Maybe Text
  , deltaToolCalls :: Maybe [ToolCallDelta]
  }
  deriving stock (Show, Eq)

data ToolCallDelta = ToolCallDelta
  { tcdIndex    :: Int
  , tcdId       :: Maybe Text
  , tcdFunction :: Maybe FunctionDelta
  }
  deriving stock (Show, Eq)

data FunctionDelta = FunctionDelta
  { fdName      :: Maybe Text
  , fdArguments :: Maybe Text
  }
  deriving stock (Show, Eq)

data ChatCompletionUsage = ChatCompletionUsage
  { ccUsagePromptTokens     :: Int
  , ccUsageCompletionTokens :: Int
  , ccUsageTotalTokens      :: Int
  }
  deriving stock (Show, Eq)

instance FromJSON ChatCompletionChunk where
  parseJSON = withObject "ChatCompletionChunk" $ \o ->
    ChatCompletionChunk
      <$> o .:  "id"
      <*> o .:  "choices"
      <*> o .:? "usage"

instance FromJSON Choice where
  parseJSON = withObject "Choice" $ \o ->
    Choice
      <$> o .:  "index"
      <*> o .:  "delta"
      <*> o .:? "finish_reason"

instance FromJSON Delta where
  parseJSON = withObject "Delta" $ \o ->
    Delta
      <$> o .:? "content"
      <*> o .:? "tool_calls"

instance FromJSON ToolCallDelta where
  parseJSON = withObject "ToolCallDelta" $ \o ->
    ToolCallDelta
      <$> o .:  "index"
      <*> o .:? "id"
      <*> o .:? "function"

instance FromJSON FunctionDelta where
  parseJSON = withObject "FunctionDelta" $ \o ->
    FunctionDelta
      <$> o .:? "name"
      <*> o .:? "arguments"

instance FromJSON ChatCompletionUsage where
  parseJSON = withObject "ChatCompletionUsage" $ \o ->
    ChatCompletionUsage
      <$> o .: "prompt_tokens"
      <*> o .: "completion_tokens"
      <*> o .: "total_tokens"

-- | Decode one SSE payload as a 'ChatCompletionChunk'.
decodeChunk :: ByteString -> Either String ChatCompletionChunk
decodeChunk = Aeson.eitherDecodeStrict

-- ---------------------------------------------------------------------------
-- Tool-call accumulator state
--
-- Tracks per-tool-call-index (within a single choice) whether ToolCallStart
-- has been emitted yet (so we know to emit ToolCallEnd at finish time) and
-- the call id we observed. OpenAI guarantees that the first chunk for a
-- given index supplies both id and function.name; subsequent chunks for the
-- same index only carry function.arguments fragments.
-- ---------------------------------------------------------------------------

type ToolCallAccum = Map Int Text   -- ^ index → callId

-- | Consume one chunk and emit zero or more 'StreamEvent's, updating the
-- accumulator state.
processChunk
  :: ToolCallAccum
  -> ChatCompletionChunk
  -> ([StreamEvent], ToolCallAccum)
processChunk st chunk =
  let allChoices = cccChoices chunk
      (textEvents,  st1) = foldl' collectText  ([], st) allChoices
      (toolEvents,  st2) = foldl' collectTools (textEvents, st1) allChoices
      (finalEvents, st3) = foldl' collectFinish (toolEvents, st2) allChoices
      usageEvents = case cccUsage chunk of
        Just u  | any (isJust . choiceFinishReason) allChoices ->
                    [StreamDone (toUsage u)]
        _       -> []
  in (finalEvents ++ usageEvents, st3)
  where
    collectText (acc, s) ch = case deltaContent (choiceDelta ch) of
      Just t | not (Text.null t) -> (acc ++ [TextDelta t], s)
      _                          -> (acc, s)

    collectTools (acc, s) ch = case deltaToolCalls (choiceDelta ch) of
      Nothing  -> (acc, s)
      Just tcs -> foldl' processTC (acc, s) tcs

    processTC (acc, s) tcd =
      let idx = tcdIndex tcd
      in case Map.lookup idx s of
        Nothing ->
          -- First sighting: must have id + function.name.
          case (tcdId tcd, tcdFunction tcd >>= fdName) of
            (Just cid, Just tname) ->
              let s'     = Map.insert idx cid s
                  start  = ToolCallStart cid tname
                  args   = tcdFunction tcd >>= fdArguments
                  argEvt = case args of
                    Just a | not (Text.null a) -> [ToolCallArgDelta cid a]
                    _                          -> []
              in (acc ++ [start] ++ argEvt, s')
            _ -> (acc, s)   -- malformed first chunk; ignore quietly
        Just cid ->
          -- Subsequent chunk: argument fragment.
          let args = tcdFunction tcd >>= fdArguments
              argEvt = case args of
                Just a | not (Text.null a) -> [ToolCallArgDelta cid a]
                _                          -> []
          in (acc ++ argEvt, s)

    collectFinish (acc, s) ch = case choiceFinishReason ch of
      Nothing -> (acc, s)
      Just _  ->
        -- Emit ToolCallEnd for every in-flight tool call.
        let ends = map ToolCallEnd (Map.elems s)
        in (acc ++ ends, Map.empty)

toUsage :: ChatCompletionUsage -> Usage
toUsage u = Usage
  { inputTokens  = ccUsagePromptTokens u
  , outputTokens = ccUsageCompletionTokens u
  , cacheRead    = Nothing
  , cacheWrite   = Nothing
  }

-- ---------------------------------------------------------------------------
-- Pure SSE → StreamEvent pipeline (no HTTP)
-- ---------------------------------------------------------------------------

-- | Consume a raw SSE byte stream and emit 'StreamEvent's.
-- Pure with respect to networking; tested directly against fixture bodies.
interpretOpenAIStream
  :: MonadIO m
  => ConduitT ByteString StreamEvent m ()
interpretOpenAIStream =
  Request.chunkSSELines
    .| translateLines
  where
    translateLines = go Map.empty
    go st = do
      mline <- await
      case mline of
        Nothing   -> pure ()
        Just line -> case Request.sseDataLine line of
          Nothing       -> go st
          Just "[DONE]" -> pure ()
          Just payload  -> case decodeChunk payload of
            Left _      -> go st   -- ignore malformed chunks; production would log
            Right chunk -> do
              let (events, st') = processChunk st chunk
              mapM_ yield events
              go st'

-- | Default provider pointing at the public OpenAI endpoint.
defaultOpenAI :: ApiKey -> OpenAIProvider
defaultOpenAI key = OpenAIProvider
  { apiKey  = key
  , baseUrl = "https://api.openai.com"
  }

-- ---------------------------------------------------------------------------
-- HTTP integration
-- ---------------------------------------------------------------------------

-- | Build an HTTP error 'StreamEvent' from a status code + body bytes.
-- The body is truncated to a manageable snippet so log/UI surfaces don't
-- get flooded with massive HTML error pages.
streamErrorFromHttp :: Int -> ByteString -> StreamEvent
streamErrorFromHttp status body =
  let snippet = BS.take 200 body
  in StreamError $
      "openai: " <> Text.pack (show status) <> ": " <> TextEnc.decodeUtf8With lenientDecode snippet

-- | Stream completions from OpenAI via SSE.
-- On HTTP 2xx, pipes the response body through 'interpretOpenAIStream'.
-- On non-2xx, drains the body, emits a single 'StreamError', terminates.
streamOpenAI
  :: OpenAIProvider
  -> LLMRequest
  -> ConduitT () StreamEvent (ResourceT IO) ()
streamOpenAI provider req = do
  initReq <- liftIO $ HTTP.parseRequest (Text.unpack (baseUrl provider) <> "/v1/chat/completions")
  let bodyBytes = Aeson.encode (Schema.buildOpenAIRequestBody req)
      authHeader = ("Authorization", "Bearer " <> TextEnc.encodeUtf8 (unApiKey (apiKey provider)))
      headers =
        [ authHeader
        , ("Content-Type", "application/json")
        , ("Accept", "text/event-stream")
        ]
      httpReq = setRequestMethod "POST"
              . setRequestHeaders headers
              . setRequestBodyLBS bodyBytes
              $ initReq { responseTimeout = responseTimeoutNone }
  HTTP.httpSource httpReq dispatch
  where
    dispatch response =
      let code = statusCode (HTTP.getResponseStatus response)
      in if code >= 200 && code < 300
           then HTTP.getResponseBody response .| interpretOpenAIStream
           else do
             body <- HTTP.getResponseBody response .| Conduit.foldC
             yield (streamErrorFromHttp code body)

instance LLMProvider OpenAIProvider where
  streamCompletion = streamOpenAI
