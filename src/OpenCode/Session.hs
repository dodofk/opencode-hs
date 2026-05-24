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
    -- * Loop
  , agentic
  , maxToolRounds
    -- * Stubs (filled in by later M6 tasks)
  , processUserMessage
  , abortSession
  ) where

import qualified Brick.BChan as BChan
import Conduit ((.|))
import qualified Conduit
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Reader (asks)
import qualified Data.List.NonEmpty as NE
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Time (getCurrentTime)

import OpenCode.App (AppEnv (..), AppM)
import qualified OpenCode.DB as DB
import OpenCode.LLM.Types (LLMRequest (..), Streamer)
import OpenCode.Session.Events (RunState (..), SessionEvent (..))
import OpenCode.Session.Prompt (systemPrompt)
import OpenCode.Tool.Types (SomeTool (..), ToolRegistry (..), someToolDefinition)
import OpenCode.Types
  ( Message (..)
  , MessagePart (..)
  , ModelId
  , Role (..)
  , Session (..)
  , SessionId
  , StreamEvent (..)
  )

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
-- The agentic loop
-- ---------------------------------------------------------------------------

-- | Maximum number of tool rounds before forcing termination.
maxToolRounds :: Int
maxToolRounds = 10

-- | Drive the agentic loop. For Task 5: text-only single round. Tool
-- execution and recursion arrive in Task 6; abort handling arrives in Task 7.
--
-- Returns the assistant messages appended in THIS call (not the prior history).
agentic :: Streamer -> SessionId -> [Message] -> AppM [Message]
agentic streamer sid history = go 0 history []
  where
    go :: Int -> [Message] -> [Message] -> AppM [Message]
    go _round soFar appended = do
      env <- asks id
      emitEvent (RunStateChanged RunningLLM)
      let req    = buildRequest env soFar
          stream = streamer req
      events <- liftIO $ Conduit.runResourceT $ Conduit.runConduit $
        stream .| Conduit.sinkList
      mAssist <- buildAssistantMessage events
      case mAssist of
        Nothing -> do
          emitEvent (RunStateChanged Idle)
          pure (reverse appended)
        Just m -> do
          conn <- asks envDb
          liftIO (DB.insertMessage conn sid m)
          emitEvent (MessageAppended m)
          emitEvent (RunStateChanged Idle)
          -- Text-only Task 5: never recurse.
          pure (reverse (m : appended))

buildRequest :: AppEnv -> [Message] -> LLMRequest
buildRequest env history = LLMRequest
  { reqModel        = "gpt-4o"
  , reqMessages     = history
  , reqTools        = map someToolDefinition (Map.elems (unRegistry (envRegistry env)))
  , reqSystemPrompt = systemPrompt (envRegistry env)
  , reqMaxTokens    = Nothing
  }

-- | Process a flat list of 'StreamEvent's into one assistant 'Message'.
-- Returns 'Nothing' if the stream produced no parts (no text, no tool calls).
buildAssistantMessage :: [StreamEvent] -> AppM (Maybe Message)
buildAssistantMessage events = do
  let parts = collectText events
  case NE.nonEmpty parts of
    Nothing -> pure Nothing
    Just ne -> do
      mid <- liftIO DB.newMessageId
      now <- liftIO getCurrentTime
      pure $ Just Message
        { msgId      = mid
        , msgRole    = RoleAssistant
        , msgParts   = ne
        , msgCreated = now
        }

-- | Concatenate consecutive 'TextDelta' events into one 'TextPart'.
-- Task 6 extends this with tool-call accumulation.
collectText :: [StreamEvent] -> [MessagePart]
collectText events =
  let chunks = [t | TextDelta t <- events]
  in [TextPart (Text.concat chunks) | not (null chunks)]

-- ---------------------------------------------------------------------------
-- Stubs (filled in by later M6 tasks)
-- ---------------------------------------------------------------------------

processUserMessage :: SessionId -> Text -> AppM ()
processUserMessage _ _ = error "OpenCode.Session.processUserMessage: not yet implemented (M6 Task 8)"

abortSession :: AppM ()
abortSession = error "OpenCode.Session.abortSession: not yet implemented (M6 Task 7)"
