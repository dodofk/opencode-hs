-- | OpenAI provider: streaming completions via SSE.
module OpenCode.LLM.OpenAI
  ( OpenAIProvider (..)
  , defaultOpenAI
  ) where

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
