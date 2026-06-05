module OpenCode.Model.CatalogSpec (spec) where

import Test.Hspec

import OpenCode.Config (ProviderConfig (..))
import OpenCode.Model.Catalog (availableModels, knownModels, modelLabel)
import OpenCode.Types (ApiKey (..), ModelId (..), ProviderId (..))

spec :: Spec
spec = do
  describe "modelLabel" $
    it "formats provider:model" $
      modelLabel (ModelId Anthropic "claude-opus-4-5")
        `shouldBe` "anthropic:claude-opus-4-5"

  describe "availableModels" $ do
    it "keeps only models whose provider has a key" $
      map provider (availableModels openaiOnly) `shouldBe` [OpenAI]

    it "is empty when no provider has a key" $
      availableModels noKeys `shouldBe` []

    it "never returns a model outside the known catalog" $
      all (`elem` knownModels) (availableModels allKeys) `shouldBe` True
  where
    openaiOnly = ProviderConfig (Just (ApiKey "k")) Nothing Nothing
    noKeys     = ProviderConfig Nothing Nothing Nothing
    allKeys    = ProviderConfig (Just (ApiKey "k")) (Just (ApiKey "k")) (Just (ApiKey "k"))
