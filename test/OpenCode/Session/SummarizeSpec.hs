module OpenCode.Session.SummarizeSpec (spec) where

import Control.Monad.Except (runExceptT)
import Control.Monad.Reader (runReaderT)
import qualified Data.List.NonEmpty as NE
import qualified Data.Text as T
import Data.Time (UTCTime (..), fromGregorian)
import Test.Hspec

import OpenCode.LLM.Mock (staticStreamer)
import OpenCode.Session.Summarize (contextLimit, estimateTokens, maybeSummarize, needsSummary)
import OpenCode.TestEnv (withTestEnv)
import OpenCode.Types
  ( Message (..), MessageId (..), MessagePart (TextPart), ModelId (..)
  , ProviderId (..), Role (..), StreamEvent (..), Usage (..) )

spec :: Spec
spec = do
  describe "estimateTokens" $
    it "approximates chars/4 over message text" $
      estimateTokens [msg 40] `shouldBe` 10

  describe "contextLimit" $ do
    it "OpenAI is 128000"    $ contextLimit (ModelId OpenAI "gpt-4o")      `shouldBe` 128000
    it "Anthropic is 200000" $ contextLimit (ModelId Anthropic "claude")   `shouldBe` 200000
    it "MiniMax is 1000000"  $ contextLimit (ModelId MiniMax "MiniMax-M3") `shouldBe` 1000000

  describe "needsSummary" $ do
    it "true when estimate meets the threshold" $
      needsSummary 5 [msg 40] `shouldBe` True
    it "false when under the threshold" $
      needsSummary 1000 [msg 40] `shouldBe` False

  describe "maybeSummarize" $ do
    it "replaces the older prefix with a summary and keeps the recent suffix" $
      withTestEnv $ \env _ -> do
        let msgs = [ msgN i | i <- [1 .. 10 :: Int] ]
            streamer = staticStreamer [ TextDelta "compact summary", StreamDone (Usage 0 0 Nothing Nothing) ]
        result <- runExceptT $ runReaderT
          (maybeSummarize streamer (ModelId OpenAI "gpt-4o") 1 6 msgs) env
        case result of
          Right out -> do
            length out `shouldBe` 7
            NE.toList (msgParts (head out)) `shouldBe`
              [TextPart "[Summary of earlier conversation]: compact summary"]
            msgRole (head out) `shouldBe` RoleUser
            map msgId (drop 1 out) `shouldBe` [ MessageId (T.pack (show i)) | i <- [5 .. 10 :: Int] ]
          Left e -> expectationFailure (show e)

    it "returns messages unchanged when under threshold" $
      withTestEnv $ \env _ -> do
        let msgs = [ msgN i | i <- [1 .. 10 :: Int] ]
            streamer = staticStreamer [ StreamError "must not be called" ]
        result <- runExceptT $ runReaderT
          (maybeSummarize streamer (ModelId OpenAI "gpt-4o") 1000000 6 msgs) env
        fmap length result `shouldBe` Right 10

t0 :: UTCTime
t0 = UTCTime (fromGregorian 2026 6 1) 0

msg :: Int -> Message
msg n = Message (MessageId "m") RoleUser (NE.fromList [TextPart (T.replicate n "a")]) t0

msgN :: Int -> Message
msgN i = Message (MessageId (T.pack (show i))) RoleUser (NE.fromList [TextPart (T.pack ("body " <> show i))]) t0
