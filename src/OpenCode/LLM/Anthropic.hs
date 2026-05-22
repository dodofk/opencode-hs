-- | Anthropic provider: streaming completions via SSE.
module OpenCode.LLM.Anthropic
  ( AnthropicProvider (..)
  ) where

import Data.Text (Text)
import OpenCode.LLM.Types (LLMProvider (..), LLMRequest)
import OpenCode.Types (StreamEvent)

-- ---------------------------------------------------------------------------
-- Provider record
-- ---------------------------------------------------------------------------

data AnthropicProvider = AnthropicProvider
  { apiKey :: Text
  }
  deriving stock (Show, Eq)

-- ---------------------------------------------------------------------------
-- Instance (implemented in M3c)
-- ---------------------------------------------------------------------------

instance LLMProvider AnthropicProvider where
  streamCompletion _ _ = error "OpenCode.LLM.Anthropic: not yet implemented (M3c)"

-- Silence unused-import warnings for types needed in M3c
_unused :: (LLMRequest, StreamEvent) -> ()
_unused _ = ()
