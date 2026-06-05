module OpenCode.TUI.RenderSpec (spec) where

import Brick (Widget)
import qualified Brick.Main as M
import Brick.Widgets.Core (str)
import qualified Brick.Widgets.Edit as E
import Control.Exception (evaluate)
import qualified Data.List.NonEmpty as NE
import qualified Data.Sequence as Seq
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Time (UTCTime (..), fromGregorian, secondsToDiffTime)
import qualified Graphics.Vty as V
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck
  ( Gen
  , choose
  , elements
  , forAll
  , ioProperty
  , listOf
  , listOf1
  , oneof
  , resize
  )

import OpenCode.Session.Events (RunState (..))
import OpenCode.TestEnv (newDummyEnv)
import OpenCode.TUI.Overlay (helpOverlay, modelsOverlay)
import OpenCode.TUI.Render (drawUI, safeWrap)
import OpenCode.TUI.Types (AppState (..), ResourceName (InputEditor), UIMode (..))
import OpenCode.Types
  ( Message (..)
  , MessageId (..)
  , MessagePart (..)
  , ModelId (..)
  , ProviderId (..)
  , Role (..)
  , Session (..)
  , SessionId (..)
  , ToolArgs (..)
  , ToolCall (..)
  , ToolResult (..)
  )

spec :: Spec
spec = do

  describe "drawUI" $ do

    it "produces one layer in ModeNormal (no overlay)" $ do
      st <- mkState []
      length (drawUI st) `shouldBe` 1

    it "produces two layers when an overlay is open" $ do
      st0 <- mkState []
      let st = st0 { asMode = ModeOverlay helpOverlay }
      length (drawUI st) `shouldBe` 2

    prop "renders an arbitrary short history without throwing" $
      forAll (resize 8 (listOf genMessage)) $ \msgs -> ioProperty $ do
        st <- mkState msgs
        -- Force a *real* render, not just the widget-list spine: 'renderHeight'
        -- runs every widget's deferred render action, so any bottom in the
        -- rendering code (which 'evaluate . length' would miss) is exercised.
        h <- renderHeight (drawUI st)
        pure (h >= 1)

    it "renders a message containing every MessagePart constructor" $ do
      let m = Message
            { msgId    = MessageId "m-multi"
            , msgRole  = RoleAssistant
            , msgParts = NE.fromList
                [ TextPart "thinking"
                , ToolCallPart (ToolCall "c1" "bash" (ToolArgs "{\"cmd\":\"ls\"}"))
                , ToolResultPart (ToolResult "c1" "file.txt\n" False)
                , ErrorPart "boom"
                , TextPart ""        -- empty text must not break layout
                ]
            , msgCreated = t0
            }
      st <- mkState [m]
      h <- renderHeight (drawUI st)
      h `shouldSatisfy` (>= 1)

  describe "safeWrap (empty-text guard)" $ do

    -- 'renderWidget' pads every layer to the region with a background fill, so
    -- the total image height is always the region height and can't reveal a
    -- collapsed line. We inspect the rendered 'Picture' instead (the same
    -- approach brick's own render test uses).
    it "renders empty text as a single space line, not a collapsed image" $ do
      -- safeWrap "" must render exactly like a real one-space line. Without the
      -- guard, 'txtWrap \"\"' renders to pure background fill (an empty image),
      -- which would NOT match.
      let emptyPic = M.renderWidget Nothing [safeWrap ""] (80, 24)
          spacePic = M.renderWidget Nothing [str " " :: Widget ResourceName] (80, 24)
      show emptyPic `shouldBe` show spacePic

    it "renders non-empty text as a real text span" $ do
      let pic = M.renderWidget Nothing [safeWrap "hello"] (80, 24)
      show pic `shouldContain` "hello"

  describe "in-flight partial" $ do

    it "renders the partial text while a run is active" $ do
      st0 <- mkState []
      let st  = st0 { asRunState = RunningLLM, asPartialText = "streaming now" }
          pic = M.renderWidget Nothing (drawUI st) (80, 24)
      show pic `shouldContain` "streaming now"

    it "hides the partial text when Idle" $ do
      st0 <- mkState []
      let st  = st0 { asRunState = Idle, asPartialText = "ghosttext" }
          pic = M.renderWidget Nothing (drawUI st) (80, 24)
      show pic `shouldNotContain` "ghosttext"

    it "renders the dim thinking block while a run is active" $ do
      st0 <- mkState []
      let st  = st0 { asRunState = RunningLLM, asPartialReasoning = "pondering" }
          pic = M.renderWidget Nothing (drawUI st) (80, 24)
      show pic `shouldContain` "pondering"

    it "hides the thinking block when Idle" $ do
      st0 <- mkState []
      let st  = st0 { asRunState = Idle, asPartialReasoning = "ghostthought" }
          pic = M.renderWidget Nothing (drawUI st) (80, 24)
      show pic `shouldNotContain` "ghostthought"

  describe "status bar round indicator" $ do

    it "shows round N/M when asRound is set" $ do
      st0 <- mkState []
      let st  = st0 { asRound = Just (2, 10) }
          pic = M.renderWidget Nothing (drawUI st) (80, 24)
      show pic `shouldContain` "round 2/10"

  describe "overlay layer" $ do

    it "renders the model overlay's rows over the chat" $ do
      st0 <- mkState []
      let ov  = modelsOverlay (ModelId OpenAI "gpt-4o")
                  [ModelId OpenAI "gpt-4o", ModelId Anthropic "claude-opus-4-5"]
          st  = st0 { asMode = ModeOverlay ov }
          pic = M.renderWidget Nothing (drawUI st) (80, 24)
      show pic `shouldContain` "claude-opus-4-5"

    it "renders the help overlay" $ do
      st0 <- mkState []
      let st  = st0 { asMode = ModeOverlay helpOverlay }
          pic = M.renderWidget Nothing (drawUI st) (80, 24)
      show pic `shouldContain` "commands:"

  describe "status-bar notice" $
    it "renders a transient notice" $ do
      st0 <- mkState []
      let st  = st0 { asNotice = Just "model set to anthropic:claude-opus-4-5" }
          pic = M.renderWidget Nothing (drawUI st) (80, 24)
      show pic `shouldContain` "model set to"

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

mkState :: [Message] -> IO AppState
mkState msgs = do
  env <- newDummyEnv
  pure AppState
    { asMessages         = Seq.fromList msgs
    , asInput            = E.editorText InputEditor (Just 1) ""
    , asRunState         = Idle
    , asStatusLine       = "openai:gpt-4o"
    , asPartialText      = ""
    , asPartialReasoning = ""
    , asRound            = Nothing
    , asTitle            = "untitled"
    , asEnv              = env
    , asSessionId        = sessionId sampleRenderSession
    , asMode             = ModeNormal
    , asNotice           = Nothing
    , asSuggestSel       = 0
    }

sampleRenderSession :: Session
sampleRenderSession = Session
  { sessionId      = SessionId "s-render"
  , sessionTitle   = "untitled"
  , sessionModel   = ModelId OpenAI "gpt-4o"
  , sessionCreated = t0
  }

t0 :: UTCTime
t0 = UTCTime (fromGregorian 2026 5 29) 0

-- | Force a real vty render of the given widget layers (into a fixed 80x24
-- region) and return the rendered image height. 'M.renderWidget' builds the
-- render state and runs every widget's deferred render action — so unlike
-- @evaluate . length@, a bottom or empty-image bug in rendering is actually
-- triggered here.
renderHeight :: [Widget ResourceName] -> IO Int
renderHeight ws =
  evaluate (V.imageHeight (V.picImage (M.renderWidget Nothing ws (80, 24))))

-- ---------------------------------------------------------------------------
-- Generators
-- ---------------------------------------------------------------------------

genText :: Gen Text
genText = Text.pack
  <$> listOf (elements (['a' .. 'z'] ++ ['0' .. '9'] ++ " \n.,_-"))

genShortText :: Gen Text
genShortText = Text.pack
  <$> resize 12 (listOf1 (elements (['a' .. 'z'] ++ ['0' .. '9'])))

genUtcTime :: Gen UTCTime
genUtcTime = do
  day  <- fromGregorian 2026 5 <$> choose (1, 28)
  secs <- secondsToDiffTime <$> choose (0, 86399)
  pure (UTCTime day secs)

genRole :: Gen Role
genRole = elements [RoleUser, RoleAssistant, RoleTool]

genMessagePart :: Gen MessagePart
genMessagePart = oneof
  [ TextPart       <$> genText
  , ToolCallPart   <$> (ToolCall <$> genShortText <*> genShortText <*> (ToolArgs <$> genText))
  , ToolResultPart <$> (ToolResult <$> genShortText <*> genText <*> elements [True, False])
  , ErrorPart      <$> genText
  ]

genMessage :: Gen Message
genMessage = Message . MessageId
  <$> genShortText
  <*> genRole
  <*> (NE.fromList <$> resize 4 (listOf1 genMessagePart))
  <*> genUtcTime
