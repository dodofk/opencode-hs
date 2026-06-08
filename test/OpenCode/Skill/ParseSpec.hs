module OpenCode.Skill.ParseSpec (spec) where

import Data.Either (isLeft)
import Test.Hspec

import OpenCode.Skill.Parse
import OpenCode.Skill.Types (Skill (..), SkillSource (..))

spec :: Spec
spec = do
  describe "splitFrontmatter" $ do
    it "splits frontmatter from body" $
      splitFrontmatter "---\nname: greet\n---\nhello\n"
        `shouldBe` (Just "name: greet\n", "hello\n")

    it "returns Nothing when there is no opening fence" $
      splitFrontmatter "just a body\n" `shouldBe` (Nothing, "just a body\n")

    it "treats an unterminated fence as all body" $
      splitFrontmatter "---\nname: x\nno close"
        `shouldBe` (Nothing, "---\nname: x\nno close")

  describe "parseSkillFile" $ do
    it "reads name, description, and body from frontmatter" $ do
      let r = parseSkillFile "dir"
                "---\nname: greet\ndescription: say hi\n---\nBody $ARGUMENTS\n"
      fmap skName r        `shouldBe` Right "greet"
      fmap skDescription r `shouldBe` Right "say hi"
      fmap skSource r      `shouldBe` Right (LocalSkill "Body $ARGUMENTS")

    it "defaults the name to the directory name when omitted" $
      fmap skName (parseSkillFile "mydir" "---\ndescription: d\n---\nbody\n")
        `shouldBe` Right "mydir"

    it "defaults the name when the frontmatter name is blank" $
      fmap skName (parseSkillFile "mydir" "---\nname: \"  \"\n---\nbody\n")
        `shouldBe` Right "mydir"

    it "uses the whole file as the body when there is no frontmatter" $
      fmap skSource (parseSkillFile "d" "plain body\n")
        `shouldBe` Right (LocalSkill "plain body")

    it "gives an empty description when omitted" $
      fmap skDescription (parseSkillFile "d" "body") `shouldBe` Right ""

    it "sets no required args for a local skill" $
      fmap skRequiredArgs (parseSkillFile "d" "body") `shouldBe` Right []

    it "reports a Left for malformed frontmatter" $
      parseSkillFile "d" "---\nnot an object\n---\nbody\n" `shouldSatisfy` isLeft

  describe "substituteArgs" $ do
    it "replaces every $ARGUMENTS token" $
      substituteArgs "a $ARGUMENTS b $ARGUMENTS" "X" `shouldBe` "a X b X"

    it "appends args after a blank line when there is no token" $
      substituteArgs "body" "tail" `shouldBe` "body\n\ntail"

    it "leaves the body unchanged when there are no args and no token" $
      substituteArgs "body" "  " `shouldBe` "body"

    it "substitutes blank args into the token when the token is present" $
      substituteArgs "say $ARGUMENTS please" "" `shouldBe` "say  please"

  describe "splitInvocation" $ do
    it "splits the name from the trailing free text" $
      splitInvocation "/greet make it formal" `shouldBe` Just ("greet", "make it formal")

    it "parses a bare name with empty rest" $
      splitInvocation "/greet" `shouldBe` Just ("greet", "")

    it "trims surrounding whitespace" $
      splitInvocation "   /greet   hi there  " `shouldBe` Just ("greet", "hi there")

    it "returns Nothing for non-slash input" $
      splitInvocation "hello" `shouldBe` Nothing

    it "returns Nothing for a bare slash" $
      splitInvocation "/" `shouldBe` Nothing

  describe "parseArgs" $ do
    it "parses key=value pairs" $
      parseArgs "name=ann lang=en" `shouldBe` [("name", "ann"), ("lang", "en")]

    it "ignores tokens without '='" $
      parseArgs "hello name=ann" `shouldBe` [("name", "ann")]

    it "splits on the first '=' only" $
      parseArgs "k=v=w" `shouldBe` [("k", "v=w")]

    it "passes an empty value through" $
      parseArgs "foo=" `shouldBe` [("foo", "")]

  describe "missingArgs" $ do
    it "reports required names that are absent" $
      missingArgs ["name", "lang"] [("name", "a")] `shouldBe` ["lang"]

    it "is empty when all present" $
      missingArgs ["name"] [("name", "a")] `shouldBe` []
