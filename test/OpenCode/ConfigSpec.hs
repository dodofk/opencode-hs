module OpenCode.ConfigSpec (spec) where

import Data.Maybe (isNothing)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import qualified Data.Yaml as Yaml
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

import OpenCode.Config
import OpenCode.Types

-- ---------------------------------------------------------------------------
-- Spec
-- ---------------------------------------------------------------------------

spec :: Spec
spec = do
  describe "buildConfig" $ do

    it "succeeds with an OpenAI key in YAML" $
      buildConfig (cfWithOpenAI "sk-test") noEnv
        `shouldSatisfy` isRight

    it "succeeds with an Anthropic key in YAML" $
      buildConfig (cfWithAnthropic "sk-ant-test") noEnv
        `shouldSatisfy` isRight

    it "fails with no keys anywhere" $
      buildConfig emptyConfigFile noEnv
        `shouldSatisfy` isLeft

    it "env var satisfies missing YAML key" $
      buildConfig emptyConfigFile (anthropicEnv "sk-ant-env")
        `shouldSatisfy` isRight

    it "env var takes priority over YAML key" $ do
      let cfg = cfWithAnthropic "sk-ant-yaml"
          env = anthropicEnv "sk-ant-env"
      case buildConfig cfg env of
        Left  err -> expectationFailure (show err)
        Right c   ->
          anthropicKey (providers c) `shouldBe` Just (ApiKey "sk-ant-env")

    it "both providers can be set simultaneously" $ do
      let cfg = cfWithBoth "sk-openai" "sk-ant"
      case buildConfig cfg noEnv of
        Left  err -> expectationFailure (show err)
        Right c   -> do
          openaiKey    (providers c) `shouldBe` Just (ApiKey "sk-openai")
          anthropicKey (providers c) `shouldBe` Just (ApiKey "sk-ant")

    it "openai-only config leaves anthropicKey as Nothing" $ do
      case buildConfig (cfWithOpenAI "sk-openai") noEnv of
        Left  err -> expectationFailure (show err)
        Right c   -> anthropicKey (providers c) `shouldSatisfy` isNothing

    it "uses Anthropic fallback model when none specified" $ do
      case buildConfig (cfWithAnthropic "sk-ant") noEnv of
        Left  err -> expectationFailure (show err)
        Right c   -> provider (defaultModel c) `shouldBe` Anthropic

    it "uses model specified in config" $ do
      let cfg = cfWithOpenAIAndModel "sk-openai" OpenAI "gpt-4o"
      case buildConfig cfg noEnv of
        Left  err -> expectationFailure (show err)
        Right c   -> do
          model    (defaultModel c) `shouldBe` "gpt-4o"
          provider (defaultModel c) `shouldBe` OpenAI

    it "MINIMAX_API_KEY env var satisfies a missing YAML key" $
      buildConfig emptyConfigFile (minimaxEnv "mk-env")
        `shouldSatisfy` isRight

    it "reads the MiniMax key from YAML" $
      case buildConfig (cfWithMiniMax "mk-yaml") noEnv of
        Left  err -> expectationFailure (show err)
        Right c   -> minimaxKey (providers c) `shouldBe` Just (ApiKey "mk-yaml")

    it "MINIMAX_API_KEY env var takes priority over YAML key" $
      case buildConfig (cfWithMiniMax "mk-yaml") (minimaxEnv "mk-env") of
        Left  err -> expectationFailure (show err)
        Right c   -> minimaxKey (providers c) `shouldBe` Just (ApiKey "mk-env")

    it "defaults to the MiniMax-M3 model when only a MiniMax key is present" $
      case buildConfig emptyConfigFile (minimaxEnv "mk-env") of
        Left  err -> expectationFailure (show err)
        Right c   -> do
          provider (defaultModel c) `shouldBe` MiniMax
          model    (defaultModel c) `shouldBe` "MiniMax-M3"

    it "prefers MiniMax over OpenAI for the default model when both keys are set" $
      case buildConfig emptyConfigFile (noEnv { eoOpenAIKey = Just (ApiKey "sk"), eoMiniMaxKey = Just (ApiKey "mk") }) of
        Left  err -> expectationFailure (show err)
        Right c   -> provider (defaultModel c) `shouldBe` MiniMax

    it "honours an explicit OpenAI defaultModel even when a MiniMax key is set" $
      case buildConfig (cfWithOpenAIAndModel "sk" OpenAI "gpt-4o") (minimaxEnv "mk") of
        Left  err -> expectationFailure (show err)
        Right c   -> provider (defaultModel c) `shouldBe` OpenAI

  describe "mcpServers parsing" $ do
    it "parses a full server entry from YAML" $ do
      let yaml = Text.unlines
            [ "providers:"
            , "  openai:"
            , "    apiKey: sk-x"
            , "mcpServers:"
            , "  filesystem:"
            , "    command: npx"
            , "    args: [\"-y\", \"server-filesystem\", \"/tmp\"]"
            , "    env:"
            , "      FOO: bar"
            , "    enabled: true"
            ]
      cf <- either (fail . show) pure (Yaml.decodeEither' (Text.encodeUtf8 yaml))
      case buildConfig cf noEnv of
        Left  err -> expectationFailure (show err)
        Right cfg ->
          mcpServers cfg `shouldBe`
            [ ("filesystem", McpServerConfig
                { mcsCommand = "npx"
                , mcsArgs    = ["-y", "server-filesystem", "/tmp"]
                , mcsEnv     = [("FOO", "bar")]
                , mcsEnabled = True
                }) ]

    it "defaults env to empty and enabled to True" $ do
      let yaml = Text.unlines
            [ "providers: { openai: { apiKey: sk-x } }"
            , "mcpServers:"
            , "  srv:"
            , "    command: foo"
            ]
      cf <- either (fail . show) pure (Yaml.decodeEither' (Text.encodeUtf8 yaml))
      case buildConfig cf noEnv of
        Left  err -> expectationFailure (show err)
        Right cfg ->
          mcpServers cfg `shouldBe`
            [ ("srv", McpServerConfig { mcsCommand = "foo", mcsArgs = [], mcsEnv = [], mcsEnabled = True }) ]

    it "is empty when the section is absent" $
      case buildConfig emptyConfigFile (openaiEnv "sk-x") of
        Left  err -> expectationFailure (show err)
        Right cfg -> mcpServers cfg `shouldBe` []

    it "preserves enabled:false" $ do
      let yaml = Text.unlines
            [ "providers: { openai: { apiKey: sk-x } }"
            , "mcpServers: { srv: { command: foo, enabled: false } }"
            ]
      cf <- either (fail . show) pure (Yaml.decodeEither' (Text.encodeUtf8 yaml))
      case buildConfig cf noEnv of
        Left  err -> expectationFailure (show err)
        Right cfg -> map (mcsEnabled . snd) (mcpServers cfg) `shouldBe` [False]

  describe "tools config (brave/github keys)" $ do

    it "reads braveApiKey from YAML" $ do
      let yaml = Text.unlines
            [ "providers: { openai: { apiKey: sk-x } }"
            , "tools:"
            , "  braveApiKey: { apiKey: BSA-yaml }"
            ]
      cf <- either (fail . show) pure (Yaml.decodeEither' (Text.encodeUtf8 yaml))
      case buildConfig cf noEnv of
        Left  err -> expectationFailure (show err)
        Right cfg -> braveKey (tools cfg) `shouldBe` Just (ApiKey "BSA-yaml")

    it "reads githubToken from YAML" $ do
      let yaml = Text.unlines
            [ "providers: { openai: { apiKey: sk-x } }"
            , "tools:"
            , "  githubToken: { apiKey: ghp-yaml }"
            ]
      cf <- either (fail . show) pure (Yaml.decodeEither' (Text.encodeUtf8 yaml))
      case buildConfig cf noEnv of
        Left  err -> expectationFailure (show err)
        Right cfg -> githubKey (tools cfg) `shouldBe` Just (ApiKey "ghp-yaml")

    it "BRAVE_API_KEY env var overrides YAML" $ do
      let cfg = emptyConfigFile
            { cfProviders = Just ProviderConfigFile
                { cfOpenai = Just (ApiKeyFile (ApiKey "sk-x")), cfAnthropic = Nothing, cfMiniMax = Nothing }
            , cfTools = Just ToolsConfigFile
                { tcfBrave = Just (ApiKeyFile (ApiKey "BSA-yaml"))
                , tcfGithub = Nothing
                }
            }
          env = noEnv { eoBraveKey = Just (ApiKey "BSA-env") }
      case buildConfig cfg env of
        Left  err -> expectationFailure (show err)
        Right c   -> braveKey (tools c) `shouldBe` Just (ApiKey "BSA-env")

    it "GITHUB_TOKEN env var overrides YAML" $ do
      let cfg = emptyConfigFile
            { cfProviders = Just ProviderConfigFile
                { cfOpenai = Just (ApiKeyFile (ApiKey "sk-x")), cfAnthropic = Nothing, cfMiniMax = Nothing }
            , cfTools = Just ToolsConfigFile
                { tcfBrave = Nothing
                , tcfGithub = Just (ApiKeyFile (ApiKey "ghp-yaml"))
                }
            }
          env = noEnv { eoGithubKey = Just (ApiKey "ghp-env") }
      case buildConfig cfg env of
        Left  err -> expectationFailure (show err)
        Right c   -> githubKey (tools c) `shouldBe` Just (ApiKey "ghp-env")

    it "both tool keys default to Nothing when absent" $
      case buildConfig (cfWithOpenAI "sk-x") noEnv of
        Left  err -> expectationFailure (show err)
        Right c   -> do
          braveKey  (tools c) `shouldBe` Nothing
          githubKey (tools c) `shouldBe` Nothing

    it "still boots (Right) with only an LLM key, no tool keys" $
      buildConfig (cfWithOpenAI "sk-x") noEnv `shouldSatisfy` isRight

  describe "loadConfigFile" $ do

    it "returns Right for a missing file (fresh install)" $
      withSystemTempDirectory "opencode-hs-test" $ \tmpDir -> do
        result <- loadConfigFile (tmpDir </> "does-not-exist.yaml")
        result `shouldSatisfy` isRight

    it "parses a minimal valid YAML file" $
      withSystemTempDirectory "opencode-hs-test" $ \tmpDir -> do
        let path = tmpDir </> "config.yaml"
        writeFile path
          "providers:\n\
          \  anthropic:\n\
          \    apiKey: sk-ant-file\n"
        result <- loadConfigFile path
        result `shouldSatisfy` isRight

    it "returns ConfigParseError for malformed YAML" $
      withSystemTempDirectory "opencode-hs-test" $ \tmpDir -> do
        let path = tmpDir </> "bad.yaml"
        writeFile path "{ not: valid: yaml: ]["
        result <- loadConfigFile path
        result `shouldSatisfy` isLeft

    it "round-trips provider key through YAML" $
      withSystemTempDirectory "opencode-hs-test" $ \tmpDir -> do
        let path = tmpDir </> "config.yaml"
        writeFile path
          "providers:\n\
          \  openai:\n\
          \    apiKey: sk-from-file\n"
        cfResult <- loadConfigFile path
        case cfResult >>= \cf -> buildConfig cf noEnv of
          Left  err -> expectationFailure (show err)
          Right c   ->
            openaiKey (providers c) `shouldBe` Just (ApiKey "sk-from-file")

    it "parses defaultModel from YAML" $
      withSystemTempDirectory "opencode-hs-test" $ \tmpDir -> do
        let path = tmpDir </> "config.yaml"
        writeFile path
          "providers:\n\
          \  openai:\n\
          \    apiKey: sk-openai\n\
          \defaultModel:\n\
          \  provider: openai\n\
          \  model: gpt-4o\n"
        cfResult <- loadConfigFile path
        case cfResult >>= \cf -> buildConfig cf noEnv of
          Left  err -> expectationFailure (show err)
          Right c   -> do
            model    (defaultModel c) `shouldBe` "gpt-4o"
            provider (defaultModel c) `shouldBe` OpenAI

-- ---------------------------------------------------------------------------
-- Test fixtures
-- ---------------------------------------------------------------------------

noEnv :: EnvOverride
noEnv = EnvOverride Nothing Nothing Nothing Nothing Nothing

openaiEnv :: Text -> EnvOverride
openaiEnv k = noEnv { eoOpenAIKey = Just (ApiKey k) }

anthropicEnv :: Text -> EnvOverride
anthropicEnv k = noEnv { eoAnthropicKey = Just (ApiKey k) }

minimaxEnv :: Text -> EnvOverride
minimaxEnv k = noEnv { eoMiniMaxKey = Just (ApiKey k) }

cfWithOpenAI :: Text -> ConfigFile
cfWithOpenAI k = emptyConfigFile
  { cfProviders = Just ProviderConfigFile
      { cfOpenai    = Just (ApiKeyFile (ApiKey k))
      , cfAnthropic = Nothing
      , cfMiniMax   = Nothing
      }
  }

cfWithAnthropic :: Text -> ConfigFile
cfWithAnthropic k = emptyConfigFile
  { cfProviders = Just ProviderConfigFile
      { cfOpenai    = Nothing
      , cfAnthropic = Just (ApiKeyFile (ApiKey k))
      , cfMiniMax   = Nothing
      }
  }

cfWithMiniMax :: Text -> ConfigFile
cfWithMiniMax k = emptyConfigFile
  { cfProviders = Just ProviderConfigFile
      { cfOpenai    = Nothing
      , cfAnthropic = Nothing
      , cfMiniMax   = Just (ApiKeyFile (ApiKey k))
      }
  }

cfWithBoth :: Text -> Text -> ConfigFile
cfWithBoth oa ant = emptyConfigFile
  { cfProviders = Just ProviderConfigFile
      { cfOpenai    = Just (ApiKeyFile (ApiKey oa))
      , cfAnthropic = Just (ApiKeyFile (ApiKey ant))
      , cfMiniMax   = Nothing
      }
  }

cfWithOpenAIAndModel :: Text -> ProviderId -> Text -> ConfigFile
cfWithOpenAIAndModel k prov mdl = (cfWithOpenAI k)
  { cfDefaultModel = Just ModelIdFile { mfProvider = prov, mfModel = mdl }
  }

-- ---------------------------------------------------------------------------
-- Predicates (avoid importing Data.Either which may vary)
-- ---------------------------------------------------------------------------

isRight :: Either a b -> Bool
isRight (Right _) = True
isRight _         = False

isLeft :: Either a b -> Bool
isLeft = not . isRight
