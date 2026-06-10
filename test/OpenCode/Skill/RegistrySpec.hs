{-# LANGUAGE OverloadedStrings #-}
module OpenCode.Skill.RegistrySpec (spec) where

import qualified Data.Aeson as Aeson
import qualified Data.Aeson.KeyMap as KM
import qualified Data.Text as T
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

  describe "skillToolDescription" $ do
    it "enumerates one line per skill with name and description" $ do
      let ss = [ Skill "explain" "explain a file" [] (LocalSkill "body")
               , Skill "srv_greet" "greet someone" ["who"] (McpPromptSkill "srv" "greet") ]
          d  = skillToolDescription ss
      d `shouldSatisfy` T.isInfixOf "  - explain: explain a file"
      d `shouldSatisfy` T.isInfixOf "  - srv_greet: greet someone (needs: who)"

    it "starts with the invocation instruction" $
      skillToolDescription [Skill "a" "b" [] (LocalSkill "x")]
        `shouldSatisfy` T.isPrefixOf "Invoke a named skill"

  describe "skillToolSchema" $ do
    it "is an object schema requiring name, with the skill names as the enum" $ do
      let v = skillToolSchema [ Skill "a" "" [] (LocalSkill "x")
                              , Skill "b" "" [] (LocalSkill "y") ]
      case v of
        Aeson.Object o -> do
          KM.lookup "required" o `shouldBe` Just (Aeson.toJSON (["name"] :: [T.Text]))
          case KM.lookup "properties" o of
            Just (Aeson.Object props) -> case KM.lookup "name" props of
              Just (Aeson.Object nameP) ->
                KM.lookup "enum" nameP `shouldBe` Just (Aeson.toJSON (["a", "b"] :: [T.Text]))
              _ -> expectationFailure "properties.name missing"
            _ -> expectationFailure "properties missing"
        _ -> expectationFailure "schema is not an object"

    it "round-trips through aeson" $ do
      let v = skillToolSchema [Skill "a" "" [] (LocalSkill "x")]
      Aeson.decode (Aeson.encode v) `shouldBe` Just v
