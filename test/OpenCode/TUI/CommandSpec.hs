module OpenCode.TUI.CommandSpec (spec) where

import Test.Hspec

import OpenCode.TUI.Command (Command (..), parseCommand, commandSuggestions, clampSel)

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

  it "splits the command from tab-separated arguments" $
    parseCommand "/model\topenai:gpt-4o" `shouldBe` Just CmdModel

  it "treats a bare slash as an unknown command" $
    parseCommand "/" `shouldBe` Just (CmdUnknown "/")

  describe "commandSuggestions" $ do
    it "lists every command for a bare slash, in catalog order" $
      map fst (commandSuggestions "/") `shouldBe`
        ["/new", "/sessions", "/model", "/help", "/quit"]

    it "filters by case-insensitive name prefix" $
      map fst (commandSuggestions "/se") `shouldBe` ["/sessions"]

    it "is case-insensitive on the typed prefix" $
      map fst (commandSuggestions "/SE") `shouldBe` ["/sessions"]

    it "tolerates leading whitespace" $
      map fst (commandSuggestions "  /m") `shouldBe` ["/model"]

    it "returns nothing for non-slash input" $
      commandSuggestions "hello" `shouldBe` []

    it "returns nothing for an unknown command" $
      commandSuggestions "/foo" `shouldBe` []

    it "pairs each match with its description" $
      lookup "/model" (commandSuggestions "/m")
        `shouldBe` Just "change model (this session)"

  describe "clampSel" $ do
    it "clamps a negative index to zero"      $ clampSel 3 (-5) `shouldBe` 0
    it "clamps an over-large index to n-1"    $ clampSel 3 99   `shouldBe` 2
    it "passes an in-range index through"      $ clampSel 3 1    `shouldBe` 1
    it "is zero for an empty list"             $ clampSel 0 4    `shouldBe` 0
