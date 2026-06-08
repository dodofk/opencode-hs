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

  describe "promptEntryOf" $
    it "builds a full name + required-arg list from an McpPrompt" $ do
      let p = McpPrompt "greet" (Just "d") [McpPromptArg "name" Nothing True, McpPromptArg "lang" Nothing False]
          e = promptEntryOf "srv" p
      peFullName e     `shouldBe` "srv_greet"
      peServer e       `shouldBe` "srv"
      peName e         `shouldBe` "greet"
      peDescription e  `shouldBe` "d"
      peRequiredArgs e `shouldBe` ["name"]

  describe "resourceReadSchema is a valid object schema" $
    it "round-trips through aeson" $
      Aeson.decode (Aeson.encode resourceReadSchema) `shouldBe` Just resourceReadSchema
