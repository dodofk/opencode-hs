-- | TUI state, resource names, and the event type shared with the session loop.
module OpenCode.TUI.Types
  ( ResourceName (..)
  , AppState (..)
  , SessionEvent (..)
  , RenderedMessage (..)
  ) where

import Brick.BChan (BChan)
import Brick.Widgets.Edit (Editor)
import Data.Sequence (Seq)
import Data.Text (Text)
import OpenCode.Session (RunState (..))
import OpenCode.Types (Message, Usage)

-- ---------------------------------------------------------------------------
-- Resource names (used by brick to identify widgets / viewports)
-- ---------------------------------------------------------------------------

data ResourceName
  = ChatViewport
  | InputEditor
  | StatusBar
  deriving stock (Show, Eq, Ord)

-- ---------------------------------------------------------------------------
-- Rendered message (display-ready form)
-- ---------------------------------------------------------------------------

data RenderedMessage = RenderedMessage
  { rmRole    :: Text
  , rmContent :: Text      -- ^ markdown-stripped plain text for now
  }
  deriving stock (Show, Eq)

-- ---------------------------------------------------------------------------
-- App state
-- ---------------------------------------------------------------------------

data AppState = AppState
  { asMessages   :: Seq RenderedMessage
  , asInput      :: Editor Text ResourceName
  , asRunState   :: RunState
  , asStatusLine :: Text
  , asEventChan  :: BChan SessionEvent
  }

-- ---------------------------------------------------------------------------
-- Events sent from the session loop to the TUI
-- ---------------------------------------------------------------------------

data SessionEvent
  = MessageAppended Message
  | PartialText Text           -- ^ streaming text delta
  | ToolStarted Text           -- ^ tool name
  | ToolFinished Text Text     -- ^ tool name, result summary
  | RunStateChanged RunState
  | TokensUpdated Usage
  | ErrorOccurred Text
  deriving stock (Show, Eq)
