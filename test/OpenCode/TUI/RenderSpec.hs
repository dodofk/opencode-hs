module OpenCode.TUI.RenderSpec (spec) where

import qualified Brick.BChan as BChan
import qualified Brick.Widgets.Edit as E
import Control.Exception (evaluate)
import qualified Data.List.NonEmpty as NE
import qualified Data.Sequence as Seq
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Time (UTCTime (..), fromGregorian, secondsToDiffTime)
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

import OpenCode.Session.Events (RunState (Idle))
import OpenCode.TUI.Render (drawUI)
import OpenCode.TUI.Types (AppState (..), ResourceName (InputEditor))
import OpenCode.Types
  ( Message (..)
  , MessageId (..)
  , MessagePart (..)
  , Role (..)
  , ToolArgs (..)
  , ToolCall (..)
  , ToolResult (..)
  )

spec :: Spec
spec = describe "drawUI" $ do

  it "produces a single top-level widget" $ do
    st <- mkState []
    length (drawUI st) `shouldBe` 1

  prop "renders an arbitrary short history without throwing" $
    forAll (resize 8 (listOf genMessage)) $ \msgs -> ioProperty $ do
      st <- mkState msgs
      -- Force the widget-list spine; total rendering code must not raise.
      n <- evaluate (length (drawUI st))
      pure (n == 1)

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
    n <- evaluate (length (drawUI st))
    n `shouldBe` 1

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

mkState :: [Message] -> IO AppState
mkState msgs = do
  chan <- BChan.newBChan 10
  pure AppState
    { asMessages   = Seq.fromList msgs
    , asInput      = E.editorText InputEditor (Just 1) ""
    , asRunState   = Idle
    , asStatusLine = "openai:gpt-4o"
    , asEventChan  = chan
    }

t0 :: UTCTime
t0 = UTCTime (fromGregorian 2026 5 29) 0

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
