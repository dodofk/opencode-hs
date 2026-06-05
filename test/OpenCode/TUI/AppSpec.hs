module OpenCode.TUI.AppSpec (spec) where

import qualified Brick.Widgets.Edit as E
import Control.Concurrent (threadDelay)
import Control.Concurrent.STM (atomically, readTVarIO, writeTVar)
import qualified Data.List.NonEmpty as NE
import qualified Data.Sequence as Seq
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time (UTCTime (..), fromGregorian)
import System.Environment (unsetEnv)
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck (Property, ioProperty)

import OpenCode.App.Types (AppEnv (..))
import OpenCode.Session.Events (RunState (..), SessionEvent (..))
import OpenCode.TestEnv (drainBChan, newDummyEnv, newDummyEnvNoKey)
import OpenCode.TUI.App
  ( appendUserMessage
  , applyEnter
  , applyEvent
  , applyModelSet
  , applySwitch
  , currentInput
  , initialState
  , modelLabel
  , shouldSubmit
  , startRun
  )
import OpenCode.TUI.Types (AppState (..), ResourceName (InputEditor), UIMode (..))
import OpenCode.Types
  ( Message (..)
  , MessageId (..)
  , MessagePart (TextPart, ErrorPart)
  , ModelId (..)
  , ProviderId (..)
  , Role (RoleUser)
  , Session (..)
  , SessionId (..)
  , msgParts
  )

