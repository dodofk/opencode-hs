-- | Agentic conversation loop: drives LLM streaming and tool execution.
module OpenCode.Session
  ( -- * Re-exports
    RunState (..)
  , SessionEvent (..)
    -- * Session management
  , createSession
  , loadSession
    -- * Event emission
  , emitEvent
    -- * Stubs (filled in by later M6 tasks)
  , processUserMessage
  , abortSession
  ) where

import qualified Brick.BChan as BChan
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Reader (asks)
import Data.Text (Text)
import Data.Time (getCurrentTime)

import OpenCode.App (AppEnv (..), AppM)
import qualified OpenCode.DB as DB
import OpenCode.Session.Events (RunState (..), SessionEvent (..))
import OpenCode.Types (ModelId, Session (..), SessionId)

-- ---------------------------------------------------------------------------
-- Session management
-- ---------------------------------------------------------------------------

-- | Create a new session with the given model. Default title is "untitled".
-- Persists immediately via 'insertSession'.
createSession :: ModelId -> AppM Session
createSession m = do
  sid  <- liftIO DB.newSessionId
  now  <- liftIO getCurrentTime
  let session = Session
        { sessionId      = sid
        , sessionTitle   = "untitled"
        , sessionModel   = m
        , sessionCreated = now
        }
  conn <- asks envDb
  liftIO (DB.insertSession conn session)
  pure session

-- | Look up a session by id.
loadSession :: SessionId -> AppM (Maybe Session)
loadSession sid = do
  conn <- asks envDb
  liftIO (DB.getSession conn sid)

-- ---------------------------------------------------------------------------
-- Event emission helper
-- ---------------------------------------------------------------------------

-- | Push a 'SessionEvent' onto 'envEventChan'. Used by the agentic loop to
-- broadcast progress to the TUI (M9). 'BChan.writeBChan' blocks if the
-- channel is full — for production sizing of 100+ this never blocks in
-- practice.
emitEvent :: SessionEvent -> AppM ()
emitEvent evt = do
  chan <- asks envEventChan
  liftIO (BChan.writeBChan chan evt)

-- ---------------------------------------------------------------------------
-- Stubs (filled in by later M6 tasks)
-- ---------------------------------------------------------------------------

processUserMessage :: SessionId -> Text -> AppM ()
processUserMessage _ _ = error "OpenCode.Session.processUserMessage: not yet implemented (M6 Task 8)"

abortSession :: AppM ()
abortSession = error "OpenCode.Session.abortSession: not yet implemented (M6 Task 7)"
