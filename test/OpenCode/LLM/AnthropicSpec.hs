module OpenCode.LLM.AnthropicSpec (spec) where

import Conduit qualified
import Conduit ((.|))
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Map.Strict qualified as Map
import Test.Hspec

import OpenCode.LLM.Anthropic
import OpenCode.Types (StreamEvent (..), Usage (..))

spec :: Spec
spec = do
  describe "decodeEvent" $ do

    it "parses a text_delta event" $
      decodeEvent "{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Hi\"}}"
        `shouldBe` Right (EvBlockDelta 0 (DeltaText "Hi"))

    it "parses a tool_use content_block_start" $
      decodeEvent "{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"t1\",\"name\":\"bash\",\"input\":{}}}"
        `shouldBe` Right (EvBlockStart 0 (BlockToolUse "t1" "bash"))

    it "parses a message_delta with output usage" $
      decodeEvent "{\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":7}}"
        `shouldBe` Right (EvMessageDelta (Just 7))

    it "parses an error event" $
      decodeEvent "{\"type\":\"error\",\"error\":{\"type\":\"overloaded_error\",\"message\":\"Overloaded\"}}"
        `shouldBe` Right (EvError "Overloaded")

  describe "processAnthropicEvent" $ do

    it "emits ToolCallStart and records the block id" $
      let (evs, acc) = processAnthropicEvent emptyAccum (EvBlockStart 0 (BlockToolUse "t1" "bash"))
      in do
        evs `shouldBe` [ToolCallStart "t1" "bash"]
        Map.lookup 0 (accBlocks acc) `shouldBe` Just "t1"

    it "maps input_json_delta to ToolCallArgDelta via the recorded id" $
      let (_, acc) = processAnthropicEvent emptyAccum (EvBlockStart 0 (BlockToolUse "t1" "bash"))
          (evs, _) = processAnthropicEvent acc (EvBlockDelta 0 (DeltaInputJson "{\"a\":1}"))
      in evs `shouldBe` [ToolCallArgDelta "t1" "{\"a\":1}"]

    it "emits ToolCallEnd on content_block_stop for a tool block" $
      let (_, acc) = processAnthropicEvent emptyAccum (EvBlockStart 0 (BlockToolUse "t1" "bash"))
          (evs, _) = processAnthropicEvent acc (EvBlockStop 0)
      in evs `shouldBe` [ToolCallEnd "t1"]

    it "emits StreamDone combining stored input with output tokens" $
      let (_, acc) = processAnthropicEvent emptyAccum (EvMessageStart 12)
          (evs, _) = processAnthropicEvent acc (EvMessageDelta (Just 3))
      in evs `shouldBe` [StreamDone (Usage 12 3 Nothing Nothing)]

    it "emits TextDelta for text deltas" $
      fst (processAnthropicEvent emptyAccum (EvBlockDelta 0 (DeltaText "hey")))
        `shouldBe` [TextDelta "hey"]

  describe "interpretAnthropicStream" $ do

    it "reassembles a multi-block text response into TextDelta + StreamDone" $ do
      events <- runStream "test/fixtures/anthropic/text-stream.sse"
      events `shouldBe`
        [ TextDelta "Hello", TextDelta " world", StreamDone (Usage 10 2 Nothing Nothing) ]

    it "decodes a fragmented tool call into ordered start/delta/end events" $ do
      events <- runStream "test/fixtures/anthropic/tool-call-stream.sse"
      events `shouldBe`
        [ ToolCallStart "toolu_abc" "bash"
        , ToolCallArgDelta "toolu_abc" "{\"command\":"
        , ToolCallArgDelta "toolu_abc" "\"echo hi\"}"
        , ToolCallEnd "toolu_abc"
        , StreamDone (Usage 50 15 Nothing Nothing)
        ]

    it "emits exactly one StreamError on an error event" $ do
      events <- runStream "test/fixtures/anthropic/error.sse"
      events `shouldBe` [StreamError "Overloaded"]

  describe "anthropicErrorFromHttp" $
    it "includes the status code and body snippet" $
      anthropicErrorFromHttp 529 "overloaded"
        `shouldBe` StreamError "anthropic: 529: overloaded"

runStream :: FilePath -> IO [StreamEvent]
runStream path = do
  body <- BS.readFile path
  Conduit.runResourceT $ Conduit.runConduit $
    Conduit.yieldMany [body :: ByteString]
      .| interpretAnthropicStream
      .| Conduit.sinkList
