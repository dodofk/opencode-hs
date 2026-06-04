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
    -- * Provider selection
  , streamerForProvider
    -- * Top-level entry points
  , processUserMessage
  , processUserMessageWith
  ) where

import qualified Brick.BChan as BChan
import Conduit ((.|))
import qualified Conduit
import Control.Monad (when)
import Control.Monad.Except (catchError, throwError)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Reader (ask, asks)
import qualified OpenCode.Config as Config
import qualified OpenCode.LLM.Mock as Mock
import qualified OpenCode.LLM.Anthropic as Anthropic
import qualified OpenCode.LLM.OpenAI as OpenAI
import qualified Control.Concurrent.STM as STM
import System.Environment (lookupEnv)
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
import OpenCode.Tool.Types (ToolRegistry (..), someToolDefinition)
import OpenCode.Types
  ( Message (..)
  , MessagePart (..)
  , ModelId (..)
  , ProviderId (..)
  , Role (..)
  , Session (..)
  , SessionId
  , StreamEvent (..)
  , ToolArgs (..)
  , ToolCall (..)
  , ToolResult (..)
  , Usage (..)
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

-- | Drive the agentic loop. Handles text and tool calls, recursing up to
-- 'maxToolRounds' times when tools are executed.
--
-- Returns the assistant messages appended in THIS call (not the prior history).
agentic :: Streamer -> SessionId -> [Message] -> AppM [Message]
agentic streamer sid history = go 0 history []
  where
    go :: Int -> [Message] -> [Message] -> AppM [Message]
    go roundNum soFar appended
      | roundNum >= maxToolRounds = pure (reverse appended)
      | otherwise = do
          env <- ask
          emitEvent (RunStateChanged RunningLLM)
          let req    = buildRequest env soFar
              stream = streamer req
          (events, aborted) <- liftIO $ Conduit.runResourceT $ Conduit.runConduit $
            stream .| consumeStream (envEventChan env) (envAbort env)
          if aborted
            then do
              mMsg <- buildTextOnlyMessage events
              case mMsg of
                Nothing -> do
                  emitEvent (RunStateChanged Idle)
                  pure (reverse appended)
                Just m -> do
                  conn <- asks envDb
                  liftIO (DB.insertMessage conn sid m)
                  emitEvent (MessageAppended m)
                  emitEvent (RunStateChanged Idle)
                  pure (reverse (m : appended))
            else do
              -- A provider HTTP error arrives as a StreamError *event*, not an
              -- exception; surface each one so a failed round is visible rather
              -- than a silent flip back to idle.
              let errs = collectErrors events
              mapM_ (emitEvent . ErrorOccurred) errs
              mResult <- buildAssistantMessage events
              case mResult of
                Nothing -> do
                  -- No text, no tool call, and no error: e.g. a 200 with empty
                  -- content (a reasoning model that streamed only thinking).
                  -- Say so on the first round instead of looking frozen.
                  when (roundNum == 0 && null errs && not (hasReasoning events)) $
                    emitEvent (ErrorOccurred emptyResponseMessage)
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
                        else go (roundNum + 1) nextHistory nextAppended
                    else pure (reverse nextAppended)

buildRequest :: AppEnv -> [Message] -> LLMRequest
buildRequest env history = LLMRequest
  { reqModel        = model (Config.defaultModel (envConfig env))
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

-- | Stream sink: emit 'PartialText' for each 'TextDelta', accumulate every
-- event, and stop pulling as soon as 'envAbort' is observed (returning
-- @aborted = True@). Stopping lets 'runResourceT' finalize the HTTP conduit and
-- close the connection — cooperative abort. Runs in @ResourceT IO@, so it
-- writes the channel directly rather than via 'emitEvent' (which is 'AppM').
consumeStream
  :: BChan.BChan SessionEvent
  -> STM.TVar Bool
  -> Conduit.ConduitT StreamEvent o (Conduit.ResourceT IO) ([StreamEvent], Bool)
consumeStream chan abortVar = loop []
  where
    loop acc = do
      mEvt <- Conduit.await
      case mEvt of
        Nothing  -> pure (reverse acc, False)
        Just evt -> do
          case evt of
            TextDelta t      -> liftIO (BChan.writeBChan chan (PartialText t))
            ReasoningDelta t -> liftIO (BChan.writeBChan chan (PartialReasoning t))
            _                -> pure ()
          aborted <- liftIO (STM.readTVarIO abortVar)
          if aborted
            then pure (reverse (evt : acc), True)
            else loop (evt : acc)

-- | Build an assistant message from the text deltas only, ignoring any tool
-- calls. Used on the abort path so a cancelled run never executes a tool that
-- happened to fully stream in. 'Nothing' when no text was produced.
buildTextOnlyMessage :: [StreamEvent] -> AppM (Maybe Message)
buildTextOnlyMessage events =
  case NE.nonEmpty (collectText events) of
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

-- | Pair each completed tool call with the result of executing it.
-- Emits 'ToolStarted'/'ToolFinished' SessionEvents around the execution.
-- Sets 'isError = True' in the 'ToolResultPart' when 'catchError' fires so
-- the LLM knows the tool failed and can retry or apologise.
executeOne :: PendingToolCall -> AppM (MessagePart, MessagePart)
executeOne (PendingToolCall pid pname pargs) = do
  let callPart = ToolCallPart (ToolCall
        { callId    = pid
        , toolName  = pname
        , arguments = ToolArgs pargs
        })
      argsValue = case Aeson.eitherDecodeStrict (Text.encodeUtf8 pargs) of
        Right v -> v
        Left _  -> Aeson.Null   -- malformed JSON; askExecuteTool will reject it
  emitEvent (RunStateChanged (RunningTool pname))
  emitEvent (ToolStarted pname)
  -- Track whether catchError fired so we can set ToolResult.isError correctly.
  -- This signals to the LLM that the tool failed, prompting retry or apology.
  outcome <- fmap Right (App.askExecuteTool pname argsValue)
               `catchError` \err -> pure $ Left $ case err of
                 ToolError _ msg -> "tool error: " <> msg
                 _               -> "tool error: " <> Text.pack (show err)
  let (resultText, isErr) = case outcome of
        Right t   -> (t, False)
        Left errT -> (errT, True)
  emitEvent (ToolFinished pname resultText)
  let resultPart = ToolResultPart (ToolResult
        { resultCallId = pid
        , content      = resultText
        , isError      = isErr
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

-- | Extract the messages of any 'StreamError' events. A provider HTTP error
-- (4xx/5xx) is delivered as stream data, not an exception, so the loop must
-- inspect for it explicitly — otherwise an errored round looks like an empty,
-- silent non-response.
collectErrors :: [StreamEvent] -> [Text]
collectErrors events = [e | StreamError e <- events]

-- | True if any event is a reasoning delta (used to suppress the empty-response
-- message when a round streamed only thinking).
hasReasoning :: [StreamEvent] -> Bool
hasReasoning events = not (null [() | ReasoningDelta _ <- events])

-- | Surfaced when the first round produces no text, no tool call, and no error.
emptyResponseMessage :: Text
emptyResponseMessage =
  "the model returned an empty response (no text or tool call)"

-- ---------------------------------------------------------------------------
-- Top-level entry points
-- ---------------------------------------------------------------------------

-- | Process a user prompt: persist a user 'Message', run one agentic loop,
-- and return. When @OPENCODE_MOCK=1@ is set, use a delay-paced canned reply
-- for keyless manual testing; otherwise select a streamer for the configured
-- default model's provider (see 'selectStreamer').
processUserMessage :: SessionId -> Text -> AppM ()
processUserMessage sid prompt = do
  mock <- liftIO (lookupEnv "OPENCODE_MOCK")
  case mock of
    Just "1" ->
      processUserMessageWith (Mock.delayedStreamer mockChunkDelayUs mockReply) sid prompt
    _ -> do
      cfg      <- asks envConfig
      streamer <- either throwError pure (selectStreamer cfg)
      processUserMessageWith streamer sid prompt

-- | Pick a streaming provider for the configured default model. Thin wrapper
-- over 'streamerForProvider'.
selectStreamer :: Config.Config -> Either AppError Streamer
selectStreamer cfg = streamerForProvider cfg (provider (Config.defaultModel cfg))

-- | Pick a streamer for a specific provider id, given the configured keys.
-- MiniMax and OpenAI share the OpenAI-compatible wire format and differ only in
-- base URL, so both go through 'OpenAI.streamOpenAI'; Anthropic uses its own
-- 'Anthropic.streamAnthropic'. Each arm fails with 'LLMError' when its key is
-- absent. Exported so @config check@ can probe a provider other than the
-- default model's.
streamerForProvider :: Config.Config -> ProviderId -> Either AppError Streamer
streamerForProvider cfg pid =
  case pid of
    OpenAI    -> withKey (Config.openaiKey  pc) "OpenAI"
                   (OpenAI.streamOpenAI . OpenAI.defaultOpenAI)
    MiniMax   -> withKey (Config.minimaxKey pc) "MiniMax"
                   (OpenAI.streamOpenAI . OpenAI.minimaxOpenAI)
    Anthropic -> withKey (Config.anthropicKey pc) "Anthropic"
                   (Anthropic.streamAnthropic . Anthropic.defaultAnthropic)
  where
    pc = Config.providers cfg
    withKey mKey label mkStreamer = case mKey of
      Nothing  -> Left (LLMError ("no " <> label <> " API key configured"))
      Just key -> Right (mkStreamer key)

-- | Microseconds between mock chunks; tuned so the whole reply takes a few
-- seconds — long enough to watch streaming and test Esc by hand.
mockChunkDelayUs :: Int
mockChunkDelayUs = 700000

-- | The canned reply emitted under OPENCODE_MOCK=1.
mockReply :: [StreamEvent]
mockReply =
  [ TextDelta "This ", TextDelta "is ", TextDelta "a ", TextDelta "mock "
  , TextDelta "streamed ", TextDelta "reply ", TextDelta "for ", TextDelta "manual "
  , TextDelta "testing."
  , StreamDone (Usage 0 0 Nothing Nothing)
  ]

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
