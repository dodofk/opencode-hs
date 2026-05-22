-- | Configuration loading from YAML file and environment variables.
module OpenCode.Config
  ( Config (..)
  , ProviderConfig (..)
  , loadConfig
  , ConfigError (..)
  ) where

import Data.Text (Text)
import OpenCode.Types (ApiKey, ModelId)

-- ---------------------------------------------------------------------------
-- Types
-- ---------------------------------------------------------------------------

data Config = Config
  { providers    :: ProviderConfig
  , defaultModel :: ModelId
  }
  deriving stock (Show, Eq)

data ProviderConfig = ProviderConfig
  { openaiKey    :: Maybe ApiKey
  , anthropicKey :: Maybe ApiKey
  }
  deriving stock (Show, Eq)

data ConfigError
  = ConfigFileNotFound FilePath
  | ConfigParseError Text
  | ConfigMissingKey Text
  deriving stock (Show, Eq)

-- ---------------------------------------------------------------------------
-- Loading (stub — implemented in M1)
-- ---------------------------------------------------------------------------

loadConfig :: IO (Either ConfigError Config)
loadConfig = pure (Left (ConfigMissingKey "not yet implemented"))
