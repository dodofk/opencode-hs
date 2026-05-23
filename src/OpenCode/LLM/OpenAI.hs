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
  ) where

import Data.Aeson (FromJSON (..), withObject, (.:), (.:?))
import Data.Aeson qualified as Aeson
import Data.ByteString (ByteString)
import Data.Text (Text)

import OpenCode.LLM.Types (LLMProvider (..), LLMRequest)
import OpenCode.Types (ApiKey, StreamEvent)

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

-- Silence unused-import warnings for types needed in M3b
_unused :: (LLMRequest, StreamEvent) -> ()
_unused _ = ()
