module OpenCode.Session.PromptSpec (spec) where

import qualified Data.Map.Strict as Map
import qualified Data.Text as Text
import Test.Hspec

import OpenCode.Session.Prompt (systemPrompt)
import OpenCode.Tool.Registry (defaultBuiltinRegistry)
import OpenCode.Tool.Types (ToolRegistry (..), unRegistry)

spec :: Spec
spec = describe "systemPrompt" $ do

  it "includes a non-empty header section" $ do
    let p = systemPrompt defaultBuiltinRegistry
    Text.length p `shouldSatisfy` (> 0)

  it "mentions every tool name from the registry" $ do
    let p     = systemPrompt defaultBuiltinRegistry
        names = Map.keys (unRegistry defaultBuiltinRegistry)
    mapM_ (\name -> Text.unpack p `shouldContain` Text.unpack name) names

  it "produces an empty-registry prompt that still has the header" $ do
    let p = systemPrompt (ToolRegistry Map.empty)
    Text.length p `shouldSatisfy` (> 0)
    Text.unpack p `shouldContain` "AI coding"   -- a recognizable header phrase
