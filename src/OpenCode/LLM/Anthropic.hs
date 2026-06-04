-- | Anthropic provider: streaming completions via the Messages API (SSE).
module OpenCode.LLM.Anthropic
  ( -- * Provider
    AnthropicProvider (..)
  , defaultAnthropic
    -- * SSE event model (internal — exposed for tests)
  , AnthropicEvent (..)
  , BlockStart (..)
  , BlockDelta (..)
  , AnthropicAccum (..)
  , emptyAccum
  , decodeEvent
  , processAnthropicEvent
  , interpretAnthropicStream
    -- * Streaming
  , streamAnthropic
  , anthropicErrorFromHttp
  ) where

import Conduit (ConduitT, MonadIO, await, yield, (.|))
import Conduit qualified
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Trans.Resource (ResourceT)
import Data.Aeson (FromJSON (..), withObject, (.:), (.:?))
import Data.Aeson qualified as Aeson
import Data.Aeson.Types (Parser)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
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

-- Provider -------------------------------------------------------------------

data AnthropicProvider = AnthropicProvider
  { apiKey  :: ApiKey
  , baseUrl :: Text
  }
  deriving stock (Show, Eq)

defaultAnthropic :: ApiKey -> AnthropicProvider
defaultAnthropic key = AnthropicProvider
  { apiKey  = key
  , baseUrl = "https://api.anthropic.com"
  }

-- SSE event model ------------------------------------------------------------

data BlockStart = BlockText | BlockToolUse Text Text   -- ^ id, name
  deriving stock (Show, Eq)

data BlockDelta = DeltaText Text | DeltaInputJson Text
  deriving stock (Show, Eq)

data AnthropicEvent
  = EvMessageStart Int            -- ^ input tokens
  | EvBlockStart Int BlockStart   -- ^ content index, block kind
  | EvBlockDelta Int BlockDelta   -- ^ content index, delta kind
  | EvBlockStop Int
  | EvMessageDelta (Maybe Int)    -- ^ output tokens
  | EvMessageStop
  | EvPing
  | EvError Text
  | EvOther
  deriving stock (Show, Eq)

instance FromJSON AnthropicEvent where
  parseJSON = withObject "AnthropicEvent" $ \o -> do
    ty <- o .: "type" :: Parser Text
    case ty of
      "message_start" -> do
        msg    <- o .: "message" :: Parser Aeson.Object
        mUsage <- msg .:? "usage" :: Parser (Maybe Aeson.Object)
        inp    <- case mUsage of
                    Just u  -> u .:? "input_tokens"
                    Nothing -> pure Nothing
        pure (EvMessageStart (fromMaybe 0 inp))
      "content_block_start" -> do
        idx <- o .: "index"
        blk <- o .: "content_block" :: Parser Aeson.Object
        bty <- blk .: "type" :: Parser Text
        case bty of
          "tool_use" -> do
            cid  <- blk .: "id"
            name <- blk .: "name"
            pure (EvBlockStart idx (BlockToolUse cid name))
          _ -> pure (EvBlockStart idx BlockText)
      "content_block_delta" -> do
        idx <- o .: "index"
        d   <- o .: "delta" :: Parser Aeson.Object
        dty <- d .: "type" :: Parser Text
        case dty of
          "text_delta"       -> EvBlockDelta idx . DeltaText      <$> d .: "text"
          "input_json_delta" -> EvBlockDelta idx . DeltaInputJson <$> d .: "partial_json"
          _                  -> pure EvOther
      "content_block_stop" -> EvBlockStop <$> o .: "index"
      "message_delta" -> do
        mUsage <- o .:? "usage" :: Parser (Maybe Aeson.Object)
        out    <- case mUsage of
                    Just u  -> u .:? "output_tokens"
                    Nothing -> pure Nothing
        pure (EvMessageDelta out)
      "message_stop" -> pure EvMessageStop
      "ping"         -> pure EvPing
      "error"        -> do
        err <- o .: "error" :: Parser Aeson.Object
        EvError <$> err .: "message"
      _ -> pure EvOther