spec :: Spec
spec = do

  describe "appendUserMessage (append-and-clear helper)" $ do

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

  describe "applyEnter (the Enter-key action: submit gate + append + clear)" $ do

    it "appends the built message and clears the input when submittable" $ do
      st <- stateWithInput "hello there"
      let st' = applyEnter userMsg st
      Seq.length (asMessages st') `shouldBe` Seq.length (asMessages st) + 1
      currentInput st' `shouldBe` ""
      -- the message that landed in history is exactly the one we built
      fmap msgId (lastMsg st') `shouldBe` Just (msgId userMsg)

    it "leaves state unchanged on empty input" $ do
      st <- stateWithInput ""
      let st' = applyEnter userMsg st
      Seq.length (asMessages st') `shouldBe` Seq.length (asMessages st)
      currentInput st' `shouldBe` ""

    it "leaves state unchanged on whitespace-only input (input preserved, not cleared)" $ do
      st <- stateWithInput "   \n  "
      let st' = applyEnter userMsg st
      Seq.length (asMessages st') `shouldBe` Seq.length (asMessages st)
      currentInput st' `shouldBe` currentInput st

    prop "submits iff the current input is non-blank" $
      \(content :: String) -> ioProp $ do
        st <- stateWithInput' content
        let st'  = applyEnter userMsg st
            gate = shouldSubmit (currentInput st)
        pure $ if gate
          then Seq.length (asMessages st') == Seq.length (asMessages st) + 1
               && currentInput st' == ""
          else Seq.length (asMessages st') == Seq.length (asMessages st)
               && currentInput st' == currentInput st

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
      env <- newDummyEnv
      let st = initialState env sampleSession [userMsg, userMsg]
      Seq.length (asMessages st) `shouldBe` 2
      asRunState st `shouldBe` Idle
      currentInput st `shouldBe` ""
      asStatusLine st `shouldBe` "openai:gpt-4o"
      asPartialText st `shouldBe` ""
      asTitle st `shouldBe` "untitled"
      asMode st `shouldBe` ModeNormal
      asNotice st `shouldBe` Nothing

  describe "applyEvent (session-event reducer)" $ do

    it "PartialText accumulates into asPartialText" $ do
      st <- stateWithInput ""
      let st' = applyEvent (PartialText "cd") (applyEvent (PartialText "ab") st)
      asPartialText st' `shouldBe` "abcd"

    it "MessageAppended appends the message and clears the partial buffer" $ do
      st0 <- stateWithInput ""
      let st1 = applyEvent (PartialText "draft") st0
          st2 = applyEvent (MessageAppended userMsg) st1
      Seq.length (asMessages st2) `shouldBe` 1
      asPartialText st2 `shouldBe` ""

    it "ToolStarted sets RunningTool" $ do
      st <- stateWithInput ""
      asRunState (applyEvent (ToolStarted "bash") st) `shouldBe` RunningTool "bash"

    it "ToolFinished is a no-op" $ do
      st <- stateWithInput ""
      let st' = applyEvent (ToolFinished "bash" "out") st
      asRunState st' `shouldBe` asRunState st
      Seq.length (asMessages st') `shouldBe` Seq.length (asMessages st)

    it "RunStateChanged Idle clears the partial buffer" $ do
      st0 <- stateWithInput ""
      let st2 = applyEvent (RunStateChanged Idle) (applyEvent (PartialText "x") st0)
      asRunState st2 `shouldBe` Idle
      asPartialText st2 `shouldBe` ""

    it "RunStateChanged RunningLLM keeps the partial buffer" $ do
      st0 <- stateWithInput ""
      let st2 = applyEvent (RunStateChanged RunningLLM) (applyEvent (PartialText "x") st0)
      asRunState st2 `shouldBe` RunningLLM
      asPartialText st2 `shouldBe` "x"

    it "ErrorOccurred appends a synthetic error message" $ do
      st <- stateWithInput ""
      let st' = applyEvent (ErrorOccurred "boom") st
      Seq.length (asMessages st') `shouldBe` 1
      case Seq.lookup 0 (asMessages st') of
        Just m  -> NE.toList (msgParts m) `shouldBe` [ErrorPart "boom"]
        Nothing -> expectationFailure "expected one message"

    it "PartialReasoning accumulates into asPartialReasoning" $ do
      st <- stateWithInput ""
      let st' = applyEvent (PartialReasoning "cd") (applyEvent (PartialReasoning "ab") st)
      asPartialReasoning st' `shouldBe` "abcd"

    it "RunStateChanged Idle clears the reasoning buffer" $ do
      st0 <- stateWithInput ""
      let st2 = applyEvent (RunStateChanged Idle) (applyEvent (PartialReasoning "x") st0)
      asPartialReasoning st2 `shouldBe` ""

    it "RoundStarted sets asRound and Idle clears it" $ do
      st0 <- stateWithInput ""
      let st1 = applyEvent (RoundStarted 2 10) st0
          st2 = applyEvent (RunStateChanged Idle) st1
      asRound st1 `shouldBe` Just (2, 10)
      asRound st2 `shouldBe` Nothing

    it "SessionTitleChanged updates asTitle" $ do
      st <- stateWithInput ""
      asTitle (applyEvent (SessionTitleChanged "My Chat") st) `shouldBe` "My Chat"

  describe "applySwitch (session switch reducer)" $
    it "replaces history/id/title/model and resets view state" $ do
      st0 <- stateWithInput "typing"
      let other = Session (SessionId "s-other") "Other Chat"
                    (ModelId Anthropic "claude-opus-4-5") t0
          st1 = (applyEvent (PartialText "draft") st0) { asRound = Just (2, 10) }
          st2 = applySwitch other [userMsg, userMsg] st1
      asSessionId st2 `shouldBe` SessionId "s-other"
      asTitle st2 `shouldBe` "Other Chat"
      asStatusLine st2 `shouldBe` "anthropic:claude-opus-4-5"
      Seq.length (asMessages st2) `shouldBe` 2
      asPartialText st2 `shouldBe` ""
      asRound st2 `shouldBe` Nothing
      asRunState st2 `shouldBe` Idle
      asMode st2 `shouldBe` ModeNormal

  describe "applyModelSet (model switch reducer)" $
    it "updates the status line and sets a confirmation notice" $ do
      st0 <- stateWithInput ""
      let st1 = applyModelSet (ModelId Anthropic "claude-opus-4-5") st0
      asStatusLine st1 `shouldBe` "anthropic:claude-opus-4-5"
      asNotice st1 `shouldBe` Just "model set to anthropic:claude-opus-4-5"
      asMode st1 `shouldBe` ModeNormal

  describe "startRun (forked agentic run)" $ do

    it "resets the abort flag synchronously before forking" $ do
      unsetEnv "OPENCODE_MOCK"
      env <- newDummyEnvNoKey
      atomically (writeTVar (envAbort env) True)
      startRun env (SessionId "s-1") "hi"
      threadDelay 100000              -- let the fork run and fail
      readTVarIO (envAbort env) `shouldReturn` False

    it "surfaces a missing-key error as ErrorOccurred then Idle" $ do
      unsetEnv "OPENCODE_MOCK"
      env <- newDummyEnvNoKey
      startRun env (SessionId "s-1") "hi"
      threadDelay 100000              -- let the fork run and fail
      evts <- drainBChan (envEventChan env)
      any isErrorEvt evts `shouldBe` True
      lastMay evts `shouldBe` Just (RunStateChanged Idle)

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

ioProp :: IO Bool -> Property
ioProp = ioProperty

stateWithInput :: Text -> IO AppState
stateWithInput t = do
  env <- newDummyEnv
  pure AppState
    { asMessages         = Seq.empty
    , asInput            = E.editorText InputEditor (Just 1) t
    , asRunState         = Idle
    , asStatusLine       = "openai:gpt-4o"
    , asPartialText      = ""
    , asPartialReasoning = ""
    , asRound            = Nothing
    , asTitle            = "untitled"
    , asEnv              = env
    , asSessionId        = sessionId sampleSession
    , asMode             = ModeNormal
    , asNotice           = Nothing
    }

stateWithInput' :: String -> IO AppState
stateWithInput' = stateWithInput . T.pack

lastMsg :: AppState -> Maybe Message
lastMsg st = Seq.lookup (Seq.length s - 1) s
  where s = asMessages st

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

isErrorEvt :: SessionEvent -> Bool
isErrorEvt (ErrorOccurred _) = True
isErrorEvt _                 = False

lastMay :: [a] -> Maybe a
lastMay [] = Nothing
lastMay xs = Just (last xs)
