module OpenCode.LLM.MockSpec (spec) where

import qualified Conduit
import Conduit ((.|))
import Test.Hspec

import OpenCode.LLM.Mock
import OpenCode.LLM.Types (LLMRequest (..))
import OpenCode.Types (StreamEvent (..), Usage (..))

spec :: Spec
spec = do
  describe "mockStreamCompletion" $ do

    it "yields scripted events in order" $ do
      let scripted =
            [ TextDelta "Hello"
            , TextDelta " world"
            , StreamDone (Usage 5 2 Nothing Nothing)
            ]
      events <- Conduit.runResourceT $ Conduit.runConduit $
        mockStreamCompletion scripted .| Conduit.sinkList
      events `shouldBe` scripted

    it "yields no events for an empty script" $ do
      events <- Conduit.runResourceT $ Conduit.runConduit $
        mockStreamCompletion [] .| Conduit.sinkList
      events `shouldBe` []

  describe "delayedStreamer" $
    it "yields all scripted events in order (zero delay)" $ do
      let scripted =
            [ TextDelta "a", TextDelta "b"
            , StreamDone (Usage 1 1 Nothing Nothing)
            ]
          req = LLMRequest
            { reqModel        = "gpt-4o"
            , reqMessages     = []
            , reqTools        = []
            , reqSystemPrompt = ""
            , reqMaxTokens    = Nothing
            }
      events <- Conduit.runResourceT $ Conduit.runConduit $
        delayedStreamer 0 scripted req .| Conduit.sinkList
      events `shouldBe` scripted
