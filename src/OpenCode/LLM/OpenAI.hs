-- | OpenAI provider: streaming completions via SSE.
module OpenCode.LLM.OpenAI
  ( OpenAIProvider (..)
  , defaultOpenAI
  ) where

import Data.Text (Text)
import OpenCode.LLM.Types (LLMProvider (..), LLMRequest)
import OpenCode.Types (StreamEvent)

-- ---------------------------------------------------------------------------
-- Provider record
-- ---------------------------------------------------------------------------

data OpenAIProvider = OpenAIProvider
  { apiKey  :: Text
  , baseUrl :: Text   -- ^ defaults to "https://api.openai.com"
  }
  deriving stock (Show, Eq)

-- ---------------------------------------------------------------------------
-- Instance (implemented in M3b)
-- ---------------------------------------------------------------------------

instance LLMProvider OpenAIProvider where
  streamCompletion _ _ = error "OpenCode.LLM.OpenAI: not yet implemented (M3b)"

-- | Default provider pointing at the public OpenAI endpoint.
defaultOpenAI :: Text -> OpenAIProvider
defaultOpenAI key = OpenAIProvider
  { apiKey  = key
  , baseUrl = "https://api.openai.com"
  }

-- Silence unused-import warnings for types needed in M3b
_unused :: (LLMRequest, StreamEvent) -> ()
_unused _ = ()