-- | Decode one SSE payload as an 'AnthropicEvent'.
decodeEvent :: ByteString -> Either String AnthropicEvent
decodeEvent = Aeson.eitherDecodeStrict

-- Accumulator ----------------------------------------------------------------

data AnthropicAccum = AnthropicAccum
  { accBlocks :: Map Int Text   -- ^ content index → callId (tool_use blocks)
  , accInput  :: Int            -- ^ input tokens carried from message_start
  }
  deriving stock (Show, Eq)

emptyAccum :: AnthropicAccum
emptyAccum = AnthropicAccum Map.empty 0

-- | Consume one event, emitting zero or more 'StreamEvent's.
processAnthropicEvent :: AnthropicAccum -> AnthropicEvent -> ([StreamEvent], AnthropicAccum)
processAnthropicEvent acc ev = case ev of
  EvMessageStart inp -> ([], acc { accInput = inp })
  EvBlockStart idx (BlockToolUse cid name) ->
    ([ToolCallStart cid name], acc { accBlocks = Map.insert idx cid (accBlocks acc) })
  EvBlockStart _ BlockText -> ([], acc)
  EvBlockDelta _ (DeltaText t)
    | Text.null t -> ([], acc)
    | otherwise   -> ([TextDelta t], acc)
  EvBlockDelta idx (DeltaInputJson frag) ->
    case Map.lookup idx (accBlocks acc) of
      Just cid | not (Text.null frag) -> ([ToolCallArgDelta cid frag], acc)
      _                               -> ([], acc)
  EvBlockStop idx ->
    case Map.lookup idx (accBlocks acc) of
      Just cid -> ([ToolCallEnd cid], acc { accBlocks = Map.delete idx (accBlocks acc) })
      Nothing  -> ([], acc)
  EvMessageDelta (Just out) -> ([StreamDone (Usage (accInput acc) out Nothing Nothing)], acc)
  EvMessageDelta Nothing    -> ([], acc)   -- no usage available; StreamDone omitted
  EvMessageStop -> ([], acc)
  EvPing        -> ([], acc)
  EvError e     -> ([StreamError e], acc)
  EvOther       -> ([], acc)

-- Pure SSE → StreamEvent pipeline --------------------------------------------

interpretAnthropicStream :: MonadIO m => ConduitT ByteString StreamEvent m ()
interpretAnthropicStream = Request.chunkSSELines .| go emptyAccum
  where
    go acc = do
      mline <- await
      case mline of
        Nothing   -> pure ()
        Just line -> case Request.sseDataLine line of
          Nothing      -> go acc
          Just payload -> case decodeEvent payload of
            Left _   -> go acc
            Right ev -> do
              let (events, acc') = processAnthropicEvent acc ev
              mapM_ yield events
              go acc'

-- HTTP integration -----------------------------------------------------------

anthropicErrorFromHttp :: Int -> ByteString -> StreamEvent
anthropicErrorFromHttp status body =
  let snippet = BS.take 200 body
  in StreamError $
      "anthropic: " <> Text.pack (show status) <> ": " <> TextEnc.decodeUtf8With lenientDecode snippet

-- | Stream completions from Anthropic's Messages API via SSE.
streamAnthropic
  :: AnthropicProvider
  -> LLMRequest
  -> ConduitT () StreamEvent (ResourceT IO) ()
streamAnthropic provider req = do
  initReq <- liftIO $ HTTP.parseRequest (Text.unpack (baseUrl provider) <> "/v1/messages")
  let bodyBytes = Aeson.encode (Schema.buildAnthropicRequestBody req)
      headers =
        [ ("x-api-key", TextEnc.encodeUtf8 (unApiKey (apiKey provider)))
        , ("anthropic-version", "2023-06-01")
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
           then HTTP.getResponseBody response .| interpretAnthropicStream
           else do
             body <- HTTP.getResponseBody response .| Conduit.foldC
             yield (anthropicErrorFromHttp code body)

instance LLMProvider AnthropicProvider where
  streamCompletion = streamAnthropic
