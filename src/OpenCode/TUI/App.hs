-- | Brick application definition, event handling, and TUI entry point.
--
-- M8 wires a static layout: a scrollable chat history, a status bar, and an
-- input editor. Pressing Enter appends a placeholder user message (no LLM
-- call yet — that arrives in M9); Ctrl+C exits; PgUp / PgDn scroll history.
module OpenCode.TUI.App
  ( -- * Entry point
    startTUI
    -- * Brick app (exported for testing)
  , app
  , handleEvent
    -- * State helpers (pure; exported for testing)
  , initialState
  , appendUserMessage
  , currentInput
  , inputContents
  , shouldSubmit
  , modelLabel
  ) where

import Brick
  ( App (..)
  , BrickEvent (VtyEvent)
  , EventM
  )
import Brick.AttrMap (AttrMap, attrMap)
import Brick.BChan (BChan)
import qualified Brick.Main as M
import Brick.Util (fg, on)
import qualified Brick.Widgets.Edit as E
import Control.Monad (when)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.State.Class (get, put)
import Data.List.NonEmpty (NonEmpty ((:|)))
import Data.Sequence ((|>))
import qualified Data.Sequence as Seq
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time (getCurrentTime)
import qualified Graphics.Vty as V
import Lens.Micro (Lens')
import Lens.Micro.Mtl (zoom)

import OpenCode.App.Types (AppEnv (..))
import qualified OpenCode.DB as DB
import OpenCode.Session.Events (RunState (Idle), SessionEvent)
import OpenCode.TUI.Render
  ( assistantAttr
  , drawUI
  , errorAttr
  , statusAttr
  , toolAttr
  , userAttr
  )
import OpenCode.TUI.Types (AppState (..), ResourceName (..))
import OpenCode.Types
  ( Message (..)
  , MessagePart (TextPart)
  , ModelId (..)
  , ProviderId (..)
  , Role (RoleUser)
  , Session (..)
  )

-- ---------------------------------------------------------------------------
-- Entry point
-- ---------------------------------------------------------------------------

-- | Start the brick TUI for an existing session, pre-loading its history.
startTUI :: AppEnv -> Session -> IO ()
startTUI env session = do
  msgs <- DB.getMessages (envDb env) (sessionId session)
  let st0 = initialState (envEventChan env) session msgs
  _ <- M.defaultMain app st0
  pure ()

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
  ]

-- ---------------------------------------------------------------------------
-- Event handling
-- ---------------------------------------------------------------------------

handleEvent :: BrickEvent ResourceName SessionEvent -> EventM ResourceName AppState ()
handleEvent (VtyEvent (V.EvKey (V.KChar 'c') [V.MCtrl])) = M.halt
handleEvent (VtyEvent (V.EvKey V.KEnter [])) = do
  st <- get
  let body = currentInput st
  when (shouldSubmit body) $ do
    msg <- liftIO (mkUserMessage body)
    put (appendUserMessage msg st)
handleEvent (VtyEvent (V.EvKey V.KPageUp   [])) = M.vScrollBy chatScroll (-pageStep)
handleEvent (VtyEvent (V.EvKey V.KPageDown [])) = M.vScrollBy chatScroll pageStep
handleEvent (VtyEvent ev) = zoom inputL (E.handleEditorEvent (VtyEvent ev))
handleEvent _ = pure ()

-- | Lines scrolled per PgUp / PgDn.
pageStep :: Int
pageStep = 10

chatScroll :: M.ViewportScroll ResourceName
chatScroll = M.viewportScroll ChatViewport

-- ---------------------------------------------------------------------------
-- State helpers
-- ---------------------------------------------------------------------------

-- | Build the initial UI state from a session and its loaded history.
initialState :: BChan SessionEvent -> Session -> [Message] -> AppState
initialState chan session msgs = AppState
  { asMessages   = Seq.fromList msgs
  , asInput      = emptyEditor
  , asRunState   = Idle
  , asStatusLine = modelLabel (sessionModel session)
  , asEventChan  = chan
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

-- | A human-readable @provider:model@ label for the status bar.
modelLabel :: ModelId -> Text
modelLabel (ModelId p m) = providerLabel p <> ":" <> m

providerLabel :: ProviderId -> Text
providerLabel = \case
  OpenAI    -> "openai"
  Anthropic -> "anthropic"

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
