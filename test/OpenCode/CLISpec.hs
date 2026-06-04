module OpenCode.CLISpec (spec) where

import Data.Either (isLeft)
import Data.List.NonEmpty (NonEmpty ((:|)))
import qualified Data.Text as T
import Data.Time (UTCTime (..), fromGregorian)
import Test.Hspec

import OpenCode.CLI
import OpenCode.Types
  ( Message (..), MessageId (..), MessagePart (..), ModelId (..), ProviderId (..)
  , Role (..), Session (..), SessionId (..), ToolArgs (..), ToolCall (..)
  , ToolResult (..)
  )

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
    it "parses bare 'run' as the default RunOpts" $
      parseArgs ["run"] `shouldBe` Just (Run defaultRunOpts)
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
    it "rejects 'config' without a sub-subcommand" $
      parseArgs ["config"] `shouldBe` Nothing
  describe "renderSessionList" $ do
    it "renders one row per session with model labels and a header" $ do
      let out = renderSessionList [sess1, sess2]
      length (T.lines out) `shouldBe` 3   -- header + 2 data rows, one newline each
      out `shouldSatisfy` T.isInfixOf "s-001"
      out `shouldSatisfy` T.isInfixOf "s-002"
      out `shouldSatisfy` T.isInfixOf "first"
      out `shouldSatisfy` T.isInfixOf "second"
      out `shouldSatisfy` T.isInfixOf "openai:gpt-4o"
      out `shouldSatisfy` T.isInfixOf "minimax:MiniMax-M3"
      out `shouldSatisfy` T.isInfixOf "ID"
    it "renders a placeholder for an empty list" $
      renderSessionList [] `shouldBe` "(no sessions)\n"
  describe "renderExportMarkdown" $
    it "renders metadata, role headings, and fenced tool blocks" $ do
      let md = renderExportMarkdown sess1 [userMsg, assistantMsg]
      md `shouldSatisfy` T.isInfixOf "# first"
      md `shouldSatisfy` T.isInfixOf "**ID:** s-001"
      md `shouldSatisfy` T.isInfixOf "**Model:** openai:gpt-4o"
      md `shouldSatisfy` T.isInfixOf "## User"
      md `shouldSatisfy` T.isInfixOf "## Assistant"
      md `shouldSatisfy` T.isInfixOf "hello"
      md `shouldSatisfy` T.isInfixOf "```bash"
      md `shouldSatisfy` T.isInfixOf "```result"
      md `shouldSatisfy` T.isInfixOf "file.txt"

t0 :: UTCTime
t0 = UTCTime (fromGregorian 2026 6 4) 0

sess1 :: Session
sess1 = Session (SessionId "s-001") "first" (ModelId OpenAI "gpt-4o") t0

sess2 :: Session
sess2 = Session (SessionId "s-002") "second" (ModelId MiniMax "MiniMax-M3") t0

userMsg :: Message
userMsg = Message (MessageId "m1") RoleUser (TextPart "hello" :| []) t0

assistantMsg :: Message
assistantMsg = Message (MessageId "m2") RoleAssistant
  ( ToolCallPart (ToolCall "c1" "bash" (ToolArgs "{\"command\":\"ls\"}"))
    :| [ ToolResultPart (ToolResult "c1" "file.txt" False) ] ) t0
