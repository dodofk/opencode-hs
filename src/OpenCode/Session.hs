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
    -- * Abort
  , abortSession
    -- * Top-level entry points
  , processUserMessage
  , processUserMessageWith
  ) where

import qualified Brick.BChan as BChan
import Conduit ((.|))
import qualified Conduit
import Control.Monad.Except (catchError, throwError)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Reader (ask, asks)
import qualified OpenCode.Config as Config
import qualified OpenCode.LLM.OpenAI as OpenAI
import qualified Control.Concurrent.STM as STM
import qualified Data.Aeson as Aeson
import qualified Data.List.NonEmpty as NE
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Data.Time (getCurrentTime)

import OpenCode.App (AppEnv (..), AppError (..), AppM)
import qualified OpenCode.App as App
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
  , ToolArgs (..)
  , ToolCall (..)
  , ToolResult (..)
  )
import qualified OpenCode.Types

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

-- | Drive the agentic loop. Handles text and tool calls, recursing up to
-- 'maxToolRounds' times when tools are executed.
--
-- Returns the assistant messages appended in THIS call (not the prior history).
agentic :: Streamer -> SessionId -> [Message] -> AppM [Message]
agentic streamer sid history = go 0 history []
  where
    go :: Int -> [Message] -> [Message] -> AppM [Message]
    go round soFar appended
      | round >= maxToolRounds = pure (reverse appended)
      | otherwise = do
          env <- ask
          emitEvent (RunStateChanged RunningLLM)
          let req    = buildRequest env soFar
              stream = streamer req
          events <- liftIO $ Conduit.runResourceT $ Conduit.runConduit $
            stream .| Conduit.sinkList
          mResult <- buildAssistantMessage events
          case mResult of
            Nothing -> do
              emitEvent (RunStateChanged Idle)
              pure (reverse appended)
            Just (m, ranTool) -> do
              conn <- asks envDb
              liftIO (DB.insertMessage conn sid m)
              emitEvent (MessageAppended m)
              emitEvent (RunStateChanged Idle)
              let nextHistory  = soFar ++ [m]
                  nextAppended = m : appended
              if ranTool
                then do
                  shouldAbort <- liftIO $ STM.readTVarIO (envAbort env)
                  if shouldAbort
                    then pure (reverse nextAppended)
                    else go (round + 1) nextHistory nextAppended
                else pure (reverse nextAppended)

buildRequest :: AppEnv -> [Message] -> LLMRequest
buildRequest env history = LLMRequest
  { reqModel        = "gpt-4o"
  , reqMessages     = history
  , reqTools        = map someToolDefinition (Map.elems (unRegistry (envRegistry env)))
  , reqSystemPrompt = systemPrompt (envRegistry env)
  , reqMaxTokens    = Nothing
  }

-- | Process a list of 'StreamEvent's into:
--   * 'Nothing' if no parts were produced (skip persistence)
--   * 'Just (assistantMessage, ranTool)' where 'ranTool' indicates whether any
--     tool was executed (triggers recursion).
buildAssistantMessage :: [StreamEvent] -> AppM (Maybe (Message, Bool))
buildAssistantMessage events = do
  let textParts = collectText events
      toolCalls = collectToolCalls events
  toolPairs <- mapM executeOne toolCalls
  let toolParts = concatMap (\(callPart, resultPart) -> [callPart, resultPart]) toolPairs
      parts     = textParts ++ toolParts
      ranTool   = not (null toolPairs)
  case NE.nonEmpty parts of
    Nothing -> pure Nothing
    Just ne -> do
      mid <- liftIO DB.newMessageId
      now <- liftIO getCurrentTime
      pure $ Just
        ( Message
            { msgId      = mid
            , msgRole    = RoleAssistant
            , msgParts   = ne
            , msgCreated = now
            }
        , ranTool
        )

