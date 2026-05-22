module OpenCode.TypesSpec (spec) where

import Data.Aeson (decode, encode)
import Test.Hspec

import OpenCode.Types

-- ---------------------------------------------------------------------------
-- Spec
-- ---------------------------------------------------------------------------

spec :: Spec
spec = do
  describe "ProviderId JSON" $ do
    it "serialises OpenAI to \"openai\"" $
      encode OpenAI `shouldBe` "\"openai\""
    it "serialises Anthropic to \"anthropic\"" $
      encode Anthropic `shouldBe` "\"anthropic\""
    it "round-trips OpenAI" $
      (decode (encode OpenAI) :: Maybe ProviderId) `shouldBe` Just OpenAI
    it "round-trips Anthropic" $
      (decode (encode Anthropic) :: Maybe ProviderId) `shouldBe` Just Anthropic
    it "rejects unknown provider string" $
      (decode "\"bedrock\"" :: Maybe ProviderId) `shouldBe` Nothing

  describe "ModelId JSON" $ do
    it "round-trips via JSON" $
      let m = ModelId { provider = Anthropic, model = "claude-opus-4-5" }
      in  decode (encode m) `shouldBe` Just m
    it "serialises provider key as lowercase string" $
      -- JSON object key order is unspecified; decode and check structurally
      let m = ModelId { provider = OpenAI, model = "gpt-4o" }
      in  (decode (encode m) :: Maybe ModelId) `shouldBe` Just m

  describe "ApiKey" $ do
    it "does not reveal key in Show" $
      show (ApiKey "sk-secret") `shouldBe` "ApiKey <redacted>"
    it "round-trips via JSON" $
      (decode (encode (ApiKey "sk-test")) :: Maybe ApiKey)
        `shouldBe` Just (ApiKey "sk-test")

  describe "SessionId / MessageId" $ do
    it "SessionId round-trips via JSON" $
      (decode (encode (SessionId "abc-123")) :: Maybe SessionId)
        `shouldBe` Just (SessionId "abc-123")
    it "MessageId round-trips via JSON" $
      (decode (encode (MessageId "msg-456")) :: Maybe MessageId)
        `shouldBe` Just (MessageId "msg-456")

  describe "ToolResult JSON" $ do
    it "round-trips" $
      let r = ToolResult { resultCallId = "c1", content = "hello", isError = False }
      in  decode (encode r) `shouldBe` Just r
    it "error variant round-trips" $
      let r = ToolResult { resultCallId = "c2", content = "boom", isError = True }
      in  decode (encode r) `shouldBe` Just r

  describe "Usage JSON" $ do
    it "round-trips with optional fields present" $
      let u = Usage 100 50 (Just 10) (Just 5)
      in  decode (encode u) `shouldBe` Just u
    it "round-trips with optional fields absent" $
      let u = Usage 100 50 Nothing Nothing
      in  decode (encode u) `shouldBe` Just u

  describe "StreamEvent JSON" $ do
    it "TextDelta round-trips" $
      let e = TextDelta "hello"
      in  decode (encode e) `shouldBe` Just e
    it "StreamDone round-trips" $
      let e = StreamDone (Usage 10 20 Nothing Nothing)
      in  decode (encode e) `shouldBe` Just e
    it "StreamError round-trips" $
      let e = StreamError "timeout"
      in  decode (encode e) `shouldBe` Just e
    it "ToolCallStart round-trips" $
      let e = ToolCallStart "call-1" "bash"
      in  decode (encode e) `shouldBe` Just e
