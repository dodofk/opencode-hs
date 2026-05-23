module OpenCode.LLM.MockSpec (spec) where

import qualified Conduit
import Conduit ((.|))
import Test.Hspec

import OpenCode.LLM.Mock
import OpenCode.Types (StreamEvent (..), Usage (..))

spec :: Spec
spec = describe "mockStreamCompletion" $ do

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
