-- | Core ADTs shared across the application.
--
-- Everything that crosses module boundaries lives here.
-- No module should import from a sibling to get at basic types.
module OpenCode.Types
  ( -- * Identity wrappers
    SessionId (..)
  , MessageId (..)
  , ApiKey (..)
    -- * Provider / model
  , ProviderId (..)
  , ModelId (..)
    -- * Messages
  , Role (..)
  , MessagePart (..)
  , Message (..)
    -- * LLM tool protocol
  , ToolCall (..)
  , ToolResult (..)
    -- * Streaming events
  , StreamEvent (..)
  , Usage (..)
  ) where

import Data.Aeson (FromJSON, ToJSON)
import Data.List.NonEmpty (NonEmpty)
import Data.Text (Text)
import Data.Time (UTCTime)
import GHC.Generics (Generic)

-- ---------------------------------------------------------------------------
-- Identity wrappers
-- ---------------------------------------------------------------------------

newtype SessionId = SessionId {unSessionId :: Text}
  deriving stock (Show, Eq, Ord, Generic)
  deriving newtype (FromJSON, ToJSON)

newtype MessageId = MessageId {unMessageId :: Text}
  deriving stock (Show, Eq, Ord, Generic)
  deriving newtype (FromJSON, ToJSON)

-- | Opaque API key — never printed via Show.
newtype ApiKey = ApiKey {unApiKey :: Text}
  deriving stock (Eq, Generic)
  deriving newtype (FromJSON, ToJSON)

instance Show ApiKey where
  show _ = "ApiKey <redacted>"

-- ---------------------------------------------------------------------------
-- Provider / model
-- ---------------------------------------------------------------------------

data ProviderId
  = OpenAI
  | Anthropic
  deriving stock (Show, Eq, Ord, Generic)
  deriving anyclass (FromJSON, ToJSON)

data ModelId = ModelId
  { provider :: ProviderId
  , model    :: Text
  }
  deriving stock (Show, Eq, Ord, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- ---------------------------------------------------------------------------
-- Messages
-- ---------------------------------------------------------------------------

data Role
  = RoleUser
  | RoleAssistant
  | RoleTool
  deriving stock (Show, Eq, Ord, Generic)
  deriving anyclass (FromJSON, ToJSON)

data MessagePart
  = TextPart Text
  | ToolCallPart ToolCall
  | ToolResultPart ToolResult
  | ErrorPart Text
  deriving stock (Show, Eq, Generic)
  deriving anyclass (FromJSON, ToJSON)

data Message = Message
  { msgId      :: MessageId
  , msgRole    :: Role
  , msgParts   :: NonEmpty MessagePart
  , msgCreated :: UTCTime
  }
  deriving stock (Show, Eq, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- ---------------------------------------------------------------------------
-- Tool call / result
-- ---------------------------------------------------------------------------

data ToolCall = ToolCall
  { callId    :: Text
  , toolName  :: Text
  , arguments :: ToolArgs
  }
  deriving stock (Show, Eq, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | Raw JSON arguments passed to a tool (object shape determined per-tool).
newtype ToolArgs = ToolArgs {unToolArgs :: Text}
  deriving stock (Show, Eq, Generic)
  deriving newtype (FromJSON, ToJSON)

data ToolResult = ToolResult
  { resultCallId :: Text
  , content      :: Text
  , isError      :: Bool
  }
  deriving stock (Show, Eq, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- ---------------------------------------------------------------------------
-- Streaming events
-- ---------------------------------------------------------------------------

data StreamEvent
  = TextDelta Text
  | ToolCallStart Text Text        -- ^ callId toolName
  | ToolCallArgDelta Text Text     -- ^ callId argFragment
  | ToolCallEnd Text               -- ^ callId (arguments fully received)
  | StreamDone Usage
  | StreamError Text
  deriving stock (Show, Eq, Generic)
  deriving anyclass (FromJSON, ToJSON)

data Usage = Usage
  { inputTokens  :: Int
  , outputTokens :: Int
  , cacheRead    :: Maybe Int
  , cacheWrite   :: Maybe Int
  }
  deriving stock (Show, Eq, Generic)
  deriving anyclass (FromJSON, ToJSON)
