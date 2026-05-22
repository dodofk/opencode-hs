-- | OpenAI provider: streaming completions via SSE.
module OpenCode.LLM.OpenAI
  ( OpenAIProvider (..)
  ) where

import Conduit (ConduitT)
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
  streamCompletion _ _ = error "OpenCode.LLM.OpenAI: not yet implemented"

-- | Default provider pointing at the public OpenAI endpoint.
defaultOpenAI :: Text -> OpenAIProvider
defaultOpenAI key = OpenAIProvider
  { apiKey  = key
  , baseUrl = "https://api.openai.com"
  }
{-# INLINE defaultOpenAI #-}

-- Silence unused warning until M3b
_defaultOpenAI :: Text -> OpenAIProvider
_defaultOpenAI = defaultOpenAI
