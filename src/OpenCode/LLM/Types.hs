-- | Shared types for the LLM client layer.
module OpenCode.LLM.Types
  ( ToolDefinition (..)
  , LLMRequest (..)
  , LLMProvider (..)
  ) where

import Conduit (ConduitT)
import Data.Aeson (Value)
import Data.Text (Text)
import OpenCode.Types (Message, StreamEvent)

-- ---------------------------------------------------------------------------
-- Tool definition (sent to the LLM so it knows what tools are available)
-- ---------------------------------------------------------------------------

data ToolDefinition = ToolDefinition
  { tdName        :: Text
  , tdDescription :: Text
  , tdSchema      :: Value   -- ^ JSON Schema object
  }
  deriving stock (Show, Eq)

-- ---------------------------------------------------------------------------
-- Request
-- ---------------------------------------------------------------------------

data LLMRequest = LLMRequest
  { reqMessages     :: [Message]
  , reqTools        :: [ToolDefinition]
  , reqSystemPrompt :: Text
  , reqMaxTokens    :: Int
  }
  deriving stock (Show, Eq)

-- ---------------------------------------------------------------------------
-- Provider typeclass
-- ---------------------------------------------------------------------------

class LLMProvider p where
  streamCompletion
    :: p
    -> LLMRequest
    -> ConduitT () StreamEvent IO ()
