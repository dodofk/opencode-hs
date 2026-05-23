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
  ) where

import Data.Aeson (FromJSON (..), withObject, (.:), (.:?))
import Data.Aeson qualified as Aeson
import Data.ByteString (ByteString)
import Data.Foldable (foldl')
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (isJust)
import Data.Text (Text)
import Data.Text qualified as Text

import OpenCode.LLM.Types (LLMProvider (..), LLMRequest)
import OpenCode.Types (ApiKey, StreamEvent (..), Usage (..))

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
-- Instance (implemented in M4)
-- ---------------------------------------------------------------------------

instance LLMProvider OpenAIProvider where
  streamCompletion _ _ = error "OpenCode.LLM.OpenAI: not yet implemented (M4)"

-- | Default provider pointing at the public OpenAI endpoint.
defaultOpenAI :: ApiKey -> OpenAIProvider
defaultOpenAI key = OpenAIProvider
  { apiKey  = key
  , baseUrl = "https://api.openai.com"
  }

-- Silence unused-import warnings for types needed in M4
_unused :: LLMRequest -> ()
_unused _ = ()