-- | Pair each completed tool call with the result of executing it.
-- Emits 'ToolStarted'/'ToolFinished' SessionEvents around the execution.
executeOne :: PendingToolCall -> AppM (MessagePart, MessagePart)
executeOne (PendingToolCall pid pname pargs) = do
  let callPart = ToolCallPart (ToolCall
        { OpenCode.Types.callId    = pid
        , OpenCode.Types.toolName  = pname
        , OpenCode.Types.arguments = ToolArgs pargs
        })
      argsValue = case Aeson.eitherDecodeStrict (Text.encodeUtf8 pargs) of
        Right v -> v
        Left _  -> Aeson.Null   -- malformed JSON; askExecuteTool will reject it
  emitEvent (RunStateChanged (RunningTool pname))
  emitEvent (ToolStarted pname)
  resultText <- App.askExecuteTool pname argsValue
                  `catchError` \err -> pure $ case err of
                    ToolError _ msg -> "tool error: " <> msg
                    _               -> "tool error: " <> Text.pack (show err)
  emitEvent (ToolFinished pname resultText)
  let resultPart = ToolResultPart (ToolResult
        { resultCallId = pid
        , content      = resultText
        , isError      = False
        })
  pure (callPart, resultPart)

-- | Internal type tracking a tool call as it's accumulated from stream events.
data PendingToolCall = PendingToolCall
  { ptcCallId   :: Text
  , ptcToolName :: Text
  , ptcArgs     :: Text
  }

-- | Walk the event list and emit one 'PendingToolCall' per matched
-- (ToolCallStart, accumulated ArgDeltas, ToolCallEnd) triple.
collectToolCalls :: [StreamEvent] -> [PendingToolCall]
collectToolCalls = go Map.empty []
  where
    go :: Map.Map Text (Text, Text)
       -> [PendingToolCall]
       -> [StreamEvent]
       -> [PendingToolCall]
    go _ done [] = reverse done
    go pending done (ToolCallStart cid name : rest) =
      go (Map.insert cid (name, "") pending) done rest
    go pending done (ToolCallArgDelta cid frag : rest) =
      let pending' = Map.adjust (\(n, a) -> (n, a <> frag)) cid pending
      in go pending' done rest
    go pending done (ToolCallEnd cid : rest) =
      case Map.lookup cid pending of
        Nothing     -> go pending done rest
        Just (n, a) ->
          let ptc = PendingToolCall { ptcCallId = cid, ptcToolName = n, ptcArgs = a }
          in go (Map.delete cid pending) (ptc : done) rest
    go pending done (_ : rest) = go pending done rest

-- | Concatenate consecutive 'TextDelta' events into one 'TextPart'.
collectText :: [StreamEvent] -> [MessagePart]
collectText events =
  [TextPart (Text.concat chunks) | not (null chunks)]
  where chunks = [t | TextDelta t <- events]

-- ---------------------------------------------------------------------------
-- Top-level entry points
-- ---------------------------------------------------------------------------

-- | Process a user prompt: persist a user 'Message', run one agentic loop,
-- and return. Production uses OpenAI streaming (hardcoded for M6; M11 will
-- dispatch by provider).
processUserMessage :: SessionId -> Text -> AppM ()
processUserMessage sid prompt = do
  cfg <- asks envConfig
  case Config.openaiKey (Config.providers cfg) of
    Nothing  -> throwError (LLMError "no OpenAI API key configured")
    Just key -> do
      let provider = OpenAI.defaultOpenAI key
          streamer  = OpenAI.streamOpenAI provider
      processUserMessageWith streamer sid prompt

-- | Streamer-parameterized variant of 'processUserMessage'. Exposed for
-- tests that inject a mock 'Streamer'. Production callers use the
-- 'processUserMessage' wrapper above.
processUserMessageWith :: Streamer -> SessionId -> Text -> AppM ()
processUserMessageWith streamer sid prompt = do
  -- 1. Build and persist the user message.
  conn <- asks envDb
  mid  <- liftIO DB.newMessageId
  now  <- liftIO getCurrentTime
  let userMsg = Message
        { msgId      = mid
        , msgRole    = RoleUser
        , msgParts   = NE.singleton (TextPart prompt)
        , msgCreated = now
        }
  liftIO (DB.insertMessage conn sid userMsg)
  -- 2. Load the full message history (user + any prior turns) and drive the loop.
  history <- liftIO (DB.getMessages conn sid)
  _       <- agentic streamer sid history
  pure ()

-- ---------------------------------------------------------------------------
-- Abort
-- ---------------------------------------------------------------------------

-- | Set the abort flag. The session loop checks this between rounds and
-- terminates early if set.
abortSession :: AppM ()
abortSession = do
  var <- asks envAbort
  liftIO $ STM.atomically $ STM.writeTVar var True
