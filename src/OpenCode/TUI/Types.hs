-- | TUI state and resource names.
--
-- The streaming 'SessionEvent' type and 'RunState' live in
-- 'OpenCode.Session.Events'; this module re-exports them so callers can keep
-- 'OpenCode.TUI.Types' as a single import for everything UI-related.
module OpenCode.TUI.Types
  ( ResourceName (..)
  , AppState (..)
  , UIMode (..)
  , Overlay (..)
  , OverlayKind (..)
  , RunState (..)
  , SessionEvent (..)
  ) where

import Brick.Widgets.Edit (Editor)
import Data.Sequence (Seq)
import Data.Text (Text)

import OpenCode.App.Types (AppEnv)
import OpenCode.Skill.Types (Skill)
import OpenCode.Session.Events (RunState (..), SessionEvent (..))
import OpenCode.Types (Message, ModelId, Session, SessionId)

-- ---------------------------------------------------------------------------
-- Resource names (used by brick to identify widgets / viewports)
-- ---------------------------------------------------------------------------

data ResourceName
  = ChatViewport
  | InputEditor
  | StatusBar
  deriving stock (Show, Eq, Ord)

-- ---------------------------------------------------------------------------
-- Overlay (modal picker) — pure data; logic in OpenCode.TUI.Overlay,
-- rendering in OpenCode.TUI.Render.
-- ---------------------------------------------------------------------------

data UIMode
  = ModeNormal
  | ModeOverlay Overlay
  deriving stock (Show, Eq)

data Overlay = Overlay
  { ovTitle :: Text
  , ovSel   :: Int            -- ^ selected row, clamped to [0, count-1]
  , ovKind  :: OverlayKind
  }
  deriving stock (Show, Eq)

data OverlayKind
  = OverlaySessions SessionId [Session]  -- ^ current id (for the * marker) + rows
  | OverlayModels   ModelId   [ModelId]  -- ^ current model (* marker + preselect) + rows
  | OverlayHelp     [Text]               -- ^ non-actionable lines
  | OverlaySkills   [Skill]              -- ^ discovered skills (pick to run)
  deriving stock (Show, Eq)

-- ---------------------------------------------------------------------------
-- App state
-- ---------------------------------------------------------------------------

-- | The full UI state. 'asMode' drives the modal overlay; 'asNotice' is a
-- transient one-line status-bar message (block hint, model-set confirmation,
-- unknown-command); 'asSuggestSel' is the highlighted row of the non-modal
-- slash-command autocomplete panel (visibility is derived from the input text,
-- so only the index is stored). The event channel is reached via
-- @envEventChan asEnv@.
data AppState = AppState
  { asMessages         :: Seq Message
  , asInput            :: Editor Text ResourceName
  , asRunState         :: RunState
  , asStatusLine       :: Text
  , asPartialText      :: Text
  , asPartialReasoning :: Text
  , asRound            :: Maybe (Int, Int)
  , asTitle            :: Text
  , asEnv              :: AppEnv
  , asSessionId        :: SessionId
  , asMode             :: UIMode
  , asNotice           :: Maybe Text
  , asSuggestSel       :: Int
  }
