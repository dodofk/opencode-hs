-- | Shared types for the LLM client layer.
module OpenCode.LLM.Types
  ( ToolDefinition (..)
  , LLMRequest (..)
  , LLMProvider (..)
  , Streamer
  ) where

import Conduit (ConduitT)
import Control.Monad.Trans.Resource (ResourceT)
import Data.Aeson (Value)
import Data.Text (Text)
import OpenCode.Types (Message, StreamEvent)

-- ---------------------------------------------------------------------------
-- Tool definition (sent to the LLM so it knows what tools are available)
-- ---------------------------------------------------------------------------

data ToolDefinition = ToolDefinition
  { tdName        :: Text
  , tdDescription :: Text
  , tdSchema      :: Value   -- ^ JSON Schema object describing the input
  }
  deriving stock (Show, Eq)

-- ---------------------------------------------------------------------------
-- Request
-- ---------------------------------------------------------------------------

data LLMRequest = LLMRequest
  { reqModel        :: Text         -- ^ Model identifier, e.g. "gpt-4o"
  , reqMessages     :: [Message]    -- ^ Conversation history; system goes in reqSystemPrompt
  , reqTools        :: [ToolDefinition]
  , reqSystemPrompt :: Text         -- ^ Empty string means no system prompt
  , reqMaxTokens    :: Maybe Int    -- ^ Nothing = let the provider pick its default
  }
  deriving stock (Show, Eq)

-- ---------------------------------------------------------------------------
-- Provider typeclass
-- ---------------------------------------------------------------------------

class LLMProvider p where
  streamCompletion
    :: p
    -> LLMRequest
    -> ConduitT () StreamEvent (ResourceT IO) ()

-- ---------------------------------------------------------------------------
-- Streaming function alias
-- ---------------------------------------------------------------------------

-- | A streaming-completion function. Pure with respect to provider choice:
-- production code partial-applies 'streamOpenAI' or 'streamAnthropic' to get
-- one of these; tests use mock-based variants.
type Streamer = LLMRequest -> ConduitT () StreamEvent (ResourceT IO) ()
