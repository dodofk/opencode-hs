-- | Core ADTs shared across the application.
--
-- Everything that crosses module boundaries lives here.
-- No sibling module should be imported just to get at basic types.
module OpenCode.Types
  ( -- * Identity wrappers
    SessionId (..)
  , MessageId (..)
  , ApiKey (..)
    -- * Provider / model
  , ProviderId (..)
  , ModelId (..)
    -- * Session
  , Session (..)
    -- * Messages
  , Role (..)
  , MessagePart (..)
  , Message (..)
    -- * LLM tool protocol
  , ToolCall (..)
  , ToolArgs (..)
  , ToolResult (..)
    -- * Streaming events
  , StreamEvent (..)
  , Usage (..)
  ) where

import Data.Aeson
  ( FromJSON (..)
  , ToJSON (..)
  , Value (..)
  , genericParseJSON
  , genericToJSON
  , defaultOptions
  , withObject
  , withText
  , (.:)
  , object
  , (.=)
  )
import Data.List.NonEmpty (NonEmpty)
import Data.Text (Text)
import Data.Text qualified as Text
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

-- | Opaque API key — deliberately not shown via Show.
newtype ApiKey = ApiKey {unApiKey :: Text}
  deriving stock (Eq, Generic)
  deriving newtype (FromJSON, ToJSON)

instance Show ApiKey where
  show _ = "ApiKey <redacted>"

-- ---------------------------------------------------------------------------
-- Provider / model
--
-- JSON representation uses lowercase strings ("openai", "anthropic",
-- "minimax") so that the config YAML is human-friendly.
-- ---------------------------------------------------------------------------

data ProviderId
  = OpenAI
  | Anthropic
  | MiniMax     -- ^ MiniMax; served over an OpenAI-compatible endpoint.
  deriving stock (Show, Eq, Ord, Generic)

instance ToJSON ProviderId where
  toJSON OpenAI    = String "openai"
  toJSON Anthropic = String "anthropic"
  toJSON MiniMax   = String "minimax"

instance FromJSON ProviderId where
  parseJSON = withText "ProviderId" $ \case
    "openai"    -> pure OpenAI
    "anthropic" -> pure Anthropic
    "minimax"   -> pure MiniMax
    other       -> fail $ "Unknown provider id: " <> Text.unpack other

data ModelId = ModelId
  { provider :: ProviderId
  , model    :: Text
  }
  deriving stock (Show, Eq, Ord, Generic)

instance ToJSON ModelId where
  toJSON m = object ["provider" .= provider m, "model" .= model m]

instance FromJSON ModelId where
  parseJSON = withObject "ModelId" $ \o ->
    ModelId <$> o .: "provider" <*> o .: "model"

-- ---------------------------------------------------------------------------
-- Session
-- ---------------------------------------------------------------------------

data Session = Session
  { sessionId      :: SessionId
  , sessionTitle   :: Text
  , sessionModel   :: ModelId
  , sessionCreated :: UTCTime
  }
  deriving stock (Show, Eq, Generic)

instance ToJSON   Session where toJSON   = genericToJSON   defaultOptions
instance FromJSON Session where parseJSON = genericParseJSON defaultOptions

-- ---------------------------------------------------------------------------
-- Messages
-- ---------------------------------------------------------------------------

data Role
  = RoleUser
  | RoleAssistant
  | RoleTool
  deriving stock (Show, Eq, Ord, Generic)

instance ToJSON   Role where toJSON   = genericToJSON   defaultOptions
instance FromJSON Role where parseJSON = genericParseJSON defaultOptions

data MessagePart
  = TextPart Text
  | ToolCallPart ToolCall
  | ToolResultPart ToolResult
  | ErrorPart Text
  deriving stock (Show, Eq, Generic)

instance ToJSON   MessagePart where toJSON   = genericToJSON   defaultOptions
instance FromJSON MessagePart where parseJSON = genericParseJSON defaultOptions

data Message = Message
  { msgId      :: MessageId
  , msgRole    :: Role
  , msgParts   :: NonEmpty MessagePart
  , msgCreated :: UTCTime
  }
  deriving stock (Show, Eq, Generic)

instance ToJSON   Message where toJSON   = genericToJSON   defaultOptions
instance FromJSON Message where parseJSON = genericParseJSON defaultOptions

-- ---------------------------------------------------------------------------
-- Tool call / result
-- ---------------------------------------------------------------------------

data ToolCall = ToolCall
  { callId    :: Text
  , toolName  :: Text
  , arguments :: ToolArgs
  }
  deriving stock (Show, Eq, Generic)

instance ToJSON   ToolCall where toJSON   = genericToJSON   defaultOptions
instance FromJSON ToolCall where parseJSON = genericParseJSON defaultOptions

-- | Raw JSON arguments, stored as a text blob to avoid re-parsing.
newtype ToolArgs = ToolArgs {unToolArgs :: Text}
  deriving stock (Show, Eq, Generic)
  deriving newtype (FromJSON, ToJSON)

data ToolResult = ToolResult
  { resultCallId :: Text
  , content      :: Text
  , isError      :: Bool
  }
  deriving stock (Show, Eq, Generic)

instance ToJSON   ToolResult where toJSON   = genericToJSON   defaultOptions
instance FromJSON ToolResult where parseJSON = genericParseJSON defaultOptions

-- ---------------------------------------------------------------------------
-- Streaming events
-- ---------------------------------------------------------------------------

data StreamEvent
  = TextDelta Text
  | ToolCallStart Text Text       -- ^ callId toolName
  | ToolCallArgDelta Text Text    -- ^ callId argFragment
  | ToolCallEnd Text              -- ^ callId (arguments fully received)
  | StreamDone Usage
  | StreamError Text
  deriving stock (Show, Eq, Generic)

instance ToJSON   StreamEvent where toJSON   = genericToJSON   defaultOptions
instance FromJSON StreamEvent where parseJSON = genericParseJSON defaultOptions

data Usage = Usage
  { inputTokens  :: Int
  , outputTokens :: Int
  , cacheRead    :: Maybe Int
  , cacheWrite   :: Maybe Int
  }
  deriving stock (Show, Eq, Generic)

instance ToJSON   Usage where toJSON   = genericToJSON   defaultOptions
instance FromJSON Usage where parseJSON = genericParseJSON defaultOptions
