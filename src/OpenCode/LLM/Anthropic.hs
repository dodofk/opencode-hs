-- | Anthropic provider: streaming completions via SSE.
module OpenCode.LLM.Anthropic
  ( AnthropicProvider (..)
  ) where

import OpenCode.LLM.Types (LLMProvider (..), LLMRequest)
import OpenCode.Types (ApiKey, StreamEvent)

-- ---------------------------------------------------------------------------
-- Provider record
-- ---------------------------------------------------------------------------

newtype AnthropicProvider = AnthropicProvider
  { apiKey :: ApiKey
  }
  deriving stock (Show, Eq)

-- ---------------------------------------------------------------------------
-- Instance (implemented in M11)
-- ---------------------------------------------------------------------------

instance LLMProvider AnthropicProvider where
  streamCompletion _ _ = error "OpenCode.LLM.Anthropic: not yet implemented (M11)"

-- Silence unused-import warnings for types needed until M11
_unused :: (LLMRequest, StreamEvent) -> ()
_unused _ = ()
