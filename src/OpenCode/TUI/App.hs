-- | Brick application definition, event handling, and TUI entry point.
--
-- M9 wires streaming and abort handlers: Enter (when Idle) forks the agentic
-- loop via 'startRun'; Esc flips 'envAbort' for cooperative cancellation;
-- 'AppEvent' delegations fold each 'SessionEvent' through 'applyEvent'.
-- Ctrl+C exits; ↑/↓ scroll the chat a line, PgUp/PgDn a page, and the chat
-- auto-scrolls to the newest output as it streams in.
module OpenCode.TUI.App
  ( -- * Entry point
    startTUI
  , startRun
    -- * Brick app (exported for testing)
  , app
  , handleEvent
    -- * State helpers (pure; exported for testing)
  , initialState
  , appendUserMessage
  , applyEnter
  , applyEvent
  , applySwitch
  , applyModelSet
  , applySuggestMove
  , applyComplete
  , highlightedCommand
  , currentInput
  , inputContents
  , shouldSubmit
  , modelLabel
  ) where

import Brick
  ( App (..)
  , BrickEvent (VtyEvent, AppEvent)
  , EventM
  )
import Brick.AttrMap (AttrMap, attrMap)
import qualified Brick.BChan as BChan
import qualified Brick.Main as M
import Brick.Util (fg, on)
import qualified Brick.Widgets.Edit as E
import Control.Concurrent.Async (async)
import Control.Concurrent.STM (atomically, writeTVar)
import Control.Exception (SomeException, displayException, try)
import Control.Monad (when)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.State.Class (get, modify, put)
import Data.List.NonEmpty (NonEmpty ((:|)))
import Data.Sequence ((|>))
import qualified Data.Sequence as Seq
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time (UTCTime (..), fromGregorian, getCurrentTime)
import qualified Graphics.Vty as V
import Graphics.Vty.CrossPlatform (mkVty)
import Lens.Micro (Lens')
import Lens.Micro.Mtl (zoom)

import OpenCode.App (runAppM, AppError)
import OpenCode.App.Error (displayAppError)
import OpenCode.App.Types (AppEnv (..))
import OpenCode.Model.Catalog (availableModels, modelLabel)
import qualified OpenCode.DB as DB
import OpenCode.Session (processUserMessage, createSession)
import OpenCode.Session.Events (RunState (..), SessionEvent (..))
import OpenCode.TUI.Render
  ( assistantAttr
  , drawUI
  , errorAttr
  , statusAttr
  , streamingAttr
  , toolAttr
  , userAttr
  )
import OpenCode.Config (Config (..))
import OpenCode.MCP.Adapters (promptSuggestEntries)
import OpenCode.TUI.Command (Command (..), parseCommand, commandSuggestions, clampSel)
import OpenCode.TUI.Overlay
  ( helpOverlay, modelsOverlay, sessionsOverlay, overlayMove, overlaySelected )
import OpenCode.TUI.Types
  ( AppState (..), ResourceName (..), UIMode (..), Overlay (..), OverlayKind (..) )
import OpenCode.Types
  ( Message (..)
  , MessageId (MessageId)
  , MessagePart (TextPart, ErrorPart)
  , ModelId
  , Role (RoleUser, RoleAssistant)
  , Session (..)
  , SessionId
  )

-- ---------------------------------------------------------------------------
-- Entry point
-- ---------------------------------------------------------------------------

-- | Start the brick TUI for an existing session, pre-loading its history.
startTUI :: AppEnv -> Session -> IO ()
startTUI env session = do
  msgs <- DB.getMessages (envDb env) (sessionId session)
  let st0      = initialState env session msgs
      buildVty = mkVty V.defaultConfig
  initialVty <- buildVty
  _ <- M.customMain initialVty buildVty (Just (envEventChan env)) app st0
  pure ()

-- | Reset the abort flag (synchronously) and fork the agentic run for a user
-- prompt. Any failure — typed 'AppError' or runtime exception — is surfaced as
-- an 'ErrorOccurred' event, and the run state is always returned to 'Idle' so
-- the input is re-enabled. The handle is discarded: abort is cooperative
-- (hard cancellation is deferred to M12).
startRun :: AppEnv -> SessionId -> Text -> IO ()
startRun env sid prompt = do
  atomically (writeTVar (envAbort env) False)
  _ <- async $ do
    outcome <- try (runAppM env (processUserMessage sid prompt))
    case outcome of
      Right (Right ()) -> pure ()                  -- success: loop already emitted Idle
      Right (Left err) -> report (displayAppError err)
      Left ex          -> report (T.pack (displayException (ex :: SomeException)))
  pure ()
  where
    report msg = do
      BChan.writeBChan (envEventChan env) (ErrorOccurred msg)
      BChan.writeBChan (envEventChan env) (RunStateChanged Idle)

-- ---------------------------------------------------------------------------
-- App definition
-- ---------------------------------------------------------------------------

app :: App AppState SessionEvent ResourceName
app = App
  { appDraw         = drawUI
  , appChooseCursor = M.showFirstCursor
  , appHandleEvent  = handleEvent
  , appStartEvent   = pure ()
  , appAttrMap      = const theMap
  }

theMap :: AttrMap
theMap = attrMap V.defAttr
  [ (userAttr,      fg V.cyan)
  , (assistantAttr, fg V.green)
  , (toolAttr,      fg V.yellow)
  , (errorAttr,     fg V.red)
  , (statusAttr,    V.white `on` V.blue)
  , (streamingAttr, V.defAttr `V.withStyle` V.dim)
  ]

-- ---------------------------------------------------------------------------
-- Event handling
-- ---------------------------------------------------------------------------

-- | Top-level event router. Ctrl-C always quits. Session events apply in any
-- mode. Otherwise dispatch on whether a modal overlay is open.
handleEvent :: BrickEvent ResourceName SessionEvent -> EventM ResourceName AppState ()
handleEvent (VtyEvent (V.EvKey (V.KChar 'c') [V.MCtrl])) = M.halt
handleEvent (AppEvent ev) = do
  st <- get
  put (applyEvent ev st)
  M.vScrollToEnd chatScroll
handleEvent ev = do
  st <- get
  case asMode st of
    ModeOverlay ov -> handleOverlay ov ev
    ModeNormal     -> handleNormal ev

-- | Normal-mode keys. Esc and page-scroll are unconditional. When the slash
-- autocomplete panel is active, Up/Down move the highlight, Tab completes, and
-- Enter runs the highlighted command; otherwise the keys keep their existing
-- meaning (Enter submits, Up/Down scroll, others edit the input).
handleNormal :: BrickEvent ResourceName SessionEvent -> EventM ResourceName AppState ()
handleNormal (VtyEvent (V.EvKey V.KEsc [])) = do
  st <- get
  liftIO (atomically (writeTVar (envAbort (asEnv st)) True))
handleNormal (VtyEvent (V.EvKey V.KPageUp   [])) = M.vScrollBy chatScroll (-pageStep)
handleNormal (VtyEvent (V.EvKey V.KPageDown [])) = M.vScrollBy chatScroll pageStep
handleNormal ev = do
  st <- get
  if suggestionsActive st
    then handleSuggest ev
    else handleEdit ev

-- | Autocomplete entries for the current state: built-ins + MCP prompts.
suggestEntries :: AppState -> [(Text, Text)]
suggestEntries st =
  commandSuggestions (promptSuggestEntries (envMcp (asEnv st))) (currentInput st)

-- | Whether the autocomplete panel is currently showing.
suggestionsActive :: AppState -> Bool
suggestionsActive = not . null . suggestEntries

-- | Keys while the autocomplete panel is open.
handleSuggest :: BrickEvent ResourceName SessionEvent -> EventM ResourceName AppState ()
handleSuggest = \case
  VtyEvent (V.EvKey V.KUp   [])        -> modify (applySuggestMove (-1))
  VtyEvent (V.EvKey V.KDown [])        -> modify (applySuggestMove 1)
  VtyEvent (V.EvKey (V.KChar '\t') []) -> modify applyComplete
  VtyEvent (V.EvKey V.KEnter [])       -> runHighlighted
  ev                                   -> editAndReset ev

-- | Normal editing keys when no panel is open (the pre-M13.1 behavior).
handleEdit :: BrickEvent ResourceName SessionEvent -> EventM ResourceName AppState ()
handleEdit = \case
  VtyEvent (V.EvKey V.KEnter [])     -> onEnter
  VtyEvent (V.EvKey V.KUp   [])      -> M.vScrollBy chatScroll (-lineStep)
  VtyEvent (V.EvKey V.KDown [])      -> M.vScrollBy chatScroll lineStep
  VtyEvent vev                       -> zoom inputL (E.handleEditorEvent (VtyEvent vev))
  _                                  -> pure ()

-- | Feed an editing key to the editor, then reset the highlight to the top (the
-- match set may have changed).
editAndReset :: BrickEvent ResourceName SessionEvent -> EventM ResourceName AppState ()
editAndReset ev = do
  case ev of
    VtyEvent vev -> zoom inputL (E.handleEditorEvent (VtyEvent vev))
    _            -> pure ()
  modify (\s -> s { asSuggestSel = 0 })

-- | Enter while the panel is open: run the highlighted command via the existing
-- dispatcher (so run-in-flight gating and notices are inherited). Falls back to
-- the normal submit path if, defensively, there is no highlight.
runHighlighted :: EventM ResourceName AppState ()
runHighlighted = do
  st <- get
  case highlightedCommand st of
    Nothing   -> onEnter
    Just name -> do
      put st { asInput = emptyEditor, asNotice = Nothing, asSuggestSel = 0 }
      maybe (pure ()) dispatchCommand (parseCommand name)

-- | The Enter action in normal mode: a slash command dispatches; anything else
-- is submitted to the LLM exactly as before.
onEnter :: EventM ResourceName AppState ()
onEnter = do
  st <- get
  let body = currentInput st
  case parseCommand body of
    Nothing ->
      when (asRunState st == Idle && shouldSubmit body) $ do
        msg <- liftIO (mkUserMessage body)
        put ((applyEnter msg st) { asRunState = RunningLLM, asNotice = Nothing })
        liftIO (startRun (asEnv st) (asSessionId st) body)
        M.vScrollToEnd chatScroll
    Just cmd -> do
      put st { asInput = emptyEditor, asNotice = Nothing }
      dispatchCommand cmd

-- | Run a slash command. Context-changing commands are blocked while a run is
-- in flight (with a notice); /help and /quit always work.
dispatchCommand :: Command -> EventM ResourceName AppState ()
dispatchCommand cmd = do
  st <- get
  case cmd of
    CmdHelp      -> put st { asMode = ModeOverlay helpOverlay }
    CmdQuit      -> M.halt
    CmdUnknown w -> put st { asNotice = Just ("unknown command: " <> w) }
    CmdNew       -> whenIdle st (openNew st)
    CmdSessions  -> whenIdle st (openSessions st)
    CmdModel     -> whenIdle st (openModel st)
  where
    whenIdle st act
      | asRunState st == Idle = act
      | otherwise             = put st { asNotice = Just "press Esc to abort the run first" }

-- | Overlay-mode keys: Esc closes, arrows move, Enter commits the selection.
handleOverlay :: Overlay -> BrickEvent ResourceName SessionEvent -> EventM ResourceName AppState ()
handleOverlay ov ev = case ev of
  VtyEvent (V.EvKey V.KEsc [])   -> closeOverlay
  VtyEvent (V.EvKey V.KUp [])    -> moveSel (-1)
  VtyEvent (V.EvKey V.KDown [])  -> moveSel 1
  VtyEvent (V.EvKey V.KEnter []) -> commitOverlay ov
  _                              -> pure ()
  where
    closeOverlay = do
      s <- get
      put s { asMode = ModeNormal }
    moveSel d = do
      s <- get
      case asMode s of
        ModeOverlay o -> put s { asMode = ModeOverlay (overlayMove d o) }
        ModeNormal    -> pure ()

-- | Perform the action for the currently-selected overlay row.
commitOverlay :: Overlay -> EventM ResourceName AppState ()
commitOverlay ov = do
  st <- get
  case overlaySelected ov of
    Nothing -> put st { asMode = ModeNormal }
    Just i  -> case ovKind ov of
      OverlayHelp _        -> put st { asMode = ModeNormal }
      OverlaySessions _ ss -> maybe (put st { asMode = ModeNormal })
                                    (\s -> switchTo s st { asNotice = Nothing })
                                    (safeIndex ss i)
      OverlayModels _ ms   -> maybe (put st { asMode = ModeNormal })
                                    (`setModel` st)
                                    (safeIndex ms i)

-- | /new: create a session with the config default model and switch to it.
openNew :: AppState -> EventM ResourceName AppState ()
openNew st = do
  let env = asEnv st
      mdl = defaultModel (envConfig env)
  result <- liftIO (try (runAppM env (createSession mdl))
                      :: IO (Either SomeException (Either AppError Session)))
  case result of
    Right (Right s) -> switchTo s st { asNotice = Just "new session created" }
    Right (Left e)  -> put st { asNotice = Just ("error: " <> displayAppError e) }
    Left e          -> put st { asNotice = Just ("error: " <> T.pack (displayException e)) }

-- | /sessions: open a picker of all stored sessions.
openSessions :: AppState -> EventM ResourceName AppState ()
openSessions st = do
  result <- liftIO (try (DB.listSessions (envDb (asEnv st)))
                      :: IO (Either SomeException [Session]))
  case result of
    Left e   -> put st { asNotice = Just ("error: " <> T.pack (displayException e)) }
    Right ss -> put st { asMode = ModeOverlay (sessionsOverlay (asSessionId st) ss) }

-- | /model: open a picker of models for the configured providers.
openModel :: AppState -> EventM ResourceName AppState ()
openModel st = do
  let env = asEnv st
  result <- liftIO (try (DB.getSession (envDb env) (asSessionId st))
                      :: IO (Either SomeException (Maybe Session)))
  case result of
    Left e         -> put st { asNotice = Just ("error: " <> T.pack (displayException e)) }
    Right Nothing  -> put st { asNotice = Just "error: session not found" }
    Right (Just s) -> case availableModels (providers (envConfig env)) of
      [] -> put st { asNotice = Just "no models available" }
      ms -> put st { asMode = ModeOverlay (modelsOverlay (sessionModel s) ms) }

-- | Load a session's history and switch the UI to it.
switchTo :: Session -> AppState -> EventM ResourceName AppState ()
switchTo session st = do
  result <- liftIO (try (DB.getMessages (envDb (asEnv st)) (sessionId session))
                      :: IO (Either SomeException [Message]))
  case result of
    Left e     -> put st { asNotice = Just ("error: " <> T.pack (displayException e)) }
    Right msgs -> do
      put (applySwitch session msgs st)
      M.vScrollToEnd chatScroll

-- | Persist the chosen model to the session, then update the UI.
setModel :: ModelId -> AppState -> EventM ResourceName AppState ()
setModel mdl st = do
  result <- liftIO (try (DB.updateSessionModel (envDb (asEnv st)) (asSessionId st) mdl)
                      :: IO (Either SomeException ()))
  case result of
    Left e   -> put st { asMode = ModeNormal
                       , asNotice = Just ("error: " <> T.pack (displayException e)) }
    Right () -> put (applyModelSet mdl st)

-- | Total list indexing.
safeIndex :: [a] -> Int -> Maybe a
safeIndex xs i
  | i >= 0 && i < length xs = Just (xs !! i)
  | otherwise               = Nothing

-- | Pure: switch the UI to another session, resetting per-session view state.
-- Preserves env and notice; clears the input.
applySwitch :: Session -> [Message] -> AppState -> AppState
applySwitch session msgs st = st
  { asMessages         = Seq.fromList msgs
  , asInput            = emptyEditor
  , asSessionId        = sessionId session
  , asTitle            = sessionTitle session
  , asStatusLine       = modelLabel (sessionModel session)
  , asPartialText      = ""
  , asPartialReasoning = ""
  , asRound            = Nothing
  , asRunState         = Idle
  , asMode             = ModeNormal
  }

-- | Pure: apply a model switch (status line + confirmation notice + close).
applyModelSet :: ModelId -> AppState -> AppState
applyModelSet mdl st = st
  { asStatusLine = modelLabel mdl
  , asMode       = ModeNormal
  , asNotice     = Just ("model set to " <> modelLabel mdl)
  }

-- | The currently-highlighted command name, if the autocomplete panel is
-- showing for the current input. Total: 'clampSel' keeps the index in range
-- and 'safeIndex' guards the lookup.
highlightedCommand :: AppState -> Maybe Text
highlightedCommand st =
  case suggestEntries st of
    [] -> Nothing
    -- safeIndex is the outer guard; clampSel already keeps the index valid here.
    xs -> fst <$> safeIndex xs (clampSel (length xs) (asSuggestSel st))

-- | Pure: move the autocomplete highlight by a delta, clamped to the current
-- match count. No-op when no suggestions are showing.
applySuggestMove :: Int -> AppState -> AppState
applySuggestMove delta st =
  st { asSuggestSel = clampSel n (asSuggestSel st + delta) }
  where n = length (suggestEntries st)

-- | Pure: complete the input to the highlighted command name (the rebuilt
-- editor's cursor lands at the end) and reset the highlight. No-op when no
-- suggestions are showing.
applyComplete :: AppState -> AppState
applyComplete st = case highlightedCommand st of
  Nothing   -> st
  Just name -> st
    { asInput      = E.editorText InputEditor (Just 1) name
    , asSuggestSel = 0
    }

-- | Lines scrolled per ↑ / ↓ keypress.
lineStep :: Int
lineStep = 1

-- | Lines scrolled per PgUp / PgDn.
pageStep :: Int
pageStep = 10

chatScroll :: M.ViewportScroll ResourceName
chatScroll = M.viewportScroll ChatViewport

-- ---------------------------------------------------------------------------
-- State helpers
-- ---------------------------------------------------------------------------

-- | Build the initial UI state from the environment, session, and history.
initialState :: AppEnv -> Session -> [Message] -> AppState
initialState env session msgs = AppState
  { asMessages         = Seq.fromList msgs
  , asInput            = emptyEditor
  , asRunState         = Idle
  , asStatusLine       = modelLabel (sessionModel session)
  , asPartialText      = ""
  , asPartialReasoning = ""
  , asRound            = Nothing
  , asTitle            = sessionTitle session
  , asEnv              = env
  , asSessionId        = sessionId session
  , asMode             = ModeNormal
  , asNotice           = Nothing
  , asSuggestSel       = 0
  }

emptyEditor :: E.Editor Text ResourceName
emptyEditor = E.editorText InputEditor (Just 1) ""

-- | The current input buffer as a single line of text.
currentInput :: AppState -> Text
currentInput = inputContents . asInput

inputContents :: E.Editor Text ResourceName -> Text
inputContents = T.intercalate "\n" . E.getEditContents

-- | Whether the given input buffer is worth submitting (non-blank).
shouldSubmit :: Text -> Bool
shouldSubmit = not . T.null . T.strip

-- | Append a finalized user message to the history and clear the input.
appendUserMessage :: Message -> AppState -> AppState
appendUserMessage m st = st
  { asMessages = asMessages st |> m
  , asInput    = emptyEditor
  }

-- | Pure core of the Enter-key action: the @KEnter@ branch of 'handleEvent'
-- delegates its state update here. Append the freshly-built user message and
-- clear the input iff the current input is submittable; otherwise leave the
-- state untouched.
--
-- 'handleEvent' already checks 'shouldSubmit' before building the message (to
-- avoid minting a message id for blank input), so the guard here is redundant
-- in production. It is repeated so this function is a total, self-contained
-- specification of the Enter semantics — the submit gate together with the
-- append-and-clear — that can be unit-tested directly. brick 2.1 exposes no
-- pure 'EventM' runner, so testing that wiring through 'handleEvent' itself
-- would require driving a live vty terminal.
applyEnter :: Message -> AppState -> AppState
applyEnter msg st
  | shouldSubmit (currentInput st) = appendUserMessage msg st
  | otherwise                      = st

-- | Pure reducer: fold a 'SessionEvent' from the session loop into the UI
-- state. Exported for testing. Never reads 'asEnv'/'asSessionId'.
applyEvent :: SessionEvent -> AppState -> AppState
applyEvent = \case
  MessageAppended m  -> \st -> st { asMessages = asMessages st |> m, asPartialText = "", asPartialReasoning = "" }
  PartialText t      -> \st -> st { asPartialText = asPartialText st <> t }
  PartialReasoning t -> \st -> st { asPartialReasoning = asPartialReasoning st <> t }
  ToolStarted n      -> \st -> st { asRunState = RunningTool n }
  ToolFinished _ _   -> id
  RunStateChanged s  -> \st -> st
    { asRunState         = s
    , asPartialText      = if s == Idle then "" else asPartialText st
    , asPartialReasoning = if s == Idle then "" else asPartialReasoning st
    , asRound            = if s == Idle then Nothing else asRound st
    }
  ErrorOccurred e       -> \st -> st { asMessages = asMessages st |> errorMessage e }
  RoundStarted c t      -> \st -> st { asRound = Just (c, t) }
  SessionTitleChanged t -> \st -> st { asTitle = t }

-- | A transient, render-only assistant message carrying an error line. Not
-- persisted, so a fixed synthetic id/timestamp is fine.
errorMessage :: Text -> Message
errorMessage e = Message
  { msgId      = MessageId "error-synthetic"
  , msgRole    = RoleAssistant
  , msgParts   = ErrorPart e :| []
  , msgCreated = UTCTime (fromGregorian 1970 1 1) 0
  }

-- ---------------------------------------------------------------------------
-- Internals
-- ---------------------------------------------------------------------------

mkUserMessage :: Text -> IO Message
mkUserMessage body = do
  mid <- DB.newMessageId
  now <- getCurrentTime
  pure Message
    { msgId      = mid
    , msgRole    = RoleUser
    , msgParts   = TextPart body :| []
    , msgCreated = now
    }

inputL :: Lens' AppState (E.Editor Text ResourceName)
inputL f s = (\e -> s { asInput = e }) <$> f (asInput s)
