-- | Session loop event types: 'SessionEvent' (drained from streaming) and
-- 'RunState' (current pipeline state).
--
-- Leaf module — depends only on 'OpenCode.Types' for 'Message'. Lives below
-- 'OpenCode.Session' in the dependency graph so 'OpenCode.App.Types' can
-- reference 'SessionEvent' without inducing a cycle.
module OpenCode.Session.Events
  ( SessionEvent (..)
  , RunState (..)
  ) where

import Data.Text (Text)
import OpenCode.Types (Message)

-- | What the session loop is currently doing. The TUI reads this for
-- status-bar rendering.
data RunState
  = Idle
  | RunningLLM
  | RunningTool Text    -- ^ currently-executing tool name
  | AwaitingInput
  deriving stock (Show, Eq)

-- | An event emitted by the session loop onto 'envEventChan'.
data SessionEvent
  = MessageAppended Message
      -- ^ A complete 'Message' was just persisted.
  | PartialText Text
      -- ^ A streaming text delta from the LLM.
  | ToolStarted Text
      -- ^ A tool execution is about to begin (carries the tool name).
  | ToolFinished Text Text
      -- ^ A tool execution completed (tool name, output text).
  | RunStateChanged RunState
      -- ^ The session's 'RunState' transitioned.
  | ErrorOccurred Text
      -- ^ An error to display to the user (transient; doesn't terminate the loop).
  deriving stock (Show, Eq)
