-- | Agentic conversation loop: drives LLM streaming and tool execution.
module OpenCode.Session
  ( RunState (..)
  , createSession
  , loadSession
  , processUserMessage
  , abortSession
  ) where

import Data.Text (Text)
import OpenCode.App (AppM)
import OpenCode.Types (ModelId, SessionId)

-- ---------------------------------------------------------------------------
-- Run state
-- ---------------------------------------------------------------------------

data RunState
  = Idle
  | RunningLLM
  | RunningTool Text    -- ^ currently-executing tool name
  | AwaitingInput
  deriving stock (Show, Eq)

-- ---------------------------------------------------------------------------
-- Stubs (implemented in M5)
-- ---------------------------------------------------------------------------

createSession :: ModelId -> AppM SessionId
createSession _ = error "OpenCode.Session.createSession: not yet implemented"

loadSession :: SessionId -> AppM ()
loadSession _ = error "OpenCode.Session.loadSession: not yet implemented"

processUserMessage :: SessionId -> Text -> AppM ()
processUserMessage _ _ = error "OpenCode.Session.processUserMessage: not yet implemented"

abortSession :: SessionId -> AppM ()
abortSession _ = error "OpenCode.Session.abortSession: not yet implemented"
