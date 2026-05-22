-- | Configuration loading from YAML file and environment variables.
--
-- Priority (highest first):
--   1. Environment variables (OPENAI_API_KEY, ANTHROPIC_API_KEY)
--   2. ~/.config/opencode-hs/config.yaml
--   3. Built-in defaults (defaultModel only)
module OpenCode.Config
  ( -- * Public types
    Config (..)
  , ProviderConfig (..)
  , ConfigError (..)
    -- * Loading
  , loadConfig
  , loadConfigFile
  , configFilePath
    -- * Pure assembly (exported for white-box testing)
  , buildConfig
  , EnvOverride (..)
    -- * Internal YAML-shaped types (exported for white-box testing)
  , ConfigFile (..)
  , ProviderConfigFile (..)
  , ApiKeyFile (..)
  , ModelIdFile (..)
  , emptyConfigFile
  ) where

import Control.Applicative ((<|>))
import Data.Aeson (FromJSON (..), (.:), (.:?), withObject)
import Data.Maybe (isNothing)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Yaml qualified as Yaml
import System.Directory (doesFileExist, getHomeDirectory)
import System.Environment (lookupEnv)
import System.FilePath ((</>))
import OpenCode.Types (ApiKey (..), ModelId (..), ProviderId (..))

-- ---------------------------------------------------------------------------
-- Public config types
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
  = ConfigParseError Text     -- ^ malformed YAML
  | ConfigMissingKey Text     -- ^ no API key found anywhere
  deriving stock (Show, Eq)

-- ---------------------------------------------------------------------------
-- Internal YAML-shaped types
-- ---------------------------------------------------------------------------

-- | Mirrors the config.yaml structure exactly; all fields optional.
data ConfigFile = ConfigFile
  { cfProviders    :: Maybe ProviderConfigFile
  , cfDefaultModel :: Maybe ModelIdFile
  }
  deriving stock (Show, Eq)

emptyConfigFile :: ConfigFile
emptyConfigFile = ConfigFile Nothing Nothing

instance FromJSON ConfigFile where
  parseJSON = withObject "ConfigFile" $ \o -> ConfigFile
    <$> o .:? "providers"
    <*> o .:? "defaultModel"

data ProviderConfigFile = ProviderConfigFile
  { cfOpenai    :: Maybe ApiKeyFile
  , cfAnthropic :: Maybe ApiKeyFile
  }
  deriving stock (Show, Eq)

instance FromJSON ProviderConfigFile where
  parseJSON = withObject "ProviderConfigFile" $ \o -> ProviderConfigFile
    <$> o .:? "openai"
    <*> o .:? "anthropic"

newtype ApiKeyFile = ApiKeyFile {afApiKey :: ApiKey}
  deriving stock (Show, Eq)

instance FromJSON ApiKeyFile where
  parseJSON = withObject "ApiKeyFile" $ \o -> ApiKeyFile <$> o .: "apiKey"

data ModelIdFile = ModelIdFile
  { mfProvider :: ProviderId
  , mfModel    :: Text
  }
  deriving stock (Show, Eq)

instance FromJSON ModelIdFile where
  parseJSON = withObject "ModelIdFile" $ \o -> ModelIdFile
    <$> o .: "provider"
    <*> o .: "model"

-- ---------------------------------------------------------------------------
-- Environment variable overrides
-- ---------------------------------------------------------------------------

-- | API keys read from the environment.
data EnvOverride = EnvOverride
  { eoOpenAIKey    :: Maybe ApiKey
  , eoAnthropicKey :: Maybe ApiKey
  }
  deriving stock (Show, Eq)

loadEnvVars :: IO EnvOverride
loadEnvVars = EnvOverride
  <$> readKey "OPENAI_API_KEY"
  <*> readKey "ANTHROPIC_API_KEY"
  where
    readKey var = fmap (ApiKey . Text.pack) <$> lookupEnv var

-- ---------------------------------------------------------------------------
-- Config assembly (pure, testable)
-- ---------------------------------------------------------------------------

-- | The fallback model used when none is specified in the config file.
fallbackModel :: ModelId
fallbackModel = ModelId { provider = Anthropic, model = "claude-opus-4-5" }

-- | Build a 'Config' from a parsed config file and env-var overrides.
-- Returns 'Left' when no API key can be found for any provider.
buildConfig :: ConfigFile -> EnvOverride -> Either ConfigError Config
buildConfig cf env =
  let
    -- env vars take priority over yaml
    openaiKey    = eoOpenAIKey    env
               <|> (afApiKey <$> (cfOpenai    =<< cfProviders cf))
    anthropicKey = eoAnthropicKey env
               <|> (afApiKey <$> (cfAnthropic =<< cfProviders cf))

    defModel = maybe fallbackModel toModelId (cfDefaultModel cf)
  in
    if isNothing openaiKey && isNothing anthropicKey
      then Left $ ConfigMissingKey
        "No API key found. Set OPENAI_API_KEY or ANTHROPIC_API_KEY, \
        \or add them to ~/.config/opencode-hs/config.yaml."
      else Right Config
        { providers    = ProviderConfig { openaiKey, anthropicKey }
        , defaultModel = defModel
        }

toModelId :: ModelIdFile -> ModelId
toModelId mf = ModelId { provider = mfProvider mf, model = mfModel mf }

-- ---------------------------------------------------------------------------
-- IO loading
-- ---------------------------------------------------------------------------

-- | Path to the user config file.
configFilePath :: IO FilePath
configFilePath = do
  home <- getHomeDirectory
  pure (home </> ".config" </> "opencode-hs" </> "config.yaml")

-- | Load config from @~/.config/opencode-hs/config.yaml@ and env vars.
-- Missing config file is not an error; a missing API key is.
loadConfig :: IO (Either ConfigError Config)
loadConfig = do
  path    <- configFilePath
  cfResult <- loadConfigFile path
  env      <- loadEnvVars
  pure (cfResult >>= \cf -> buildConfig cf env)

-- | Parse a config file. Returns 'Right emptyConfigFile' if the file
-- doesn't exist (fresh install is fine as long as env vars are set).
loadConfigFile :: FilePath -> IO (Either ConfigError ConfigFile)
loadConfigFile path = do
  exists <- doesFileExist path
  if not exists
    then pure (Right emptyConfigFile)
    else do
      result <- Yaml.decodeFileEither path
      pure $ case result of
        Left err -> Left (ConfigParseError (Text.pack (Yaml.prettyPrintParseException err)))
        Right cf -> Right cf
