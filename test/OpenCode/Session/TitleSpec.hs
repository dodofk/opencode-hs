module OpenCode.Session.TitleSpec (spec) where

import qualified Data.Text as T
import Test.Hspec

import OpenCode.Session.Title (sanitizeTitle, titlePrompt)

spec :: Spec
spec = do
  describe "sanitizeTitle" $ do
    it "takes the first line and strips surrounding quotes" $
      sanitizeTitle "\"Add login flow\"\nextra" `shouldBe` "Add login flow"
    it "collapses internal whitespace" $
      sanitizeTitle "fix   the\tparser" `shouldBe` "fix the parser"
    it "caps to at most 6 words" $
      sanitizeTitle "one two three four five six seven eight"
        `shouldBe` "one two three four five six"
    it "caps to at most 60 characters" $
      T.length (sanitizeTitle (T.replicate 100 "a")) `shouldSatisfy` (<= 60)
    it "returns 'untitled' for empty input" $
      sanitizeTitle "   " `shouldBe` "untitled"

  describe "titlePrompt" $
    it "embeds the user message" $
      titlePrompt "build a parser" `shouldSatisfy` T.isInfixOf "build a parser"
