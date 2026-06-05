-- | Static catalog of selectable models, plus shared provider/model labels.
--
-- The run path keys off each session's 'ModelId'; this module enumerates the
-- models a user may switch to (filtered to providers that actually have a key)
-- and centralizes the @provider:model@ label so the status bar and the model
-- picker format identically.
module OpenCode.Model.Catalog
  ( knownModels
  , availableModels
  , modelLabel
  , providerLabel
  ) where

import Data.Maybe (isJust)
import Data.Text (Text)

import OpenCode.Config (ProviderConfig (..))
import OpenCode.Types (ModelId (..), ProviderId (..))

-- | Curated set of models offered in the @/model@ picker. Extend by adding rows.
knownModels :: [ModelId]
knownModels =
  [ ModelId OpenAI    "gpt-4o"
  , ModelId Anthropic "claude-opus-4-5"
  , ModelId MiniMax   "MiniMax-M3"
  ]

-- | The subset of 'knownModels' whose provider has a key configured — you can't
-- run a model whose provider you have no credentials for.
availableModels :: ProviderConfig -> [ModelId]
availableModels pc = filter (hasKey . provider) knownModels
  where
    hasKey OpenAI    = isJust (openaiKey pc)
    hasKey Anthropic = isJust (anthropicKey pc)
    hasKey MiniMax   = isJust (minimaxKey pc)

-- | A human-readable @provider:model@ label (e.g. @openai:gpt-4o@).
modelLabel :: ModelId -> Text
modelLabel (ModelId p m) = providerLabel p <> ":" <> m

providerLabel :: ProviderId -> Text
providerLabel = \case
  OpenAI    -> "openai"
  Anthropic -> "anthropic"
  MiniMax   -> "minimax"
