-- | TUI state and resource names.
--
-- The streaming 'SessionEvent' type and 'RunState' live in
-- 'OpenCode.Session.Events'; this module re-exports them so callers can keep
-- 'OpenCode.TUI.Types' as a single import for everything UI-related.
module OpenCode.TUI.Types
  ( ResourceName (..)
  , AppState (..)
  , RunState (..)
  , SessionEvent (..)
  ) where

import Brick.BChan (BChan)
import Brick.Widgets.Edit (Editor)
import Data.Sequence (Seq)
import Data.Text (Text)

import OpenCode.Session.Events (RunState (..), SessionEvent (..))
import OpenCode.Types (Message)

-- ---------------------------------------------------------------------------
-- Resource names (used by brick to identify widgets / viewports)
-- ---------------------------------------------------------------------------

data ResourceName
  = ChatViewport
  | InputEditor
  | StatusBar
  deriving stock (Show, Eq, Ord)

-- ---------------------------------------------------------------------------
-- App state
-- ---------------------------------------------------------------------------

-- | The full UI state. In M8 (static layout) only 'asMessages', 'asInput',
-- 'asRunState', and 'asStatusLine' drive rendering. 'asEventChan' is carried
-- so M9 can pump 'SessionEvent's from the session loop without reshaping the
-- state.
data AppState = AppState
  { asMessages   :: Seq Message
  , asInput      :: Editor Text ResourceName
  , asRunState   :: RunState
  , asStatusLine :: Text
  , asEventChan  :: BChan SessionEvent
  }
