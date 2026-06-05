module OpenCode.TUI.CommandSpec (spec) where

import Test.Hspec

import OpenCode.TUI.Command (Command (..), parseCommand)

spec :: Spec
spec = describe "parseCommand" $ do
  it "treats non-slash input as a prompt (Nothing)" $
    parseCommand "hello world" `shouldBe` Nothing

  it "treats blank input as a prompt (Nothing)" $
    parseCommand "   " `shouldBe` Nothing

  it "parses each known command" $ do
    parseCommand "/new"      `shouldBe` Just CmdNew
    parseCommand "/sessions" `shouldBe` Just CmdSessions
    parseCommand "/model"    `shouldBe` Just CmdModel
    parseCommand "/help"     `shouldBe` Just CmdHelp
    parseCommand "/quit"     `shouldBe` Just CmdQuit

  it "is case-insensitive" $
    parseCommand "/MODEL" `shouldBe` Just CmdModel

  it "ignores surrounding whitespace" $
    parseCommand "   /help  " `shouldBe` Just CmdHelp

  it "ignores trailing arguments" $
    parseCommand "/model openai:gpt-4o" `shouldBe` Just CmdModel

  it "reports an unknown slash command (lower-cased first word)" $
    parseCommand "/Foo bar" `shouldBe` Just (CmdUnknown "/foo")
