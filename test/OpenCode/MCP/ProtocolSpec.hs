{-# LANGUAGE OverloadedStrings #-}
module OpenCode.MCP.ProtocolSpec (spec) where

import qualified Data.Aeson as Aeson
import qualified Data.ByteString.Lazy as BL
import qualified Data.ByteString.Char8 as BS8
import Data.Either (isLeft)
import Data.Maybe (fromMaybe)
import Test.Hspec

import OpenCode.MCP.Protocol

spec :: Spec
spec = do
  describe "encodeRequest" $ do
    it "produces a single line with jsonrpc/id/method" $ do
      let bs = encodeRequest (JsonRpcRequest 7 "tools/list" (Aeson.object []))
      BL.notElem 0x0a bs `shouldBe` True            -- no embedded newline
      case Aeson.decode bs :: Maybe Aeson.Value of
        Nothing -> expectationFailure "could not decode encoded request"
        Just v  -> v `shouldBe` Aeson.object
          [ "jsonrpc" Aeson..= ("2.0" :: String)
          , "id"      Aeson..= (7 :: Int)
          , "method"  Aeson..= ("tools/list" :: String)
          , "params"  Aeson..= Aeson.object []
          ]

  describe "parseResponse" $ do
    it "decodes a result response" $ do
      let line = "{\"jsonrpc\":\"2.0\",\"id\":3,\"result\":{\"ok\":true}}"
      parseResponse (BS8.pack line) `shouldBe`
        Right (Right (JsonRpcResponse 3 (Right (Aeson.object ["ok" Aeson..= True]))))

    it "decodes an error response" $ do
      let line = "{\"jsonrpc\":\"2.0\",\"id\":3,\"error\":{\"code\":-32601,\"message\":\"nope\"}}"
      parseResponse (BS8.pack line) `shouldBe`
        Right (Right (JsonRpcResponse 3 (Left (JsonRpcError (-32601) "nope"))))

    it "classifies a notification (no id)" $ do
      let line = "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/log\",\"params\":{}}"
      case parseResponse (BS8.pack line) of
        Right (Left ntf) -> ntfMethod ntf `shouldBe` "notifications/log"
        other            -> expectationFailure (show other)

    it "rejects non-JSON" $
      parseResponse "not json" `shouldSatisfy` isLeft

  describe "decoders tolerate unknown fields and parse lists" $ do
    it "initialize capabilities" $ do
      let v = obj "{\"protocolVersion\":\"x\",\"capabilities\":{\"tools\":{},\"prompts\":{}},\"extra\":1}"
      case Aeson.fromJSON v :: Aeson.Result InitializeResult of
        Aeson.Error e  -> expectationFailure e
        Aeson.Success ir -> do
          capTools (initCapabilities ir)     `shouldBe` True
          capPrompts (initCapabilities ir)   `shouldBe` True
          capResources (initCapabilities ir) `shouldBe` False

    it "tools/list" $
      decodeToolsList (obj "{\"tools\":[{\"name\":\"echo\",\"description\":\"d\",\"inputSchema\":{}}]}")
        `shouldBe` Right [McpToolDef "echo" "d" (Aeson.object [])]

    it "tools/call with text and non-text content + isError" $ do
      let v = obj "{\"content\":[{\"type\":\"text\",\"text\":\"hi\"},{\"type\":\"image\"}],\"isError\":true}"
      case Aeson.fromJSON v :: Aeson.Result CallToolResult of
        Aeson.Error e  -> expectationFailure e
        Aeson.Success r -> do
          ctrIsError r `shouldBe` True
          renderContent (ctrContent r) `shouldBe` "hi\n[non-text content omitted]"

    it "resources/read (untyped content with text)" $ do
      let v = obj "{\"contents\":[{\"uri\":\"u\",\"text\":\"body\"}]}"
      case Aeson.fromJSON v :: Aeson.Result ReadResourceResult of
        Aeson.Error e  -> expectationFailure e
        Aeson.Success r -> renderContent (rrContents r) `shouldBe` "body"

    it "prompts/list" $
      decodePromptsList (obj "{\"prompts\":[{\"name\":\"g\",\"description\":\"d\",\"arguments\":[{\"name\":\"x\",\"required\":true}]}]}")
        `shouldBe` Right [McpPrompt "g" (Just "d") [McpPromptArg "x" Nothing True]]

    it "prompts/get" $ do
      let v = obj "{\"messages\":[{\"role\":\"user\",\"content\":{\"type\":\"text\",\"text\":\"hey\"}}]}"
      case Aeson.fromJSON v :: Aeson.Result GetPromptResult of
        Aeson.Error e  -> expectationFailure e
        Aeson.Success r -> do
          map pmText (gprMessages r) `shouldBe` ["hey"]
          map pmRole (gprMessages r) `shouldBe` ["user"]

obj :: String -> Aeson.Value
obj s = fromMaybe (error "bad json fixture") (Aeson.decode (BL.fromStrict (BS8.pack s)))
