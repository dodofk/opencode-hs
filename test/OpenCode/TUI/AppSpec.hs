module OpenCode.TUI.AppSpec (spec) where

import qualified Brick.BChan as BChan
import qualified Brick.Widgets.Edit as E
import qualified Data.List.NonEmpty as NE
import qualified Data.Sequence as Seq
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time (UTCTime (..), fromGregorian)
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck (Property, ioProperty)

import OpenCode.Session.Events (RunState (Idle))
import OpenCode.TUI.App
  ( appendUserMessage
  , currentInput
  , initialState
  , modelLabel
  , shouldSubmit
  )
import OpenCode.TUI.Types (AppState (..), ResourceName (InputEditor))
import OpenCode.Types
  ( Message (..)
  , MessageId (..)
  , MessagePart (TextPart)
  , ModelId (..)
  , ProviderId (..)
  , Role (RoleUser)
  , Session (..)
  , SessionId (..)
  )

spec :: Spec
spec = do

  describe "appendUserMessage (the Enter action)" $ do

    it "appends the message and clears the input buffer" $ do
      st  <- stateWithInput "hello there"
      let st' = appendUserMessage userMsg st
      Seq.length (asMessages st') `shouldBe` Seq.length (asMessages st) + 1
      currentInput st' `shouldBe` ""

    prop "increments history length by exactly one regardless of prior input" $
      \(content :: String) -> ioProp $ do
        st <- stateWithInput' content
        let st' = appendUserMessage userMsg st
        pure $ Seq.length (asMessages st') == Seq.length (asMessages st) + 1
             && currentInput st' == ""

  describe "shouldSubmit" $ do
    it "rejects empty input" $ shouldSubmit "" `shouldBe` False
    it "rejects whitespace-only input" $ shouldSubmit "   \n  " `shouldBe` False
    it "accepts non-blank input" $ shouldSubmit "hi" `shouldBe` True

  describe "modelLabel" $ do
    it "formats an OpenAI model" $
      modelLabel (ModelId OpenAI "gpt-4o") `shouldBe` "openai:gpt-4o"
    it "formats an Anthropic model" $
      modelLabel (ModelId Anthropic "claude-opus-4-7")
        `shouldBe` "anthropic:claude-opus-4-7"

  describe "initialState" $ do
    it "loads the given history and starts Idle with an empty input" $ do
      chan <- BChan.newBChan 10
      let st = initialState chan sampleSession [userMsg, userMsg]
      Seq.length (asMessages st) `shouldBe` 2
      asRunState st `shouldBe` Idle
      currentInput st `shouldBe` ""
      asStatusLine st `shouldBe` "openai:gpt-4o"

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

ioProp :: IO Bool -> Property
ioProp = ioProperty

stateWithInput :: Text -> IO AppState
stateWithInput t = do
  chan <- BChan.newBChan 10
  pure AppState
    { asMessages   = Seq.empty
    , asInput      = E.editorText InputEditor (Just 1) t
    , asRunState   = Idle
    , asStatusLine = "openai:gpt-4o"
    , asEventChan  = chan
    }

stateWithInput' :: String -> IO AppState
stateWithInput' = stateWithInput . T.pack

userMsg :: Message
userMsg = Message
  { msgId      = MessageId "m-user"
  , msgRole    = RoleUser
  , msgParts   = TextPart "hello there" NE.:| []
  , msgCreated = t0
  }

sampleSession :: Session
sampleSession = Session
  { sessionId      = SessionId "s-1"
  , sessionTitle   = "untitled"
  , sessionModel   = ModelId OpenAI "gpt-4o"
  , sessionCreated = t0
  }

t0 :: UTCTime
t0 = UTCTime (fromGregorian 2026 5 29) 0
