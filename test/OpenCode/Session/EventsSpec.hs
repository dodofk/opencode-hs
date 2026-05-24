module OpenCode.Session.EventsSpec (spec) where

import Test.Hspec

import OpenCode.Session.Events

spec :: Spec
spec = do
  describe "RunState shape" $ do

    it "Idle, RunningLLM, AwaitingInput are distinct" $ do
      Idle `shouldNotBe` RunningLLM
      RunningLLM `shouldNotBe` AwaitingInput
      Idle `shouldNotBe` AwaitingInput

    it "RunningTool carries the tool name" $
      RunningTool "bash" `shouldNotBe` RunningTool "grep"

  describe "SessionEvent shape" $ do

    it "PartialText carries the text" $
      PartialText "hi" `shouldNotBe` PartialText "bye"

    it "ToolStarted / ToolFinished are distinct constructors" $
      ToolStarted "bash" `shouldNotBe` ToolFinished "bash" "ok"

    it "RunStateChanged wraps a RunState" $
      RunStateChanged Idle `shouldNotBe` RunStateChanged RunningLLM

    it "ErrorOccurred carries a message" $
      ErrorOccurred "boom" `shouldNotBe` ErrorOccurred "kaboom"
