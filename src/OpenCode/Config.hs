-- | Configuration loading from YAML file and environment variables.
--
-- Priority (highest first):
--   1. Environment variables (OPENAI_API_KEY, ANTHROPIC_API_KEY, MINIMAX_API_KEY)
--   2. ~/.config/opencode-hs/config.yaml
--   3. Built-in defaults (defaultModel only)
module OpenCode.Config
  ( -- * Public types
    Config (..)
  , ProviderConfig (..)
  , McpServerConfig (..)
  , ConfigError (..)
    -- * Loading
  , loadConfig
  , loadConfigFile
  , configFilePath
    -- * Pure assembly (exported for white-box testing)
  , buildConfig
  , EnvOverride (..)
  , defaultAnthropicModel
  , defaultMiniMaxModel
    -- * Internal YAML-shaped types (exported for white-box testing)
  , ConfigFile (..)
  , ProviderConfigFile (..)
  , ApiKeyFile (..)
  , ModelIdFile (..)
  , McpServerConfigFile (..)
  , emptyConfigFile
  ) where

import Control.Applicative ((<|>))
import Data.Aeson (FromJSON (..), (.:), (.:?), withObject)
import Data.Map (Map)
import qualified Data.Map as Map
import Data.Maybe (fromMaybe, isJust, isNothing)
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
  , mcpServers   :: [(Text, McpServerConfig)]   -- ^ name -> config, in file order
  }
  deriving stock (Show, Eq)

data ProviderConfig = ProviderConfig
  { openaiKey    :: Maybe ApiKey
  , anthropicKey :: Maybe ApiKey
  , minimaxKey   :: Maybe ApiKey
  }
  deriving stock (Show, Eq)

-- | One configured MCP server. 'mcsEnv' is merged over the inherited process
-- environment at spawn time; 'mcsEnabled' defaults to True.
data McpServerConfig = McpServerConfig
  { mcsCommand :: FilePath
  , mcsArgs    :: [Text]
  , mcsEnv     :: [(Text, Text)]
  , mcsEnabled :: Bool
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
  , cfMcpServers   :: Maybe (Map Text McpServerConfigFile)
  }
  deriving stock (Show, Eq)

emptyConfigFile :: ConfigFile
emptyConfigFile = ConfigFile Nothing Nothing Nothing

instance FromJSON ConfigFile where
  parseJSON = withObject "ConfigFile" $ \o -> ConfigFile
    <$> o .:? "providers"
    <*> o .:? "defaultModel"
    <*> o .:? "mcpServers"

data ProviderConfigFile = ProviderConfigFile
  { cfOpenai    :: Maybe ApiKeyFile
  , cfAnthropic :: Maybe ApiKeyFile
  , cfMiniMax   :: Maybe ApiKeyFile
  }
  deriving stock (Show, Eq)

instance FromJSON ProviderConfigFile where
  parseJSON = withObject "ProviderConfigFile" $ \o -> ProviderConfigFile
    <$> o .:? "openai"
    <*> o .:? "anthropic"
    <*> o .:? "minimax"

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

data McpServerConfigFile = McpServerConfigFile
  { mscfCommand :: FilePath
  , mscfArgs    :: Maybe [Text]
  , mscfEnv     :: Maybe (Map Text Text)
  , mscfEnabled :: Maybe Bool
  }
  deriving stock (Show, Eq)

instance FromJSON McpServerConfigFile where
  parseJSON = withObject "McpServerConfigFile" $ \o -> McpServerConfigFile
    <$> o .:  "command"
    <*> o .:? "args"
    <*> o .:? "env"
    <*> o .:? "enabled"

-- ---------------------------------------------------------------------------
-- Environment variable overrides
-- ---------------------------------------------------------------------------

-- | API keys read from the environment.
data EnvOverride = EnvOverride
  { eoOpenAIKey    :: Maybe ApiKey
  , eoAnthropicKey :: Maybe ApiKey
  , eoMiniMaxKey   :: Maybe ApiKey
  }
  deriving stock (Show, Eq)

loadEnvVars :: IO EnvOverride
loadEnvVars = EnvOverride
  <$> readKey "OPENAI_API_KEY"
  <*> readKey "ANTHROPIC_API_KEY"
  <*> readKey "MINIMAX_API_KEY"
  where
    readKey var = fmap (ApiKey . Text.pack) <$> lookupEnv var

-- ---------------------------------------------------------------------------
-- Config assembly (pure, testable)
-- ---------------------------------------------------------------------------

-- | The fallback model used when no model is specified and no provider key
-- selects a more specific default (see 'pickDefaultModel').
fallbackModel :: ModelId
fallbackModel = ModelId { provider = Anthropic, model = defaultAnthropicModel }

-- | The Anthropic model used as the fallback default and for connectivity probes.
defaultAnthropicModel :: Text
defaultAnthropicModel = "claude-opus-4-5"

-- | The MiniMax model used when @MINIMAX_API_KEY@ is set and no explicit
-- default model is configured.
defaultMiniMaxModel :: Text
defaultMiniMaxModel = "MiniMax-M3"

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
    minimaxKey   = eoMiniMaxKey   env
               <|> (afApiKey <$> (cfMiniMax   =<< cfProviders cf))

    providerCfg = ProviderConfig { openaiKey, anthropicKey, minimaxKey }
    defModel    = maybe (pickDefaultModel providerCfg) toModelId (cfDefaultModel cf)
    mcpList     = maybe [] (map toMcpServer . Map.toList) (cfMcpServers cf)
  in
    if isNothing openaiKey && isNothing anthropicKey && isNothing minimaxKey
      then Left $ ConfigMissingKey
        "No API key found. Set MINIMAX_API_KEY, OPENAI_API_KEY or ANTHROPIC_API_KEY, \
        \or add them to ~/.config/opencode-hs/config.yaml."
      else Right Config
        { providers    = providerCfg
        , defaultModel = defModel
        , mcpServers   = mcpList
        }

-- | When no @defaultModel@ is configured, pick one from whichever provider key
-- is present, so that exporting a single @*_API_KEY@ is enough to run. MiniMax
-- is preferred when its key is set, then OpenAI, then the Anthropic fallback.
pickDefaultModel :: ProviderConfig -> ModelId
pickDefaultModel pc
  | isJust (minimaxKey pc) = ModelId { provider = MiniMax, model = defaultMiniMaxModel }
  | isJust (openaiKey  pc) = ModelId { provider = OpenAI,  model = "gpt-4o" }
  | otherwise              = fallbackModel

toModelId :: ModelIdFile -> ModelId
toModelId mf = ModelId { provider = mfProvider mf, model = mfModel mf }

toMcpServer :: (Text, McpServerConfigFile) -> (Text, McpServerConfig)
toMcpServer (name, f) =
  ( name
  , McpServerConfig
      { mcsCommand = mscfCommand f
      , mcsArgs    = fromMaybe [] (mscfArgs f)
      , mcsEnv     = maybe [] Map.toList (mscfEnv f)
      , mcsEnabled = fromMaybe True (mscfEnabled f)
      }
  )

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
