module OpenCode.MCP.StartupSpec (spec) where

import Data.Maybe (isJust)
import Test.Hspec

import OpenCode.MCP.Startup (mcpRegistryAdditions)
import OpenCode.Tool.Types (emptyRegistry, lookupTool)

spec :: Spec
spec = describe "mcpRegistryAdditions" $
  it "is identity for no clients" $
    -- with no clients, the registry is unchanged: a name absent before is
    -- absent after.
    lookupName (mcpRegistryAdditions [] emptyRegistry) "anything" `shouldBe` False
  where
    lookupName reg n = isJust (lookupTool n reg)
