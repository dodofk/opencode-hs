{-# LANGUAGE OverloadedStrings #-}
module OpenCode.MCP.AdaptersSpec (spec) where

import qualified Data.Aeson as Aeson
import Test.Hspec

import OpenCode.MCP.Adapters
import OpenCode.MCP.Protocol (McpPrompt (..), McpPromptArg (..))

spec :: Spec
spec = do
  describe "mcpToolName" $
    it "namespaces tool by server with underscore" $
      mcpToolName "filesystem" "read_file" `shouldBe` "filesystem_read_file"

  describe "parsePromptInvocation" $ do
    it "parses a bare /name" $
      parsePromptInvocation "/greet" `shouldBe` Just ("greet", [])

    it "parses key=value args" $
      parsePromptInvocation "/srv_greet name=ann lang=en"
        `shouldBe` Just ("srv_greet", [("name", "ann"), ("lang", "en")])

    it "ignores tokens without '='" $
      parsePromptInvocation "/greet hello name=ann"
        `shouldBe` Just ("greet", [("name", "ann")])

    it "splits on the first '=' only" $
      parsePromptInvocation "/greet k=v=w" `shouldBe` Just ("greet", [("k", "v=w")])

    it "passes an empty value through" $
      parsePromptInvocation "/greet foo=" `shouldBe` Just ("greet", [("foo", "")])

    it "returns Nothing for non-slash input" $
      parsePromptInvocation "hello world" `shouldBe` Nothing

    it "returns Nothing for a bare slash" $
      parsePromptInvocation "/" `shouldBe` Nothing

  describe "promptEntryOf" $
    it "builds a full name + required-arg list from an McpPrompt" $ do
      let p = McpPrompt "greet" (Just "d") [McpPromptArg "name" Nothing True, McpPromptArg "lang" Nothing False]
          e = promptEntryOf "srv" p
      peFullName e     `shouldBe` "srv_greet"
      peServer e       `shouldBe` "srv"
      peName e         `shouldBe` "greet"
      peDescription e  `shouldBe` "d"
      peRequiredArgs e `shouldBe` ["name"]

  describe "missingArgs" $ do
    it "reports required args that are absent" $
      missingArgs (PromptEntry "x" "s" "x" "" ["name"]) [] `shouldBe` ["name"]
    it "is empty when all present" $
      missingArgs (PromptEntry "x" "s" "x" "" ["name"]) [("name", "a")] `shouldBe` []

  describe "resourceReadSchema is a valid object schema" $
    it "round-trips through aeson" $
      Aeson.decode (Aeson.encode resourceReadSchema) `shouldBe` Just resourceReadSchema
