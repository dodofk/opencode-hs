module OpenCode.CLISpec (spec) where

import Data.Either (isLeft)
import Test.Hspec

import OpenCode.CLI
import OpenCode.Types (ModelId (..), ProviderId (..), SessionId (..))

spec :: Spec
spec = do
  describe "parseModelId" $ do
    it "parses openai:gpt-4o" $
      parseModelId "openai:gpt-4o" `shouldBe` Right (ModelId OpenAI "gpt-4o")
    it "parses minimax:MiniMax-M3" $
      parseModelId "minimax:MiniMax-M3" `shouldBe` Right (ModelId MiniMax "MiniMax-M3")
    it "parses anthropic:claude-opus-4-5" $
      parseModelId "anthropic:claude-opus-4-5"
        `shouldBe` Right (ModelId Anthropic "claude-opus-4-5")
    it "rejects a string with no colon" $
      parseModelId "garbage" `shouldSatisfy` isLeft
    it "rejects an empty model part" $
      parseModelId "openai:" `shouldSatisfy` isLeft
    it "rejects an unknown provider" $
      parseModelId "weird:m" `shouldSatisfy` isLeft
  describe "parseArgs (command grammar)" $ do
    it "parses no args as the default Run" $
      parseArgs [] `shouldBe` Just (Run defaultRunOpts)
    it "parses 'list'" $
      parseArgs ["list"] `shouldBe` Just List
    it "parses 'export <id>'" $
      parseArgs ["export", "abc"] `shouldBe` Just (Export (SessionId "abc"))
    it "parses 'config check'" $
      parseArgs ["config", "check"] `shouldBe` Just ConfigCheck
    it "parses run flags" $
      parseArgs ["run", "--no-tui", "--prompt", "hi", "--model", "openai:gpt-4o"]
        `shouldBe` Just (Run RunOpts
          { roSession = Nothing
          , roModel   = Just (ModelId OpenAI "gpt-4o")
          , roPrompt  = Just "hi"
          , roNoTui   = True
          })
    it "rejects an invalid --model" $
      parseArgs ["run", "--model", "garbage"] `shouldBe` Nothing
    it "rejects an unknown subcommand" $
      parseArgs ["frobnicate"] `shouldBe` Nothing
