module OpenCode.SkillToolSpec (spec) where

import qualified Data.Aeson as Aeson
import Data.Aeson (object, (.=))
import Data.Text (Text)
import qualified Data.Text as T
import Test.Hspec

import OpenCode.App (runAppM)
import OpenCode.McpMock (withMock)
import OpenCode.SkillTool
import OpenCode.Skill.Types (Skill (..), SkillSource (..))
import OpenCode.TestEnv (newDummyEnv)
import OpenCode.Tool.Types (SomeTool (..), emptyRegistry, executeTool, registerTool)

localSkill :: Skill
localSkill = Skill "explain" "explain a file" []
  (LocalSkill "Explain this, step by step: $ARGUMENTS")

mcpSkill :: Skill
mcpSkill = Skill "srv_greet" "greet someone" ["who"]
  (McpPromptSkill "srv" "greet")

call :: Text -> Text -> Aeson.Value
call name args = object ["name" .= name, "arguments" .= args]

spec :: Spec
spec = do
  describe "renderSkill (no MCP needed)" $ do
    it "renders a local skill body with $ARGUMENTS substituted" $
      renderSkill [] localSkill "src/Foo.hs"
        `shouldReturn` Right "Explain this, step by step: src/Foo.hs"

    it "reports a missing required arg before contacting any server" $
      renderSkill [] mcpSkill "lang=en"
        `shouldReturn` Left "missing required arg: who"

    it "reports an unavailable server when args are satisfied" $
      renderSkill [] mcpSkill "who=ada"
        `shouldReturn` Left "prompt server unavailable"

  describe "runSkillCall" $ do
    it "renders the named local skill" $
      runSkillCall [] [localSkill] (call "explain" "src/Foo.hs")
        `shouldReturn` "Explain this, step by step: src/Foo.hs"

    it "returns guidance listing valid names for an unknown skill" $ do
      r <- runSkillCall [] [localSkill] (call "nope" "")
      r `shouldSatisfy` T.isInfixOf "unknown skill 'nope'"
      r `shouldSatisfy` T.isInfixOf "explain"

    it "returns guidance for a skill-level failure (missing arg)" $ do
      r <- runSkillCall [] [mcpSkill] (call "srv_greet" "")
      r `shouldSatisfy` T.isInfixOf "missing required arg: who"

    it "returns guidance for a malformed call object" $ do
      r <- runSkillCall [] [localSkill] (object ["bogus" .= True])
      r `shouldSatisfy` T.isInfixOf "invalid skill call"

    it "flags a skill that renders to blank" $ do
      let blank = Skill "empty" "" [] (LocalSkill "$ARGUMENTS")
      r <- runSkillCall [] [blank] (call "empty" "")
      r `shouldSatisfy` T.isInfixOf "produced no content"

    it "treats an omitted arguments key as empty text" $
      runSkillCall [] [localSkill] (object ["name" .= ("explain" :: Text)])
        `shouldReturn` "Explain this, step by step: "

  describe "skillTool" $ do
    it "skillToolName is the literal 'skill'" $
      skillToolName `shouldBe` "skill"

    it "is absent when no skills exist" $
      fmap toolName (skillTool [] []) `shouldBe` Nothing

    it "is named 'skill' and carries the enumerated description" $
      case skillTool [] [localSkill] of
        Nothing -> expectationFailure "expected the tool to exist"
        Just t  -> do
          toolName t `shouldBe` skillToolName
          toolDesc t `shouldSatisfy` T.isInfixOf "explain a file"

  describe "renderSkill / runSkillCall against the mock MCP server" $ do
    let greetSkill = Skill "mock_greet" "greet someone" [] (McpPromptSkill "mock" "greet")

    it "renders an MCP-prompt skill from the live server" $ withMock $ \c ->
      renderSkill [c] greetSkill "" `shouldReturn` Right "hello there"

    it "runs an MCP-prompt skill through the tool call path" $ withMock $ \c ->
      runSkillCall [c] [greetSkill] (call "mock_greet" "")
        `shouldReturn` "hello there"

    it "tool path and direct render path agree (parity)" $ withMock $ \c -> do
      direct  <- renderSkill [c] greetSkill ""
      viaTool <- runSkillCall [c] [greetSkill] (call "mock_greet" "")
      direct `shouldBe` Right viaTool

  describe "skill tool via executeTool (registry round-trip)" $ do
    it "dispatches a skill call end to end in AppM" $ do
      env <- newDummyEnv
      case skillTool [] [localSkill] of
        Nothing -> expectationFailure "expected the skill tool to exist"
        Just t  -> do
          let reg = registerTool t emptyRegistry
          r <- runAppM env (executeTool reg "skill" (call "explain" "src/Foo.hs"))
          r `shouldBe` Right "Explain this, step by step: src/Foo.hs"
