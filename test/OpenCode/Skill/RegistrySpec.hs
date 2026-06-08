{-# LANGUAGE OverloadedStrings #-}
module OpenCode.Skill.RegistrySpec (spec) where

import Data.Text (Text)
import Test.Hspec

import OpenCode.Skill.Registry
import OpenCode.Skill.Types (Skill (..), SkillSource (..))

mkLocal :: Text -> Text -> Skill
mkLocal n d = Skill n d [] (LocalSkill "body")

mkMcp :: Text -> Skill
mkMcp n = Skill n "" [] (McpPromptSkill "srv" n)

spec :: Spec
spec = do
  describe "buildSkillRegistry" $ do
    it "keeps the first skill on a name clash (project over user over mcp)" $ do
      let proj = mkLocal "greet" "project"
          user = mkLocal "greet" "user"
          mcp  = mkMcp "greet"
      map skDescription (buildSkillRegistry [] [proj, user, mcp]) `shouldBe` ["project"]

    it "drops skills whose name is reserved" $
      map skName (buildSkillRegistry ["help"] [mkLocal "help" "x", mkLocal "greet" "y"])
        `shouldBe` ["greet"]

    it "preserves order and de-duplicates" $
      map skName (buildSkillRegistry [] [mkLocal "a" "", mkLocal "b" "", mkLocal "a" ""])
        `shouldBe` ["a", "b"]

  describe "lookupSkill" $ do
    it "finds a skill by name" $
      fmap skName (lookupSkill "b" [mkLocal "a" "", mkLocal "b" ""]) `shouldBe` Just "b"
    it "is Nothing when absent" $
      lookupSkill "z" [mkLocal "a" ""] `shouldBe` Nothing

  describe "matchSkill" $ do
    it "resolves an invocation to a skill and its trailing text" $ do
      let ss = [mkLocal "greet" ""]
      fmap (skName . fst) (matchSkill ss "/greet hi there") `shouldBe` Just "greet"
      fmap snd            (matchSkill ss "/greet hi there") `shouldBe` Just "hi there"
    it "is Nothing for an unknown name" $
      matchSkill [mkLocal "greet" ""] "/nope" `shouldBe` Nothing
    it "is Nothing for non-slash input" $
      matchSkill [mkLocal "greet" ""] "hello" `shouldBe` Nothing

  describe "skillSuggestEntries" $
    it "slash-prefixes names and pairs them with descriptions" $
      skillSuggestEntries [mkLocal "greet" "say hi"] `shouldBe` [("/greet", "say hi")]
