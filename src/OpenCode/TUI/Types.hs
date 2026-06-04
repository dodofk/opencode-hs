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

import Brick.Widgets.Edit (Editor)
import Data.Sequence (Seq)
import Data.Text (Text)

import OpenCode.App.Types (AppEnv)
import OpenCode.Session.Events (RunState (..), SessionEvent (..))
import OpenCode.Types (Message, SessionId)

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

-- | The full UI state. M9 adds 'asPartialText' (the in-flight streaming
-- buffer) and embeds 'asEnv'/'asSessionId' so the Enter/Esc handlers can fork
-- the session loop and flip the abort flag. The event channel is reached via
-- @envEventChan asEnv@.
data AppState = AppState
  { asMessages         :: Seq Message
  , asInput            :: Editor Text ResourceName
  , asRunState         :: RunState
  , asStatusLine       :: Text
  , asPartialText      :: Text
  , asPartialReasoning :: Text
  , asRound            :: Maybe (Int, Int)
  , asEnv              :: AppEnv
  , asSessionId        :: SessionId
  }
