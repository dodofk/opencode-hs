module OpenCode.LLM.RequestSpec (spec) where

import Conduit (ConduitT, runConduit, yieldMany, sinkList, (.|))
import Control.Monad.Identity (Identity, runIdentity)
import Data.ByteString (ByteString)
import Test.Hspec

import OpenCode.LLM.Request

spec :: Spec
spec = do
  describe "sseDataLine" $ do

    it "extracts payload from a data: line" $
      sseDataLine "data: {\"foo\":1}" `shouldBe` Just "{\"foo\":1}"

    it "returns Just \"[DONE]\" for the done sentinel" $
      sseDataLine "data: [DONE]" `shouldBe` Just "[DONE]"

    it "returns Nothing for a comment line" $
      sseDataLine ": this is a comment" `shouldBe` Nothing

    it "returns Nothing for an event: line" $
      sseDataLine "event: ping" `shouldBe` Nothing

    it "returns Nothing for a blank line" $
      sseDataLine "" `shouldBe` Nothing

  describe "chunkSSELines" $ do

    it "splits a single complete line into one chunk" $
      runChunker ["data: hello\n"] `shouldBe` ["data: hello"]

    it "handles a line split across two input chunks" $
      runChunker ["data: hel", "lo\n"] `shouldBe` ["data: hello"]

    it "handles two lines in one input chunk" $
      runChunker ["data: a\ndata: b\n"] `shouldBe` ["data: a", "data: b"]

    it "preserves order across many splits" $
      runChunker ["da", "ta: a\nda", "ta: b\nda", "ta: c\n"]
        `shouldBe` ["data: a", "data: b", "data: c"]

    it "emits blank lines as empty bytestrings" $
      runChunker ["data: a\n\ndata: b\n"]
        `shouldBe` ["data: a", "", "data: b"]

    it "flushes any unterminated trailing line at end of stream" $
      runChunker ["data: a\ndata: b"]
        `shouldBe` ["data: a", "data: b"]

    it "strips trailing CR from CRLF line endings" $
      runChunker ["data: hello\r\n"] `shouldBe` ["data: hello"]

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

runChunker :: [ByteString] -> [ByteString]
runChunker inputs = runIdentity $ runConduit $
  yieldMany inputs .| (chunkSSELines :: ConduitT ByteString ByteString Identity ()) .| sinkList
