{-# LANGUAGE OverloadedStrings #-}
module OpenCode.MCP.ClientSpec (spec) where

import qualified Data.Aeson as Aeson
import Data.Text (Text)
import qualified Data.Text as T
import Test.Hspec

import OpenCode.MCP.Adapters (clientSomeTools, resourceTools)
import OpenCode.MCP.Client (callTool, getPrompt, mcCaps, mcPrompts,
                            mcResources, mcTools, readResource, renderMcpError)
import OpenCode.MCP.Protocol
import OpenCode.Tool.Types (SomeTool (..))
import OpenCode.McpMock (withMock)

spec :: Spec
spec = describe "OpenCode.MCP.Client (against the mock server)" $ do
  it "handshakes and caches the three capability lists" $ withMock $ \c -> do
    capTools (mcCaps c)     `shouldBe` True
    capResources (mcCaps c) `shouldBe` True
    capPrompts (mcCaps c)   `shouldBe` True
    map mtName (mcTools c)    `shouldBe` ["echo"]
    map mrUri  (mcResources c) `shouldBe` ["mock://a"]
    map mpName (mcPrompts c)  `shouldBe` ["greet"]

  it "exposes namespaced tools incl. synthesized resource tools via the adapter" $ withMock $ \c -> do
    -- the mock advertises one tool (echo) + resources, so the adapter yields
    -- the namespaced real tool plus the two synthesized resource tools.
    map toolName (clientSomeTools c)
      `shouldBe` ["mock_echo", "mock_list_resources", "mock_read_resource"]
    length (resourceTools c) `shouldBe` 2

  it "round-trips a tools/call (echo)" $ withMock $ \c -> do
    r <- callTool c "echo" (Aeson.object ["msg" Aeson..= ("hi" :: Text)])
    case r of
      Right res -> renderContent (ctrContent res) `shouldSatisfy` ("hi" `T.isInfixOf`)
      Left e    -> expectationFailure (T.unpack (renderMcpError e))

  it "reads a resource" $ withMock $ \c -> do
    r <- readResource c "mock://a"
    fmap (renderContent . rrContents) r `shouldBe` Right "resource body"

  it "gets a prompt" $ withMock $ \c -> do
    r <- getPrompt c "greet" []
    fmap (map pmText . gprMessages) r `shouldBe` Right ["hello there"]

  it "returns Left when a tool call errors (graceful failure)" $ withMock $ \c -> do
    -- the mock replies with a JSON-RPC error for the "boom" tool; the client
    -- must surface that as Left without throwing.
    r <- callTool c "boom" (Aeson.object [])
    case r of
      Left _  -> pure ()
      Right _ -> expectationFailure "expected Left for the boom tool"
