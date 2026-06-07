# M14 — MCP Client Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Connect to external MCP servers over stdio and expose their tools,
resources, and prompts to the agent — tools/resources via the existing tool
layer, prompts via the TUI slash-command surface.

**Architecture:** A hand-rolled newline-JSON-RPC stdio client (no new deps). MCP
tools become ordinary `SomeTool`s via a new `DynamicTool` GADT tag (closing over
the server connection) and are merged into `ToolRegistry` at agent-run startup,
so they flow into the LLM request + system prompt unchanged. Resources become two
synthesized tools per server. Prompts surface in the M13.1 `/` autocomplete and a
`/prompts` overlay, invoked from the input line.

**Tech Stack:** Haskell (GHC 9.6.6, Stack lts-22.39), `aeson`, `process` (both
already deps), `brick`, `hspec`. Build is `-Wall -Werror` and must stay
hlint-clean.

**Spec:** `docs/superpowers/specs/2026-06-07-mcp-client-design.md`

**Build/test commands** (the engineer should use these throughout):
- Build: `~/.ghcup/bin/stack build --fast --ghc-options -Werror`
- Test: `~/.ghcup/bin/stack test --fast`
- Single spec: `~/.ghcup/bin/stack test --fast --ta '-m "OpenCode.MCP.Protocol"'`
- Lint: `hlint src test`

**Conventions:**
- Every commit message ends with the trailer line
  `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`.
- Work happens directly on `main` (explicit user consent).
- New library modules under `src/` are auto-discovered by hpack. New **test**
  modules must be added to `tests.opencode-hs-test.other-modules` in
  `package.yaml`.

---

## Task ordering and dependencies

```
1 Config.mcpServers ─┐
2 DynamicTool tag ────┤
3 MCP.Protocol ───────┼─► 4 MCP.Client ─► 5 mock server ─► 6 Client integration test
                      │                                      │
                      └────────────► 7 MCP.Adapters ◄────────┘
                                          │
                            8 AppEnv.envMcp + MCP.Startup + Run wiring
                                          │
                            9 autocomplete merge (dynamic prompts)
                                          │
                            10 TUI prompt invocation + /prompts overlay
                                          │
                            11 docs + memory
```

---

### Task 1: Config — `mcpServers` section

**Files:**
- Modify: `src/OpenCode/Config.hs`
- Modify: `test/OpenCode/ConfigSpec.hs`
- Modify: `test/OpenCode/TestEnv.hs` (2 `Config {…}` literals)
- Modify: `test/OpenCode/SessionSpec.hs` (1 `Config {…}` literal, if present)

- [ ] **Step 1: Write the failing test**

Add to `test/OpenCode/ConfigSpec.hs`. First add these imports if missing:
`import OpenCode.Config (McpServerConfig (..))` and ensure `buildConfig`,
`ConfigFile (..)`, `emptyConfigFile`, `EnvOverride (..)` are already imported
(they are used by existing tests). Add a sibling `describe`:

```haskell
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
      let Right cfg = buildConfig cf emptyEnv
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
      let Right cfg = buildConfig cf emptyEnv
      mcpServers cfg `shouldBe`
        [ ("srv", McpServerConfig "foo" [] [] True) ]

    it "is empty when the section is absent" $ do
      let Right cfg = buildConfig emptyConfigFile envWithKey
      mcpServers cfg `shouldBe` []

    it "preserves enabled:false" $ do
      let yaml = Text.unlines
            [ "providers: { openai: { apiKey: sk-x } }"
            , "mcpServers: { srv: { command: foo, enabled: false } }"
            ]
      cf <- either (fail . show) pure (Yaml.decodeEither' (Text.encodeUtf8 yaml))
      let Right cfg = buildConfig cf emptyEnv
      map (mcsEnabled . snd) (mcpServers cfg) `shouldBe` [False]
```

Add these helpers near the top of the spec's `where`/`let` region (or as
top-level binds) if equivalents don't already exist:

```haskell
emptyEnv :: EnvOverride
emptyEnv = EnvOverride Nothing Nothing Nothing

envWithKey :: EnvOverride
envWithKey = EnvOverride (Just (ApiKey "sk-x")) Nothing Nothing
```

Ensure these imports exist in the spec:
`import qualified Data.Yaml as Yaml`, `import qualified Data.Text as Text`,
`import qualified Data.Text.Encoding as Text`,
`import OpenCode.Types (ApiKey (..))`.

- [ ] **Step 2: Run the test to verify it fails (won't compile)**

Run: `~/.ghcup/bin/stack test --fast --ta '-m "mcpServers"'`
Expected: compile error — `McpServerConfig` not in scope / `mcpServers` not a
field of `Config`.

- [ ] **Step 3: Implement in `src/OpenCode/Config.hs`**

Add to the module export list (in the "Public types" section):

```haskell
    Config (..)
  , ProviderConfig (..)
  , McpServerConfig (..)
  , ConfigError (..)
```

Add the public type (after `ProviderConfig`):

```haskell
-- | One configured MCP server. 'mcsEnv' is merged over the inherited process
-- environment at spawn time; 'mcsEnabled' defaults to True.
data McpServerConfig = McpServerConfig
  { mcsCommand :: FilePath
  , mcsArgs    :: [Text]
  , mcsEnv     :: [(Text, Text)]
  , mcsEnabled :: Bool
  }
  deriving stock (Show, Eq)
```

Add the field to `Config`:

```haskell
data Config = Config
  { providers    :: ProviderConfig
  , defaultModel :: ModelId
  , mcpServers   :: [(Text, McpServerConfig)]   -- ^ name -> config, in file order
  }
  deriving stock (Show, Eq)
```

Add the YAML-shaped type + its decoder, and a field on `ConfigFile`. First the
new shape type (near the other `*File` types):

```haskell
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
```

Add `import Data.Map (Map)` and `import qualified Data.Map as Map` at the top,
and add `Aeson.withObject`/`(.:)`/`(.:?)` are already imported. Extend
`ConfigFile`:

```haskell
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
```

Also export `McpServerConfigFile (..)` in the "Internal YAML-shaped types"
export group (next to `ConfigFile (..)`).

In `buildConfig`, build the server list and add it to the result. Inside the
`let` block add:

```haskell
    mcpList = maybe [] (map toMcpServer . Map.toList) (cfMcpServers cf)
```

and a helper near `toModelId`:

```haskell
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
```

Add `import Data.Maybe (fromMaybe, isJust, isNothing)` (extend the existing
`Data.Maybe` import). Update the `Right Config {…}` literal:

```haskell
      else Right Config
        { providers    = providerCfg
        , defaultModel = defModel
        , mcpServers   = mcpList
        }
```

- [ ] **Step 4: Fix the other `Config {…}` literals (so the build passes `-Wmissing-fields`)**

In `test/OpenCode/TestEnv.hs`, both `Config {…}` literals (`withTestEnv` and
`mkDummyEnv`) gain one field:

```haskell
        , defaultModel = ModelId OpenAI "gpt-4o"
        , mcpServers   = []
        }
```

In `test/OpenCode/SessionSpec.hs`, add `, mcpServers = []` to any `Config {…}`
literal the compiler flags (search for `Config\n` / `= Config`).

- [ ] **Step 5: Run tests to verify they pass**

Run: `~/.ghcup/bin/stack test --fast --ta '-m "mcpServers"'`
Expected: 4 examples pass. Then full `~/.ghcup/bin/stack test --fast` — all green.
Then `hlint src test` → "No hints".

- [ ] **Step 6: Commit**

```bash
git add src/OpenCode/Config.hs test/OpenCode/ConfigSpec.hs test/OpenCode/TestEnv.hs test/OpenCode/SessionSpec.hs
git commit -m "$(printf 'M14: add mcpServers config section\n\nCo-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>')"
```

---

### Task 2: Tool.Types — `DynamicTool` GADT tag

**Files:**
- Modify: `src/OpenCode/Tool/Types.hs`
- Modify: `test/OpenCode/Tool/TypesSpec.hs`

The dynamic-tool path needs a GADT tag to fill the (never-inspected) `toolDef`
field of a runtime-built `SomeTool`. `executeTool` and `someToolDefinition` never
match on `toolDef`, so adding a constructor is safe.

- [ ] **Step 1: Write the failing test**

Add to `test/OpenCode/Tool/TypesSpec.hs` a sibling `describe` proving a
`SomeTool` built with `DynamicTool` (input `Value`, output `Text`) executes:

```haskell
  describe "DynamicTool (runtime tools)" $
    it "executes a Value->Text dynamic tool via executeTool" $ do
      env <- newDummyEnv
      let echo = SomeTool
            { toolDef     = DynamicTool
            , toolName    = "echo"
            , toolDesc    = "echo"
            , toolSchema  = Aeson.object ["type" Aeson..= ("object" :: Text)]
            , toolExecute = \v -> pure (Text.pack (show v))
            , toolRender  = id
            }
          reg = registerTool echo emptyRegistry
      result <- runAppM env (executeTool reg "echo" (Aeson.object ["a" Aeson..= (1 :: Int)]))
      result `shouldSatisfy` \case
        Right out -> "\"a\"" `Text.isInfixOf` out
        Left _    -> False
```

Ensure imports in the spec:
`import OpenCode.Tool.Types (SomeTool (..), ToolDef (..), registerTool, emptyRegistry, executeTool)`,
`import OpenCode.App (runAppM)`, `import OpenCode.TestEnv (newDummyEnv)`,
`import qualified Data.Aeson as Aeson`, `import Data.Text (Text)`,
`import qualified Data.Text as Text`. The spec file already enables
`LambdaCase` project-wide (it is in `package.yaml` `default-extensions`).

- [ ] **Step 2: Run to verify it fails**

Run: `~/.ghcup/bin/stack test --fast --ta '-m "DynamicTool"'`
Expected: compile error — `DynamicTool` not in scope.

- [ ] **Step 3: Implement**

In `src/OpenCode/Tool/Types.hs`, add the constructor to the GADT:

```haskell
data ToolDef input output where
  ReadFileTool  :: ToolDef ReadFileInput  Text
  WriteFileTool :: ToolDef WriteFileInput Text
  EditFileTool  :: ToolDef EditFileInput  Text
  BashTool      :: ToolDef BashInput      BashOutput
  GlobTool      :: ToolDef GlobInput      [FilePath]
  GrepTool      :: ToolDef GrepInput      [GrepMatch]
  DynamicTool   :: ToolDef Value          Text
    -- ^ MCP / runtime-discovered tools: raw JSON in, rendered text out. The tag
    -- is never inspected (see 'executeTool'); it exists only to fill 'toolDef'.
```

`Value` is already imported and already has `FromJSON` (the `SomeTool`
constraint). No other change is needed.

- [ ] **Step 4: Run to verify it passes**

Run: `~/.ghcup/bin/stack test --fast --ta '-m "DynamicTool"'` → PASS.
Then full `~/.ghcup/bin/stack build --fast --ghc-options -Werror` to confirm no
`-Wincomplete-patterns` warning fired anywhere (nothing matches on `ToolDef`).

- [ ] **Step 5: Commit**

```bash
git add src/OpenCode/Tool/Types.hs test/OpenCode/Tool/TypesSpec.hs
git commit -m "$(printf 'M14: add DynamicTool GADT tag for runtime tools\n\nCo-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>')"
```

---

### Task 3: `OpenCode.MCP.Protocol` (pure JSON-RPC + MCP codecs)

**Files:**
- Create: `src/OpenCode/MCP/Protocol.hs`
- Create: `test/OpenCode/MCP/ProtocolSpec.hs`
- Modify: `package.yaml` (add `OpenCode.MCP.ProtocolSpec` to test `other-modules`)

- [ ] **Step 1: Write the failing test**

Create `test/OpenCode/MCP/ProtocolSpec.hs`:

```haskell
{-# LANGUAGE OverloadedStrings #-}
module OpenCode.MCP.ProtocolSpec (spec) where

import qualified Data.Aeson as Aeson
import qualified Data.ByteString.Lazy as BL
import qualified Data.ByteString.Char8 as BS8
import Data.Either (isLeft)
import Test.Hspec

import OpenCode.MCP.Protocol

spec :: Spec
spec = do
  describe "encodeRequest" $ do
    it "produces a single line with jsonrpc/id/method" $ do
      let bs = encodeRequest (JsonRpcRequest 7 "tools/list" (Aeson.object []))
      BL.notElem 0x0a bs `shouldBe` True            -- no embedded newline
      let Just v = Aeson.decode bs :: Maybe Aeson.Value
      v `shouldBe` Aeson.object
        [ "jsonrpc" Aeson..= ("2.0" :: String)
        , "id"      Aeson..= (7 :: Int)
        , "method"  Aeson..= ("tools/list" :: String)
        , "params"  Aeson..= Aeson.object []
        ]

  describe "parseResponse" $ do
    it "decodes a result response" $ do
      let line = "{\"jsonrpc\":\"2.0\",\"id\":3,\"result\":{\"ok\":true}}"
      parseResponse (BS8.pack line) `shouldBe`
        Right (Right (JsonRpcResponse 3 (Right (Aeson.object ["ok" Aeson..= True]))))

    it "decodes an error response" $ do
      let line = "{\"jsonrpc\":\"2.0\",\"id\":3,\"error\":{\"code\":-32601,\"message\":\"nope\"}}"
      parseResponse (BS8.pack line) `shouldBe`
        Right (Right (JsonRpcResponse 3 (Left (JsonRpcError (-32601) "nope"))))

    it "classifies a notification (no id)" $ do
      let line = "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/log\",\"params\":{}}"
      case parseResponse (BS8.pack line) of
        Right (Left ntf) -> ntfMethod ntf `shouldBe` "notifications/log"
        other            -> expectationFailure (show other)

    it "rejects non-JSON" $
      parseResponse "not json" `shouldSatisfy` isLeft

  describe "decoders tolerate unknown fields and parse lists" $ do
    it "initialize capabilities" $ do
      let v = obj "{\"protocolVersion\":\"x\",\"capabilities\":{\"tools\":{},\"prompts\":{}},\"extra\":1}"
          Aeson.Success ir = Aeson.fromJSON v :: Aeson.Result InitializeResult
      capTools (initCapabilities ir)     `shouldBe` True
      capPrompts (initCapabilities ir)   `shouldBe` True
      capResources (initCapabilities ir) `shouldBe` False

    it "tools/list" $
      decodeToolsList (obj "{\"tools\":[{\"name\":\"echo\",\"description\":\"d\",\"inputSchema\":{}}]}")
        `shouldBe` Right [McpToolDef "echo" "d" (Aeson.object [])]

    it "tools/call with text and non-text content + isError" $ do
      let v = obj "{\"content\":[{\"type\":\"text\",\"text\":\"hi\"},{\"type\":\"image\"}],\"isError\":true}"
          Aeson.Success r = Aeson.fromJSON v :: Aeson.Result CallToolResult
      ctrIsError r `shouldBe` True
      renderContent (ctrContent r) `shouldBe` "hi\n[non-text content omitted]"

    it "resources/read (untyped content with text)" $ do
      let v = obj "{\"contents\":[{\"uri\":\"u\",\"text\":\"body\"}]}"
          Aeson.Success r = Aeson.fromJSON v :: Aeson.Result ReadResourceResult
      renderContent (rrContents r) `shouldBe` "body"

    it "prompts/list" $
      decodePromptsList (obj "{\"prompts\":[{\"name\":\"g\",\"description\":\"d\",\"arguments\":[{\"name\":\"x\",\"required\":true}]}]}")
        `shouldBe` Right [McpPrompt "g" (Just "d") [McpPromptArg "x" Nothing True]]

    it "prompts/get" $ do
      let v = obj "{\"messages\":[{\"role\":\"user\",\"content\":{\"type\":\"text\",\"text\":\"hey\"}}]}"
          Aeson.Success r = Aeson.fromJSON v :: Aeson.Result GetPromptResult
      map pmText (gprMessages r) `shouldBe` ["hey"]
      map pmRole (gprMessages r) `shouldBe` ["user"]

obj :: String -> Aeson.Value
obj s = maybe (error "bad json fixture") id (Aeson.decode (BL.fromStrict (BS8.pack s)))
```

Register the new test module in `package.yaml` under
`tests.opencode-hs-test.other-modules`, keeping the list alphabetical-ish near
the other `OpenCode.*` entries:

```yaml
      - OpenCode.MCP.ProtocolSpec
```

- [ ] **Step 2: Run to verify it fails**

Run: `~/.ghcup/bin/stack test --fast --ta '-m "OpenCode.MCP.Protocol"'`
Expected: compile error — `OpenCode.MCP.Protocol` not found.

- [ ] **Step 3: Implement `src/OpenCode/MCP/Protocol.hs`**

```haskell
{-# LANGUAGE OverloadedStrings #-}

-- | Pure JSON-RPC 2.0 + MCP wire types and codecs. No IO. Decoders tolerate
-- unknown fields (servers add their own) and missing optional fields.
module OpenCode.MCP.Protocol
  ( -- * JSON-RPC
    JsonRpcRequest (..)
  , JsonRpcNotification (..)
  , JsonRpcResponse (..)
  , JsonRpcError (..)
  , encodeRequest
  , encodeNotification
  , parseResponse
    -- * MCP messages
  , McpCapabilities (..)
  , emptyCaps
  , InitializeResult (..)
  , McpToolDef (..)
  , McpResource (..)
  , McpPromptArg (..)
  , McpPrompt (..)
  , ContentBlock (..)
  , CallToolResult (..)
  , ReadResourceResult (..)
  , PromptMessage (..)
  , GetPromptResult (..)
  , renderContent
    -- * Result-field decoders
  , decodeToolsList
  , decodeResourcesList
  , decodePromptsList
  ) where

import Data.Aeson
  ( FromJSON (..), ToJSON (..), Value (..), (.:), (.:?), (.!=), (.=)
  , object, withObject )
import qualified Data.Aeson as Aeson
import Data.Aeson.Types (parseEither)
import qualified Data.Aeson.KeyMap as KM
import Data.Bifunctor (bimap, first)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BL
import Data.Text (Text)
import qualified Data.Text as T

-- ---------------------------------------------------------------------------
-- JSON-RPC
-- ---------------------------------------------------------------------------

data JsonRpcRequest = JsonRpcRequest
  { reqId :: Int, reqMethod :: Text, reqParams :: Value }
  deriving stock (Show, Eq)

instance ToJSON JsonRpcRequest where
  toJSON r = object
    [ "jsonrpc" .= ("2.0" :: Text)
    , "id"      .= reqId r
    , "method"  .= reqMethod r
    , "params"  .= reqParams r
    ]

data JsonRpcNotification = JsonRpcNotification
  { ntfMethod :: Text, ntfParams :: Value }
  deriving stock (Show, Eq)

instance ToJSON JsonRpcNotification where
  toJSON n = object
    [ "jsonrpc" .= ("2.0" :: Text)
    , "method"  .= ntfMethod n
    , "params"  .= ntfParams n
    ]

instance FromJSON JsonRpcNotification where
  parseJSON = withObject "JsonRpcNotification" $ \o ->
    JsonRpcNotification <$> o .: "method" <*> o .:? "params" .!= Null

data JsonRpcError = JsonRpcError { errCode :: Int, errMessage :: Text }
  deriving stock (Show, Eq)

instance FromJSON JsonRpcError where
  parseJSON = withObject "JsonRpcError" $ \o ->
    JsonRpcError <$> o .: "code" <*> o .: "message"

data JsonRpcResponse = JsonRpcResponse
  { respId :: Int, respResult :: Either JsonRpcError Value }
  deriving stock (Show, Eq)

instance FromJSON JsonRpcResponse where
  parseJSON = withObject "JsonRpcResponse" $ \o -> do
    i    <- o .: "id"
    merr <- o .:? "error"
    case merr of
      Just e  -> pure (JsonRpcResponse i (Left e))
      Nothing -> JsonRpcResponse i . Right <$> o .:? "result" .!= Null

-- | One newline-delimited request line (no trailing newline; the caller adds it).
encodeRequest :: JsonRpcRequest -> BL.ByteString
encodeRequest = Aeson.encode

encodeNotification :: JsonRpcNotification -> BL.ByteString
encodeNotification = Aeson.encode

-- | Classify one server line as a notification or a response. 'Left' on a
-- line that is neither valid JSON nor a recognized JSON-RPC message.
parseResponse :: BS.ByteString -> Either Text (Either JsonRpcNotification JsonRpcResponse)
parseResponse bs = case Aeson.eitherDecodeStrict bs of
  Left e            -> Left (T.pack e)
  Right (Object o)
    | hasId o       -> bimap T.pack Right (parseEither parseJSON (Object o))
    | hasMethod o   -> bimap T.pack Left  (parseEither parseJSON (Object o))
    | otherwise     -> Left "unrecognized JSON-RPC message"
  Right _           -> Left "JSON-RPC message is not an object"
  where
    hasId m     = case KM.lookup "id" m of
                    Just Null -> False
                    Just _    -> True
                    Nothing   -> False
    hasMethod   = KM.member "method"

-- ---------------------------------------------------------------------------
-- MCP messages
-- ---------------------------------------------------------------------------

data McpCapabilities = McpCapabilities
  { capTools :: Bool, capResources :: Bool, capPrompts :: Bool }
  deriving stock (Show, Eq)

emptyCaps :: McpCapabilities
emptyCaps = McpCapabilities False False False

instance FromJSON McpCapabilities where
  parseJSON = withObject "McpCapabilities" $ \o -> pure McpCapabilities
    { capTools     = KM.member "tools" o
    , capResources = KM.member "resources" o
    , capPrompts   = KM.member "prompts" o
    }

data InitializeResult = InitializeResult
  { initProtocolVersion :: Text, initCapabilities :: McpCapabilities }
  deriving stock (Show, Eq)

instance FromJSON InitializeResult where
  parseJSON = withObject "InitializeResult" $ \o -> InitializeResult
    <$> o .:? "protocolVersion" .!= ""
    <*> o .:? "capabilities" .!= emptyCaps

data McpToolDef = McpToolDef
  { mtName :: Text, mtDescription :: Text, mtInputSchema :: Value }
  deriving stock (Show, Eq)

instance FromJSON McpToolDef where
  parseJSON = withObject "McpToolDef" $ \o -> McpToolDef
    <$> o .:  "name"
    <*> o .:? "description" .!= ""
    <*> o .:? "inputSchema" .!= object []

data McpResource = McpResource
  { mrUri :: Text, mrName :: Text, mrDescription :: Maybe Text, mrMimeType :: Maybe Text }
  deriving stock (Show, Eq)

instance FromJSON McpResource where
  parseJSON = withObject "McpResource" $ \o -> McpResource
    <$> o .:  "uri"
    <*> o .:? "name" .!= ""
    <*> o .:? "description"
    <*> o .:? "mimeType"

data McpPromptArg = McpPromptArg
  { mpaName :: Text, mpaDescription :: Maybe Text, mpaRequired :: Bool }
  deriving stock (Show, Eq)

instance FromJSON McpPromptArg where
  parseJSON = withObject "McpPromptArg" $ \o -> McpPromptArg
    <$> o .:  "name"
    <*> o .:? "description"
    <*> o .:? "required" .!= False

data McpPrompt = McpPrompt
  { mpName :: Text, mpDescription :: Maybe Text, mpArguments :: [McpPromptArg] }
  deriving stock (Show, Eq)

instance FromJSON McpPrompt where
  parseJSON = withObject "McpPrompt" $ \o -> McpPrompt
    <$> o .:  "name"
    <*> o .:? "description"
    <*> o .:? "arguments" .!= []

-- | A content block. We only distinguish text from everything else.
data ContentBlock = TextContent Text | OtherContent
  deriving stock (Show, Eq)

instance FromJSON ContentBlock where
  parseJSON = withObject "ContentBlock" $ \o -> do
    mty <- o .:? "type"
    case (mty :: Maybe Text) of
      Just "text" -> TextContent <$> o .:? "text" .!= ""
      Just _      -> pure OtherContent
      Nothing     -> maybe OtherContent TextContent <$> o .:? "text"  -- resource contents

data CallToolResult = CallToolResult
  { ctrContent :: [ContentBlock], ctrIsError :: Bool }
  deriving stock (Show, Eq)

instance FromJSON CallToolResult where
  parseJSON = withObject "CallToolResult" $ \o -> CallToolResult
    <$> o .:? "content" .!= []
    <*> o .:? "isError" .!= False

newtype ReadResourceResult = ReadResourceResult { rrContents :: [ContentBlock] }
  deriving stock (Show, Eq)

instance FromJSON ReadResourceResult where
  parseJSON = withObject "ReadResourceResult" $ \o ->
    ReadResourceResult <$> o .:? "contents" .!= []

data PromptMessage = PromptMessage { pmRole :: Text, pmText :: Text }
  deriving stock (Show, Eq)

instance FromJSON PromptMessage where
  parseJSON = withObject "PromptMessage" $ \o -> do
    role    <- o .:? "role" .!= "user"
    content <- o .: "content"
    pure (PromptMessage role (contentText content))

newtype GetPromptResult = GetPromptResult { gprMessages :: [PromptMessage] }
  deriving stock (Show, Eq)

instance FromJSON GetPromptResult where
  parseJSON = withObject "GetPromptResult" $ \o ->
    GetPromptResult <$> o .:? "messages" .!= []

-- | Extract text from a prompt message's @content@: a content object, or a bare
-- string.
contentText :: Value -> Text
contentText (String s) = s
contentText v = case parseEither parseJSON v of
  Right cb -> renderContent [cb]
  Left _   -> ""

-- | Join text blocks with newlines; render any non-text block as a placeholder.
renderContent :: [ContentBlock] -> Text
renderContent = T.intercalate "\n" . map render
  where
    render (TextContent t) = t
    render OtherContent    = "[non-text content omitted]"

-- ---------------------------------------------------------------------------
-- Result-field decoders (pull a typed list out of a method result object)
-- ---------------------------------------------------------------------------

-- Inline literal keys (OverloadedStrings makes "tools" :: Key); the element
-- type is fixed by each signature.
decodeToolsList :: Value -> Either Text [McpToolDef]
decodeToolsList = first T.pack . parseEither (withObject "toolsList" (.: "tools"))

decodeResourcesList :: Value -> Either Text [McpResource]
decodeResourcesList = first T.pack . parseEither (withObject "resourcesList" (.: "resources"))

decodePromptsList :: Value -> Either Text [McpPrompt]
decodePromptsList = first T.pack . parseEither (withObject "promptsList" (.: "prompts"))
```

- [ ] **Step 4: Run to verify it passes**

Run: `~/.ghcup/bin/stack test --fast --ta '-m "OpenCode.MCP.Protocol"'`
Expected: all examples pass. Then `hlint src test` → "No hints".

- [ ] **Step 5: Commit**

```bash
git add src/OpenCode/MCP/Protocol.hs test/OpenCode/MCP/ProtocolSpec.hs package.yaml opencode-hs.cabal
git commit -m "$(printf 'M14: MCP JSON-RPC + message protocol codecs\n\nCo-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>')"
```

(`opencode-hs.cabal` is regenerated by hpack during the build; include it.)

---

### Task 4: `OpenCode.MCP.Client` (stdio JSON-RPC client)

**Files:**
- Create: `src/OpenCode/MCP/Client.hs`

No dedicated unit test (the IO is exercised by the Task 6 integration test). This
task only needs to compile clean.

- [ ] **Step 1: Implement `src/OpenCode/MCP/Client.hs`**

```haskell
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE OverloadedStrings #-}

-- | A minimal MCP client over stdio: spawn a server process, perform the
-- @initialize@ handshake, and make @tools/call@ / @resources/read@ /
-- @prompts/get@ requests. Newline-delimited JSON-RPC. One 'MVar' serializes
-- request/response per server; calls are wrapped in a per-call timeout.
module OpenCode.MCP.Client
  ( McpError (..)
  , renderMcpError
  , McpClient (..)
  , connect
  , callTool
  , readResource
  , getPrompt
  , shutdown
  ) where

import Control.Concurrent (forkIO)
import Control.Concurrent.MVar (MVar, newMVar, withMVar)
import Control.Exception (SomeException, catch, try)
import Control.Monad (void)
import Data.Aeson (FromJSON, Value, object, (.=))
import qualified Data.Aeson as Aeson
import qualified Data.Aeson.Key as Key
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BL
import Data.IORef (IORef, atomicModifyIORef', newIORef)
import Data.Text (Text)
import qualified Data.Text as T
import System.Environment (getEnvironment)
import System.IO
  ( BufferMode (LineBuffering), Handle, hClose, hFlush, hIsEOF, hSetBuffering )
import System.Process
  ( CreateProcess (..), ProcessHandle, StdStream (CreatePipe)
  , createProcess, proc, terminateProcess, waitForProcess )
import System.Timeout (timeout)

import OpenCode.Config (McpServerConfig (..))
import OpenCode.MCP.Protocol

-- | Per-call timeout (microseconds): 30 seconds.
callTimeoutMicros :: Int
callTimeoutMicros = 30 * 1000000

data McpError
  = SpawnFailed Text
  | HandshakeFailed Text
  | CallTimeout Text
  | CallFailed Text
  deriving stock (Show, Eq)

renderMcpError :: McpError -> Text
renderMcpError = \case
  SpawnFailed m     -> "spawn failed: " <> m
  HandshakeFailed m -> "handshake failed: " <> m
  CallTimeout m     -> "timed out: " <> m
  CallFailed m      -> m

data McpClient = McpClient
  { mcName      :: Text
  , mcCaps      :: McpCapabilities
  , mcTools     :: [McpToolDef]
  , mcResources :: [McpResource]
  , mcPrompts   :: [McpPrompt]
  , mcIn        :: Handle
  , mcOut       :: Handle
  , mcProc      :: ProcessHandle
  , mcLock      :: MVar ()
  , mcNextId    :: IORef Int
  }

-- ---------------------------------------------------------------------------
-- Connect / handshake
-- ---------------------------------------------------------------------------

connect :: Text -> McpServerConfig -> IO (Either McpError McpClient)
connect name cfg = do
  spawned <- try (spawnServer cfg)
  case (spawned :: Either SomeException (Handle, Handle, Handle, ProcessHandle)) of
    Left e -> pure (Left (SpawnFailed (T.pack (show e))))
    Right (hin, hout, herr, ph) -> do
      hSetBuffering hin LineBuffering
      hSetBuffering hout LineBuffering
      _    <- forkIO (drainHandle herr)
      lock <- newMVar ()
      idr  <- newIORef 0
      let base = McpClient name emptyCaps [] [] [] hin hout ph lock idr
      r <- try (handshake base)
      case (r :: Either SomeException (Either McpError McpClient)) of
        Left e          -> killProc ph hin >> pure (Left (HandshakeFailed (T.pack (show e))))
        Right (Left er) -> killProc ph hin >> pure (Left er)
        Right (Right c) -> pure (Right c)

spawnServer :: McpServerConfig -> IO (Handle, Handle, Handle, ProcessHandle)
spawnServer cfg = do
  parentEnv <- getEnvironment
  let cp = (proc (mcsCommand cfg) (map T.unpack (mcsArgs cfg)))
        { std_in  = CreatePipe
        , std_out = CreatePipe
        , std_err = CreatePipe
        , env     = Just (mergeEnv parentEnv (mcsEnv cfg))
        }
  (mIn, mOut, mErr, ph) <- createProcess cp
  case (mIn, mOut, mErr) of
    (Just hin, Just hout, Just herr) -> pure (hin, hout, herr, ph)
    _ -> ioError (userError "createProcess did not return all pipes")

mergeEnv :: [(String, String)] -> [(Text, Text)] -> [(String, String)]
mergeEnv parent overrides =
  let ov     = map (\(k, v) -> (T.unpack k, T.unpack v)) overrides
      ovKeys = map fst ov
  in filter ((`notElem` ovKeys) . fst) parent ++ ov

handshake :: McpClient -> IO (Either McpError McpClient)
handshake c = do
  let initParams = object
        [ "protocolVersion" .= ("2024-11-05" :: Text)
        , "capabilities"    .= object []
        , "clientInfo"      .= object
            [ "name" .= ("opencode-hs" :: Text), "version" .= ("0.1" :: Text) ]
        ]
  ir <- call c "initialize" initParams
  case ir of
    Left e        -> pure (Left e)
    Right resVal  -> case Aeson.fromJSON resVal :: Aeson.Result InitializeResult of
      Aeson.Error msg       -> pure (Left (HandshakeFailed (T.pack msg)))
      Aeson.Success initRes -> do
        sendNotification c "notifications/initialized" (object [])
        let caps = initCapabilities initRes
        tools <- if capTools caps
                   then listOrEmpty (call c "tools/list" (object [])) decodeToolsList
                   else pure []
        ress  <- if capResources caps
                   then listOrEmpty (call c "resources/list" (object [])) decodeResourcesList
                   else pure []
        prms  <- if capPrompts caps
                   then listOrEmpty (call c "prompts/list" (object [])) decodePromptsList
                   else pure []
        pure (Right c { mcCaps = caps, mcTools = tools, mcResources = ress, mcPrompts = prms })

-- | Run a list call; an error or decode failure degrades to an empty list (a
-- broken list endpoint must not fail the whole handshake).
listOrEmpty :: IO (Either McpError Value) -> (Value -> Either Text [a]) -> IO [a]
listOrEmpty act decode = do
  r <- act
  pure $ case r of
    Left _  -> []
    Right v -> either (const []) id (decode v)

-- ---------------------------------------------------------------------------
-- Typed requests
-- ---------------------------------------------------------------------------

callTool :: McpClient -> Text -> Value -> IO (Either McpError CallToolResult)
callTool c name args = do
  r <- call c "tools/call" (object ["name" .= name, "arguments" .= args])
  pure (r >>= decodeAs "tools/call")

readResource :: McpClient -> Text -> IO (Either McpError ReadResourceResult)
readResource c uri = do
  r <- call c "resources/read" (object ["uri" .= uri])
  pure (r >>= decodeAs "resources/read")

getPrompt :: McpClient -> Text -> [(Text, Text)] -> IO (Either McpError GetPromptResult)
getPrompt c name args = do
  let argObj = object [ Key.fromText k .= v | (k, v) <- args ]
  r <- call c "prompts/get" (object ["name" .= name, "arguments" .= argObj])
  pure (r >>= decodeAs "prompts/get")

decodeAs :: FromJSON a => Text -> Value -> Either McpError a
decodeAs ctx v = case Aeson.fromJSON v of
  Aeson.Error e   -> Left (CallFailed (ctx <> ": " <> T.pack e))
  Aeson.Success a -> Right a

-- ---------------------------------------------------------------------------
-- Low-level request/response
-- ---------------------------------------------------------------------------

call :: McpClient -> Text -> Value -> IO (Either McpError Value)
call c method params = withMVar (mcLock c) $ \_ -> do
  i <- atomicModifyIORef' (mcNextId c) (\n -> (n + 1, n + 1))
  res <- timeout callTimeoutMicros $ do
    BL.hPut (mcIn c) (encodeRequest (JsonRpcRequest i method params))
    BL.hPut (mcIn c) "\n"
    hFlush (mcIn c)
    awaitResponse c i
  pure $ case res of
    Nothing        -> Left (CallTimeout method)
    Just outcome   -> outcome

awaitResponse :: McpClient -> Int -> IO (Either McpError Value)
awaitResponse c expectId = loop
  where
    loop = do
      eof <- hIsEOF (mcOut c)
      if eof
        then pure (Left (CallFailed "server closed the connection"))
        else do
          line <- BS.hGetLine (mcOut c)
          if BS.null line
            then loop
            else case parseResponse line of
              Left _              -> loop          -- skip log/garbage line
              Right (Left _ntf)   -> loop          -- skip notification
              Right (Right resp)
                | respId resp /= expectId -> loop  -- stale id; keep reading
                | otherwise -> pure $ case respResult resp of
                    Left jerr -> Left (CallFailed (errMessage jerr))
                    Right v   -> Right v

sendNotification :: McpClient -> Text -> Value -> IO ()
sendNotification c method params = do
  BL.hPut (mcIn c) (encodeNotification (JsonRpcNotification method params))
  BL.hPut (mcIn c) "\n"
  hFlush (mcIn c)

-- ---------------------------------------------------------------------------
-- Teardown / helpers
-- ---------------------------------------------------------------------------

shutdown :: McpClient -> IO ()
shutdown c = killProc (mcProc c) (mcIn c)

killProc :: ProcessHandle -> Handle -> IO ()
killProc ph hin = do
  ignore (hClose hin)
  ignore (terminateProcess ph)
  ignore (void (waitForProcess ph))
  where ignore act = act `catch` \(_ :: SomeException) -> pure ()

-- | Read and discard a handle until EOF (used for the server's stderr).
drainHandle :: Handle -> IO ()
drainHandle h = loop `catch` \(_ :: SomeException) -> pure ()
  where
    loop = do
      eof <- hIsEOF h
      if eof then pure () else BS.hGetLine h >> loop
```

- [ ] **Step 2: Build**

Run: `~/.ghcup/bin/stack build --fast --ghc-options -Werror`
Expected: clean. Then `hlint src` → "No hints".

- [ ] **Step 3: Commit**

```bash
git add src/OpenCode/MCP/Client.hs package.yaml opencode-hs.cabal
git commit -m "$(printf 'M14: MCP stdio client (connect, call, shutdown)\n\nCo-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>')"
```

---

### Task 5: Mock MCP server executable

**Files:**
- Create: `test/mcp-mock/Main.hs`
- Modify: `package.yaml` (new `executables.opencode-mcp-mock` stanza)

A tiny stdio JSON-RPC server used only by the integration test. Speaks the same
newline framing and advertises all three capabilities.

- [ ] **Step 1: Create `test/mcp-mock/Main.hs`**

```haskell
{-# LANGUAGE OverloadedStrings #-}

-- | A minimal MCP server over stdio for integration tests. Advertises tools,
-- resources, and prompts. The @echo@ tool returns its JSON arguments as text.
module Main (main) where

import Data.Aeson (Value (..), object, (.=))
import qualified Data.Aeson as Aeson
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BL
import Data.Text (Text)
import Data.Text.Encoding (decodeUtf8)
import System.IO
  ( BufferMode (LineBuffering), hFlush, hIsEOF, hSetBuffering, stdin, stdout )

main :: IO ()
main = do
  hSetBuffering stdout LineBuffering
  hSetBuffering stdin LineBuffering
  loop

loop :: IO ()
loop = do
  eof <- hIsEOF stdin
  if eof
    then pure ()
    else do
      line <- BS.hGetLine stdin
      case Aeson.decodeStrict line :: Maybe Value of
        Just (Object o) -> dispatch o >> loop
        _               -> loop

dispatch :: KM.KeyMap Value -> IO ()
dispatch o = case KM.lookup "id" o of
  Nothing    -> pure ()                       -- notification; ignore
  Just idVal -> respond idVal (methodOf o) o

methodOf :: KM.KeyMap Value -> Text
methodOf o = case KM.lookup "method" o of
  Just (String m) -> m
  _               -> ""

respond :: Value -> Text -> KM.KeyMap Value -> IO ()
respond idVal method o = case method of
  "initialize" -> reply idVal $ object
    [ "protocolVersion" .= ("2024-11-05" :: Text)
    , "capabilities" .= object
        [ "tools" .= object [], "resources" .= object [], "prompts" .= object [] ]
    , "serverInfo" .= object ["name" .= ("mock" :: Text), "version" .= ("0" :: Text)]
    ]
  "tools/list" -> reply idVal $ object
    [ "tools" .=
        [ object
            [ "name" .= ("echo" :: Text)
            , "description" .= ("echoes its arguments" :: Text)
            , "inputSchema" .= object ["type" .= ("object" :: Text)]
            ]
        ]
    ]
  "tools/call"
    | toolNameOf o == "boom" -> replyError idVal "boom tool always fails"
    | otherwise -> reply idVal $ object
        [ "content" .= [ object ["type" .= ("text" :: Text), "text" .= echoArgs o] ]
        , "isError" .= False
        ]
  "resources/list" -> reply idVal $ object
    [ "resources" .=
        [ object ["uri" .= ("mock://a" :: Text), "name" .= ("a" :: Text)] ]
    ]
  "resources/read" -> reply idVal $ object
    [ "contents" .=
        [ object ["uri" .= ("mock://a" :: Text), "text" .= ("resource body" :: Text)] ]
    ]
  "prompts/list" -> reply idVal $ object
    [ "prompts" .=
        [ object
            [ "name" .= ("greet" :: Text)
            , "description" .= ("greet someone" :: Text)
            , "arguments" .= ([] :: [Value])
            ]
        ]
    ]
  "prompts/get" -> reply idVal $ object
    [ "messages" .=
        [ object
            [ "role" .= ("user" :: Text)
            , "content" .= object ["type" .= ("text" :: Text), "text" .= ("hello there" :: Text)]
            ]
        ]
    ]
  _ -> replyError idVal ("unknown method: " <> method)

-- | The JSON-encoded @arguments@ of a tools/call request, as text.
echoArgs :: KM.KeyMap Value -> Text
echoArgs o = case KM.lookup "params" o of
  Just (Object p) -> case KM.lookup "arguments" p of
    Just args -> decodeUtf8 (BL.toStrict (Aeson.encode args))
    Nothing   -> "{}"
  _ -> "{}"

-- | The @name@ of a tools/call request.
toolNameOf :: KM.KeyMap Value -> Text
toolNameOf o = case KM.lookup "params" o of
  Just (Object p) -> case KM.lookup "name" p of
    Just (String n) -> n
    _               -> ""
  _ -> ""

reply :: Value -> Value -> IO ()
reply idVal result =
  emit (object ["jsonrpc" .= ("2.0" :: Text), "id" .= idVal, "result" .= result])

replyError :: Value -> Text -> IO ()
replyError idVal msg =
  emit (object
    [ "jsonrpc" .= ("2.0" :: Text)
    , "id" .= idVal
    , "error" .= object ["code" .= (-32601 :: Int), "message" .= msg]
    ])

emit :: Value -> IO ()
emit v = BL.hPut stdout (Aeson.encode v) >> BL.hPut stdout "\n" >> hFlush stdout
```

- [ ] **Step 2: Add the executable stanza to `package.yaml`**

After the existing `executables.opencode-hs` block, add:

```yaml
  opencode-mcp-mock:
    main:         Main.hs
    source-dirs:  test/mcp-mock
    ghc-options:
      - -threaded
      - -rtsopts
      - -with-rtsopts=-N
    dependencies:
      - aeson
      - bytestring
      - text
```

(It deliberately does **not** depend on `opencode-hs` — it is self-contained.)

- [ ] **Step 3: Build the executable**

Run: `~/.ghcup/bin/stack build --fast --ghc-options -Werror opencode-hs:exe:opencode-mcp-mock`
Expected: builds clean. Then `hlint test/mcp-mock` → "No hints".

- [ ] **Step 4: Commit**

```bash
git add test/mcp-mock/Main.hs package.yaml opencode-hs.cabal
git commit -m "$(printf 'M14: in-repo mock MCP server for integration tests\n\nCo-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>')"
```

---

### Task 6: `OpenCode.MCP.Client` integration test (against the mock)

**Files:**
- Create: `test/OpenCode/MCP/ClientSpec.hs`
- Modify: `package.yaml` (add `OpenCode.MCP.ClientSpec` to test `other-modules`)

- [ ] **Step 1: Write the test**

```haskell
{-# LANGUAGE OverloadedStrings #-}
module OpenCode.MCP.ClientSpec (spec) where

import Control.Exception (bracket)
import qualified Data.Aeson as Aeson
import Data.Text (Text)
import qualified Data.Text as T
import System.Directory (doesFileExist)
import System.Environment (lookupEnv)
import System.FilePath ((</>))
import Test.Hspec

import Paths_opencode_hs (getBinDir)
import OpenCode.Config (McpServerConfig (..))
import OpenCode.MCP.Client
import OpenCode.MCP.Protocol

-- | Locate the built mock server: honor OPENCODE_MCP_MOCK, else look in the
-- package's bin dir (stack builds executables before running the test suite).
mockServerPath :: IO (Maybe FilePath)
mockServerPath = do
  override <- lookupEnv "OPENCODE_MCP_MOCK"
  case override of
    Just p  -> pure (Just p)
    Nothing -> do
      bin <- getBinDir
      let p = bin </> "opencode-mcp-mock"
      ok <- doesFileExist p
      pure (if ok then Just p else Nothing)

withMock :: (McpClient -> IO a) -> IO a
withMock k = do
  mp <- mockServerPath
  case mp of
    Nothing   -> error "opencode-mcp-mock not found (build it with `stack build`)"
    Just path -> do
      let cfg = McpServerConfig { mcsCommand = path, mcsArgs = [], mcsEnv = [], mcsEnabled = True }
      r <- connect "mock" cfg
      case r of
        Left e  -> error ("mock connect failed: " <> T.unpack (renderMcpError e))
        Right c -> bracket (pure c) shutdown k

spec :: Spec
spec = describe "OpenCode.MCP.Client (against the mock server)" $ do
  it "handshakes and caches the three capability lists" $ withMock $ \c -> do
    capTools (mcCaps c)     `shouldBe` True
    capResources (mcCaps c) `shouldBe` True
    capPrompts (mcCaps c)   `shouldBe` True
    map mtName (mcTools c)    `shouldBe` ["echo"]
    map mrUri  (mcResources c) `shouldBe` ["mock://a"]
    map mpName (mcPrompts c)  `shouldBe` ["greet"]

  it "round-trips a tools/call (echo)" $ withMock $ \c -> do
    r <- callTool c "echo" (Aeson.object ["msg" Aeson..= ("hi" :: Text)])
    case r of
      Right res -> renderContent (ctrContent res) `shouldSatisfy` ("hi" `T.isInfixOf`)
      Left e    -> expectationFailure (T.unpack (renderMcpError e))

  it "reads a resource" $ withMock $ \c -> do
    r <- readResource c "mock://a"
    fmap (renderContent . rrContents) r `shouldBe` Right "resource body"

  it "gets a prompt" $ withMock $ \c -> do
    r <- getPrompt c "greet" []
    fmap (map pmText . gprMessages) r `shouldBe` Right ["hello there"]

  it "returns Left when a tool call errors (graceful failure)" $ withMock $ \c -> do
    -- the mock replies with a JSON-RPC error for the "boom" tool; the client
    -- must surface that as Left without throwing.
    r <- callTool c "boom" (Aeson.object [])
    case r of
      Left _  -> pure ()
      Right _ -> expectationFailure "expected Left for the boom tool"
```

Register in `package.yaml` test `other-modules`:

```yaml
      - OpenCode.MCP.ClientSpec
```

`Paths_opencode_hs` is auto-generated and already available to the test suite;
no extra `other-modules` entry is needed for it.

- [ ] **Step 2: Run the test**

Run: `~/.ghcup/bin/stack test --fast --ta '-m "OpenCode.MCP.Client"'`
Expected: 5 examples pass (stack builds `opencode-mcp-mock` first, so
`getBinDir` resolves it).

- [ ] **Step 3: Commit**

```bash
git add test/OpenCode/MCP/ClientSpec.hs package.yaml opencode-hs.cabal
git commit -m "$(printf 'M14: MCP client integration test against mock server\n\nCo-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>')"
```

---

### Task 7: `OpenCode.MCP.Adapters` (converters + prompt parsing)

**Files:**
- Create: `src/OpenCode/MCP/Adapters.hs`
- Create: `test/OpenCode/MCP/AdaptersSpec.hs`
- Modify: `package.yaml` (add `OpenCode.MCP.AdaptersSpec`)

This module defines `PromptEntry` (the UI-facing prompt descriptor),
the tool/resource converters, and the pure prompt-line parser. The IO-touching
converters (`toolToSomeTool`, `resourceTools`) are validated by name/schema in
the unit test; their executors are covered transitively by Task 6's mock.

- [ ] **Step 1: Write the failing test**

`test/OpenCode/MCP/AdaptersSpec.hs`:

```haskell
{-# LANGUAGE OverloadedStrings #-}
module OpenCode.MCP.AdaptersSpec (spec) where

import qualified Data.Aeson as Aeson
import Test.Hspec

import OpenCode.MCP.Adapters
import OpenCode.MCP.Protocol (McpPrompt (..), McpPromptArg (..))

spec :: Spec
spec = do
  describe "mcpToolName" $
    it "namespaces tool by server with underscore" $
      mcpToolName "filesystem" "read_file" `shouldBe` "filesystem_read_file"

  describe "parsePromptInvocation" $ do
    it "parses a bare /name" $
      parsePromptInvocation "/greet" `shouldBe` Just ("greet", [])

    it "parses key=value args" $
      parsePromptInvocation "/srv_greet name=ann lang=en"
        `shouldBe` Just ("srv_greet", [("name", "ann"), ("lang", "en")])

    it "ignores tokens without '='" $
      parsePromptInvocation "/greet hello name=ann"
        `shouldBe` Just ("greet", [("name", "ann")])

    it "returns Nothing for non-slash input" $
      parsePromptInvocation "hello world" `shouldBe` Nothing

    it "returns Nothing for a bare slash" $
      parsePromptInvocation "/" `shouldBe` Nothing

  describe "promptEntryOf" $
    it "builds a full name + required-arg list from an McpPrompt" $ do
      let p = McpPrompt "greet" (Just "d") [McpPromptArg "name" Nothing True, McpPromptArg "lang" Nothing False]
          e = promptEntryOf "srv" p
      peFullName e     `shouldBe` "srv_greet"
      peServer e       `shouldBe` "srv"
      peName e         `shouldBe` "greet"
      peDescription e  `shouldBe` "d"
      peRequiredArgs e `shouldBe` ["name"]

  describe "missingArgs" $ do
    it "reports required args that are absent" $
      missingArgs (PromptEntry "x" "s" "x" "" ["name"]) [] `shouldBe` ["name"]
    it "is empty when all present" $
      missingArgs (PromptEntry "x" "s" "x" "" ["name"]) [("name", "a")] `shouldBe` []

  describe "resourceListSchema is a valid object schema" $
    it "round-trips through aeson" $
      Aeson.decode (Aeson.encode resourceReadSchema) `shouldBe` Just resourceReadSchema
```

Register in `package.yaml` test `other-modules`: `- OpenCode.MCP.AdaptersSpec`.

- [ ] **Step 2: Run to verify it fails**

Run: `~/.ghcup/bin/stack test --fast --ta '-m "OpenCode.MCP.Adapters"'`
Expected: compile error — module not found.

- [ ] **Step 3: Implement `src/OpenCode/MCP/Adapters.hs`**

```haskell
{-# LANGUAGE OverloadedStrings #-}

-- | Convert discovered MCP capabilities into the app's own abstractions:
-- tools and resources become 'SomeTool's on the dynamic-tool path; prompts
-- become 'PromptEntry' descriptors for the TUI. Also the pure parser for a
-- @\/name k=v@ prompt-invocation line.
module OpenCode.MCP.Adapters
  ( PromptEntry (..)
  , mcpToolName
  , toolToSomeTool
  , resourceTools
  , clientSomeTools
  , promptEntryOf
  , promptEntries
  , promptSuggestEntries
  , parsePromptInvocation
  , missingArgs
  , resourceReadSchema
  ) where

import Control.Monad.Except (MonadError, throwError)
import Control.Monad.IO.Class (liftIO)
import Data.Aeson (Value (..), object, (.=))
import qualified Data.Aeson.KeyMap as KM
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T

import OpenCode.App.Error (AppError (ToolError))
import OpenCode.MCP.Client
  ( McpClient (..), McpError, callTool, readResource, renderMcpError )
import OpenCode.MCP.Protocol
import OpenCode.Tool.Types (SomeTool (..), ToolDef (DynamicTool))

-- | A prompt the user can invoke from the TUI.
data PromptEntry = PromptEntry
  { peFullName     :: Text     -- ^ @<server>_<prompt>@ (no leading slash)
  , peServer       :: Text     -- ^ owning server name (matches 'mcName')
  , peName         :: Text     -- ^ raw prompt name on the server
  , peDescription  :: Text
  , peRequiredArgs :: [Text]
  }
  deriving stock (Show, Eq)

-- ---------------------------------------------------------------------------
-- Naming
-- ---------------------------------------------------------------------------

mcpToolName :: Text -> Text -> Text
mcpToolName server tool = server <> "_" <> tool

-- ---------------------------------------------------------------------------
-- Tools
-- ---------------------------------------------------------------------------

toolToSomeTool :: McpClient -> McpToolDef -> SomeTool
toolToSomeTool c t = SomeTool
  { toolDef     = DynamicTool
  , toolName    = fullName
  , toolDesc    = mtDescription t
  , toolSchema  = mtInputSchema t
  , toolExecute = \args -> do
      r <- liftIO (callTool c (mtName t) args)
      either (failWith fullName) (pure . renderContent . ctrContent) r
  , toolRender  = id
  }
  where fullName = mcpToolName (mcName c) (mtName t)

-- | When a server advertises resources, expose two tools so the LLM can list
-- and read them through the normal tool path.
resourceTools :: McpClient -> [SomeTool]
resourceTools c
  | not (capResources (mcCaps c)) = []
  | otherwise = [listTool, readTool]
  where
    server   = mcName c
    listName = mcpToolName server "list_resources"
    readName = mcpToolName server "read_resource"

    listTool = SomeTool
      { toolDef     = DynamicTool
      , toolName    = listName
      , toolDesc    = "list resources from the " <> server <> " MCP server"
      , toolSchema  = object ["type" .= ("object" :: Text), "properties" .= object []]
      , toolExecute = \_ -> pure (renderResourceList (mcResources c))
      , toolRender  = id
      }

    readTool = SomeTool
      { toolDef     = DynamicTool
      , toolName    = readName
      , toolDesc    = "read a resource by uri from the " <> server <> " MCP server"
      , toolSchema  = resourceReadSchema
      , toolExecute = \args -> case extractUri args of
          Nothing  -> throwError (ToolError readName "missing 'uri' argument")
          Just uri -> do
            r <- liftIO (readResource c uri)
            either (failWith readName) (pure . renderContent . rrContents) r
      , toolRender  = id
      }

-- | All tools (real + synthesized resource tools) a client contributes.
clientSomeTools :: McpClient -> [SomeTool]
clientSomeTools c = map (toolToSomeTool c) (mcTools c) ++ resourceTools c

resourceReadSchema :: Value
resourceReadSchema = object
  [ "type" .= ("object" :: Text)
  , "properties" .= object ["uri" .= object ["type" .= ("string" :: Text)]]
  , "required" .= (["uri"] :: [Text])
  ]

-- | Turn an MCP transport error into a tool error. Works in any
-- @MonadError AppError m@ (the tool executors run in 'AppM').
failWith :: MonadError AppError m => Text -> McpError -> m a
failWith name e = throwError (ToolError name (renderMcpError e))

extractUri :: Value -> Maybe Text
extractUri (Object o) = case KM.lookup "uri" o of
  Just (String s) -> Just s
  _               -> Nothing
extractUri _ = Nothing

renderResourceList :: [McpResource] -> Text
renderResourceList [] = "(no resources)"
renderResourceList rs = T.intercalate "\n" (map row rs)
  where
    row r = mrUri r <> "  " <> mrName r <> maybe "" (" — " <>) (mrDescription r)

-- ---------------------------------------------------------------------------
-- Prompts
-- ---------------------------------------------------------------------------

promptEntryOf :: Text -> McpPrompt -> PromptEntry
promptEntryOf server p = PromptEntry
  { peFullName     = mcpToolName server (mpName p)
  , peServer       = server
  , peName         = mpName p
  , peDescription  = fromMaybe "" (mpDescription p)
  , peRequiredArgs = [ mpaName a | a <- mpArguments p, mpaRequired a ]
  }

promptEntries :: McpClient -> [PromptEntry]
promptEntries c = map (promptEntryOf (mcName c)) (mcPrompts c)

-- | Autocomplete entries (slash-prefixed name + description) for every prompt
-- across the given clients.
promptSuggestEntries :: [McpClient] -> [(Text, Text)]
promptSuggestEntries cs =
  [ ("/" <> peFullName e, peDescription e) | c <- cs, e <- promptEntries c ]

-- | Parse a @\/name k=v k2=v2@ prompt-invocation line. The name carries no
-- leading slash in the result. Tokens without an @=@ are ignored. 'Nothing'
-- for input that is not a single @\/word …@.
parsePromptInvocation :: Text -> Maybe (Text, [(Text, Text)])
parsePromptInvocation raw = case T.words (T.strip raw) of
  (w : rest)
    | Just nm <- T.stripPrefix "/" w, not (T.null nm) ->
        Just (nm, [ (k, T.drop 1 vEq)
                  | tok <- rest
                  , let (k, vEq) = T.breakOn "=" tok
                  , not (T.null k), not (T.null vEq) ])
  _ -> Nothing

-- | Required arg names not present in the supplied key=value pairs.
missingArgs :: PromptEntry -> [(Text, Text)] -> [Text]
missingArgs entry args =
  [ a | a <- peRequiredArgs entry, a `notElem` map fst args ]
```

- [ ] **Step 4: Run to verify it passes**

Run: `~/.ghcup/bin/stack test --fast --ta '-m "OpenCode.MCP.Adapters"'`
Expected: all examples pass. Then `hlint src test` → "No hints".

- [ ] **Step 5: Commit**

```bash
git add src/OpenCode/MCP/Adapters.hs test/OpenCode/MCP/AdaptersSpec.hs package.yaml opencode-hs.cabal
git commit -m "$(printf 'M14: MCP adapters (tool/resource/prompt converters)\n\nCo-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>')"
```

---

### Task 8: `AppEnv.envMcp` + `MCP.Startup` + `Run.hs` wiring

**Files:**
- Modify: `src/OpenCode/App/Types.hs` (add `envMcp` field)
- Create: `src/OpenCode/MCP/Startup.hs`
- Modify: `src/OpenCode/Run.hs` (spawn at agent-run startup, merge tools, shutdown, diagnostics)
- Modify: `test/OpenCode/TestEnv.hs` (`envMcp = []` in both `AppEnv {…}` literals)
- Create: `test/OpenCode/MCP/StartupSpec.hs`
- Modify: `package.yaml` (add `OpenCode.MCP.StartupSpec`)

- [ ] **Step 1: Add `envMcp` to `AppEnv`**

In `src/OpenCode/App/Types.hs`, add the import and field:

```haskell
import OpenCode.MCP.Client (McpClient)
-- ...
data AppEnv = AppEnv
  { envConfig    :: Config
  , envDb        :: Connection
  , envRegistry  :: ToolRegistry
  , envEventChan :: BChan SessionEvent
  , envAbort     :: TVar Bool
  , envMcp       :: [McpClient]
  }
```

No import cycle: `MCP.Client` imports only `Config` + `MCP.Protocol` + base
libraries; it does not import `App.Types`.

- [ ] **Step 2: Update the test `AppEnv` literals**

In `test/OpenCode/TestEnv.hs`, both `AppEnv {…}` literals (`withTestEnv` and
`mkDummyEnv`) gain:

```haskell
        , envAbort     = abortVar
        , envMcp       = []
        }
```

Build now to confirm only the intended sites need updating:
`~/.ghcup/bin/stack build --fast --ghc-options -Werror` — fix any remaining
`AppEnv {…}` literal the compiler flags by adding `envMcp = []`.

- [ ] **Step 3: Write the failing Startup test**

`test/OpenCode/MCP/StartupSpec.hs`:

```haskell
module OpenCode.MCP.StartupSpec (spec) where

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
    lookupName reg n = maybe False (const True) (lookupTool n reg)
```

Register `- OpenCode.MCP.StartupSpec` in `package.yaml` test `other-modules`.

- [ ] **Step 4: Implement `src/OpenCode/MCP/Startup.hs`**

```haskell
{-# LANGUAGE ScopedTypeVariables #-}

-- | Startup wiring for MCP servers: connect each enabled server, fold its tools
-- (and synthesized resource tools) into the registry, and collect diagnostics
-- for servers that fail to start. Shutdown is the caller's responsibility (via
-- 'bracket' in 'OpenCode.Run').
module OpenCode.MCP.Startup
  ( McpDiagnostic (..)
  , startMcp
  , mcpRegistryAdditions
  ) where

import Data.Text (Text)

import OpenCode.Config (Config (..), McpServerConfig (..))
import OpenCode.MCP.Adapters (clientSomeTools)
import OpenCode.MCP.Client (McpClient, connect, renderMcpError)
import OpenCode.Tool.Types (ToolRegistry, registerTool)

data McpDiagnostic = McpDiagnostic
  { mdServer :: Text, mdReason :: Text }
  deriving stock (Show, Eq)

-- | Connect every enabled server. Returns the live clients and a diagnostic per
-- server that failed (skipped). Never throws.
startMcp :: Config -> IO ([McpClient], [McpDiagnostic])
startMcp cfg = go (filter (mcsEnabled . snd) (mcpServers cfg)) [] []
  where
    go [] cs ds = pure (reverse cs, reverse ds)
    go ((name, sc) : rest) cs ds = do
      r <- connect name sc
      case r of
        Right c -> go rest (c : cs) ds
        Left e  -> go rest cs (McpDiagnostic name (renderMcpError e) : ds)

-- | Fold every client's tools into a registry.
mcpRegistryAdditions :: [McpClient] -> ToolRegistry -> ToolRegistry
mcpRegistryAdditions cs reg0 =
  foldr registerTool reg0 (concatMap clientSomeTools cs)
```

- [ ] **Step 5: Wire into `src/OpenCode/Run.hs`**

The cleanest seam is `withAppEnv`: spawn MCP servers there, put the clients in
`AppEnv`, merge their tools into the registry, and shut them down when the
continuation returns. But pure admin commands (`list`/`export`/`config check`)
must not spawn servers, so gate on the parsed command.

Change `runApp` to pass the command into env construction:

```haskell
runApp :: Tool.ToolRegistry -> IO ()
runApp registry = do
  args <- getArgs
  cmd  <- case args of
    [] -> pure (Run defaultRunOpts)
    _  -> handleParseResult (execParserPure defaultPrefs commandParserInfo args)
  withAppEnv registry (needsMcp cmd) $ \cfg env ->
    dispatch cfg env cmd `catches`
      [ Handler (\(e :: SQLError) -> dieT (renderDbError e))
      , Handler (\(DB.DBCorruption m) -> dieT ("database error: " <> m))
      ]

-- | Only agent-running commands spawn MCP servers.
needsMcp :: Command -> Bool
needsMcp (Run _) = True
needsMcp _       = False
```

Update `withAppEnv` to take that flag, spawn/merge/shutdown:

```haskell
import Control.Exception (Handler (Handler), SomeException, bracket, catches, try)
-- (add 'bracket' to the existing Control.Exception import)
import OpenCode.MCP.Startup (McpDiagnostic (..), startMcp, mcpRegistryAdditions)
import OpenCode.MCP.Client (McpClient, shutdown)

withAppEnv :: Tool.ToolRegistry -> Bool -> (Config -> AppEnv -> IO a) -> IO a
withAppEnv registry spawnMcp k = do
  cfgResult <- loadConfig
  case cfgResult of
    Left err  -> do
      hPutStrLn stderr ("opencode-hs: config error: " <> show err)
      exitFailure
    Right cfg -> do
      dbPath   <- DB.defaultDbPath
      conn     <- DB.openDb dbPath
      chan     <- BChan.newBChan 100
      abortVar <- STM.newTVarIO False
      (clients, diags) <- if spawnMcp then startMcp cfg else pure ([], [])
      reportMcpDiagnostics diags
      let registry' = mcpRegistryAdditions clients registry
          env = AppEnv
            { envConfig    = cfg
            , envDb        = conn
            , envRegistry  = registry'
            , envEventChan = chan
            , envAbort     = abortVar
            , envMcp       = clients
            }
      armed <- STM.newTVarIO False
      _ <- installHandler sigINT (Catch (onSigInt env armed)) Nothing
      bracket (pure clients) (mapM_ shutdown) (\_ -> k cfg env)

-- | MCP startup diagnostics go to stderr (visible in headless mode; harmless
-- before the TUI takes the screen).
reportMcpDiagnostics :: [McpDiagnostic] -> IO ()
reportMcpDiagnostics =
  mapM_ (\d -> TIO.hPutStrLn stderr
    ("opencode-hs: MCP server '" <> mdServer d <> "' unavailable: " <> mdReason d))
```

> Note: the spec also mentions a TUI startup banner. To keep this task focused
> and avoid threading diagnostics into `startTUI`, v1 reports all diagnostics to
> stderr (printed before the TUI starts). A richer in-chat banner is a future
> enhancement — record it in the spec's "Out of scope / future" if you prefer,
> or implement it by passing `diags` to `startTUI` and prepending an
> `ErrorPart` message to the initial state. **For this plan, stderr is the
> chosen behavior.**

- [ ] **Step 6: Run tests + build**

Run: `~/.ghcup/bin/stack test --fast`
Expected: all green (including the existing `RunSpec` — `withAppEnv` is internal;
its callers compile against the new arity). Then
`~/.ghcup/bin/stack build --fast --ghc-options -Werror` and `hlint src test`.

- [ ] **Step 7: Commit**

```bash
git add src/OpenCode/App/Types.hs src/OpenCode/MCP/Startup.hs src/OpenCode/Run.hs test/OpenCode/TestEnv.hs test/OpenCode/MCP/StartupSpec.hs package.yaml opencode-hs.cabal
git commit -m "$(printf 'M14: spawn MCP servers at run startup, merge tools, shutdown\n\nCo-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>')"
```

---

### Task 9: Autocomplete merge (dynamic prompt commands)

**Files:**
- Modify: `src/OpenCode/TUI/Command.hs` (`commandSuggestions` gains a dynamic-entries parameter)
- Modify: `test/OpenCode/TUI/CommandSpec.hs`
- Modify: `src/OpenCode/TUI/App.hs` (call sites + a `suggestEntries` helper)
- Modify: `src/OpenCode/TUI/Render.hs` (`suggestBox` call site)

- [ ] **Step 1: Write the failing test**

In `test/OpenCode/TUI/CommandSpec.hs`, update existing `commandSuggestions`
calls to pass `[]` as the new first argument, and add a sibling `describe` for
the merge:

```haskell
  describe "commandSuggestions with dynamic prompt entries" $ do
    let prompts = [("/srv_greet", "greet someone"), ("/srv_bye", "say bye")]

    it "includes prompts after built-ins for a bare slash" $
      map fst (commandSuggestions prompts "/")
        `shouldBe` ["/new", "/sessions", "/model", "/help", "/quit", "/srv_greet", "/srv_bye"]

    it "matches a prompt by prefix" $
      commandSuggestions prompts "/srv_g" `shouldBe` [("/srv_greet", "greet someone")]

    it "still returns [] for non-slash input" $
      commandSuggestions prompts "hello" `shouldBe` []
```

(Existing tests like `commandSuggestions "/" `shouldBe` …` become
`commandSuggestions [] "/" `shouldBe` …`.)

- [ ] **Step 2: Run to verify it fails**

Run: `~/.ghcup/bin/stack test --fast --ta '-m "commandSuggestions"'`
Expected: compile error — `commandSuggestions` applied to too many / wrong args.

- [ ] **Step 3: Implement the signature change in `Command.hs`**

```haskell
-- | Autocomplete matches for the current input line, merging the built-in
-- command catalog with @dynamic@ entries (e.g. MCP prompts) supplied by the
-- caller. Empty unless the trimmed input begins with @\/@; otherwise the rows
-- whose @\/name@ has the typed first token as a case-insensitive prefix.
commandSuggestions :: [(Text, Text)] -> Text -> [(Text, Text)]
commandSuggestions dynamic raw =
  case T.uncons trimmed of
    Just ('/', _) ->
      [ (name, desc)
      | (name, desc) <- allEntries
      , token `T.isPrefixOf` T.toLower name
      ]
    _ -> []
  where
    allEntries = [ (name, desc) | (_, name, desc) <- commandCatalog ] ++ dynamic
    trimmed    = T.strip raw
    token      = T.toLower firstWord
    firstWord  = case T.words trimmed of
      (w:_) -> w
      []    -> ""
```

The signature comment in the export list stays; `commandSuggestions` is already
exported.

- [ ] **Step 4: Update `App.hs` call sites**

Add imports:

```haskell
import OpenCode.App.Types (AppEnv (..))   -- envMcp; AppEnv already imported, ensure (..)
import OpenCode.MCP.Adapters (promptSuggestEntries)
```

Add a helper and route the existing reducers through it. Replace the bodies of
`suggestionsActive`, `highlightedCommand`, and `applySuggestMove` so they use a
single `suggestEntries`:

```haskell
-- | Autocomplete entries for the current state: built-ins + MCP prompts.
suggestEntries :: AppState -> [(Text, Text)]
suggestEntries st =
  commandSuggestions (promptSuggestEntries (envMcp (asEnv st))) (currentInput st)

suggestionsActive :: AppState -> Bool
suggestionsActive = not . null . suggestEntries

highlightedCommand :: AppState -> Maybe Text
highlightedCommand st = case suggestEntries st of
  [] -> Nothing
  xs -> fst <$> safeIndex xs (clampSel (length xs) (asSuggestSel st))

applySuggestMove :: Int -> AppState -> AppState
applySuggestMove delta st =
  st { asSuggestSel = clampSel n (asSuggestSel st + delta) }
  where n = length (suggestEntries st)
```

(`applyComplete` already calls `highlightedCommand`, so it picks up prompts for
free.)

- [ ] **Step 5: Update `Render.hs` `suggestBox`**

Add imports:

```haskell
import OpenCode.App.Types (AppEnv (..))
import OpenCode.MCP.Adapters (promptSuggestEntries)
```

Change the `case` scrutinee:

```haskell
suggestBox st =
  case commandSuggestions (promptSuggestEntries (envMcp (asEnv st))) (currentInputText st) of
    [] -> emptyWidget
    xs -> ...   -- unchanged body
```

- [ ] **Step 6: Run tests + build**

Run: `~/.ghcup/bin/stack test --fast`
Expected: all green (the dummy env has `envMcp = []`, so existing AppSpec/
RenderSpec autocomplete tests behave exactly as before). Then
`~/.ghcup/bin/stack build --fast --ghc-options -Werror` and `hlint src test`.

- [ ] **Step 7: Commit**

```bash
git add src/OpenCode/TUI/Command.hs src/OpenCode/TUI/App.hs src/OpenCode/TUI/Render.hs test/OpenCode/TUI/CommandSpec.hs
git commit -m "$(printf 'M14: merge MCP prompts into slash-command autocomplete\n\nCo-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>')"
```

---

### Task 10: TUI prompt invocation + `/prompts` overlay

**Files:**
- Modify: `src/OpenCode/TUI/Command.hs` (`CmdPrompts` + catalog entry)
- Modify: `src/OpenCode/TUI/Types.hs` (`OverlayPrompts` kind)
- Modify: `src/OpenCode/TUI/Overlay.hs` (`promptsOverlay`, `overlayCount`, `overlayLabels`)
- Modify: `src/OpenCode/TUI/App.hs` (prompt routing in `onEnter`, `invokePrompt`, overlay commit, `dispatchCommand`)
- Modify: `test/OpenCode/TUI/CommandSpec.hs`, `test/OpenCode/TUI/OverlaySpec.hs`

- [ ] **Step 1: Write the failing tests**

In `test/OpenCode/TUI/CommandSpec.hs`:

```haskell
    it "parses /prompts" $ parseCommand "/prompts" `shouldBe` Just CmdPrompts
```

In `test/OpenCode/TUI/OverlaySpec.hs`:

```haskell
  describe "promptsOverlay" $ do
    it "labels rows by full name and description" $ do
      let es = [ PromptEntry "srv_greet" "srv" "greet" "say hi" []
               , PromptEntry "srv_bye" "srv" "bye" "" [] ]
          ov = promptsOverlay es
      overlayLabels (ovKind ov) `shouldBe` ["srv_greet  say hi", "srv_bye"]
      overlayCount (ovKind ov)  `shouldBe` 2
```

Add imports to OverlaySpec:
`import OpenCode.MCP.Adapters (PromptEntry (..))`,
`import OpenCode.TUI.Overlay (promptsOverlay, overlayLabels, overlayCount)`,
`import OpenCode.TUI.Types (Overlay (..))`.

- [ ] **Step 2: Run to verify it fails**

Run: `~/.ghcup/bin/stack test --fast --ta '-m "promptsOverlay"'`
Expected: compile error — `CmdPrompts` / `promptsOverlay` not in scope.

- [ ] **Step 3: `Command.hs` — add `CmdPrompts`**

```haskell
data Command
  = CmdNew
  | CmdSessions
  | CmdModel
  | CmdHelp
  | CmdQuit
  | CmdPrompts        -- ^ @/prompts@ — pick an MCP prompt to run
  | CmdUnknown Text
  deriving stock (Show, Eq)
```

In `classify`, add the case (before `other`):

```haskell
      "/prompts"  -> CmdPrompts
```

In `commandCatalog`, add a row (after `/model`, before `/help`):

```haskell
  , (CmdPrompts,  "/prompts",  "run an MCP prompt")
```

> The help overlay derives from `commandCatalog`, and `T.justifyLeft 9` already
> pads names; `/prompts` is 8 chars, so alignment is fine.

- [ ] **Step 4: `Types.hs` — add the overlay kind**

Add the import and constructor:

```haskell
import OpenCode.MCP.Adapters (PromptEntry)
-- ...
data OverlayKind
  = OverlaySessions SessionId [Session]
  | OverlayModels   ModelId   [ModelId]
  | OverlayHelp     [Text]
  | OverlayPrompts  [PromptEntry]
  deriving stock (Show, Eq)
```

No cycle: `MCP.Adapters` imports `App.Types`, `Tool.Types`, `MCP.Client`,
`MCP.Protocol` — none import `TUI.Types`.

- [ ] **Step 5: `Overlay.hs` — handle the new kind**

Add import: `import OpenCode.MCP.Adapters (PromptEntry (..))`.

Extend `overlayCount`:

```haskell
overlayCount = \case
  OverlaySessions _ ss -> length ss
  OverlayModels   _ ms -> length ms
  OverlayHelp     ls   -> length ls
  OverlayPrompts  es   -> length es
```

Extend `overlayLabels`:

```haskell
overlayLabels = \case
  OverlaySessions cur ss -> map (sessionRow cur) ss
  OverlayModels   cur ms -> map (modelRow cur) ms
  OverlayHelp     ls     -> ls
  OverlayPrompts  es     -> map promptRow es
  where
    -- ... existing where-binds ...
    promptRow e
      | T.null (peDescription e) = peFullName e
      | otherwise                = peFullName e <> "  " <> peDescription e
```

Add the smart constructor + export it (`promptsOverlay` in the export list):

```haskell
-- | A picker over the discovered MCP prompts.
promptsOverlay :: [PromptEntry] -> Overlay
promptsOverlay es = Overlay
  { ovTitle = "prompts"
  , ovSel   = 0
  , ovKind  = OverlayPrompts es
  }
```

- [ ] **Step 6: `App.hs` — dispatch `/prompts`, route prompt lines, invoke**

Add imports:

```haskell
import OpenCode.MCP.Adapters
  ( PromptEntry (..), promptEntries, parsePromptInvocation, missingArgs )
import OpenCode.MCP.Client (McpClient (..), McpError, getPrompt, renderMcpError)
import OpenCode.MCP.Protocol (GetPromptResult (..), PromptMessage (..))
import Data.List (find)
```

In `dispatchCommand`, add the `CmdPrompts` case (it opens a picker, gated like
the other context commands so it doesn't fire mid-run):

```haskell
    CmdPrompts   -> whenIdle st (openPrompts st)
```

Add `openPrompts`:

```haskell
-- | /prompts: open a picker of all discovered MCP prompts.
openPrompts :: AppState -> EventM ResourceName AppState ()
openPrompts st = case concatMap promptEntries (envMcp (asEnv st)) of
  [] -> put st { asNotice = Just "no MCP prompts available" }
  es -> put st { asMode = ModeOverlay (promptsOverlay es) }
```

Import `promptsOverlay` from `OpenCode.TUI.Overlay` (extend that import line).

Add the overlay-commit case in `commitOverlay`:

```haskell
      OverlayPrompts es -> maybe (put st { asMode = ModeNormal })
                                 (\e -> selectPrompt e st { asNotice = Nothing })
                                 (safeIndex es i)
```

Add `selectPrompt` — no required args runs immediately; otherwise prefill the
input line so the user can type `key=value` args:

```haskell
-- | Commit an overlay prompt selection. No required args -> run now; otherwise
-- close the overlay and prefill the input with "/<fullName> " for the user to
-- add key=value arguments.
selectPrompt :: PromptEntry -> AppState -> EventM ResourceName AppState ()
selectPrompt e st
  | null (peRequiredArgs e) = invokePrompt e [] st { asMode = ModeNormal }
  | otherwise = put st
      { asMode  = ModeNormal
      , asInput = E.editorText InputEditor (Just 1) ("/" <> peFullName e <> " ")
      }
```

Route prompt-invocation lines in `onEnter` (check before `parseCommand`):

```haskell
onEnter :: EventM ResourceName AppState ()
onEnter = do
  st <- get
  let body = currentInput st
  case matchPrompt st body of
    Just (entry, args) -> invokePrompt entry args st
    Nothing -> case parseCommand body of
      Nothing ->
        when (asRunState st == Idle && shouldSubmit body) $ do
          msg <- liftIO (mkUserMessage body)
          put ((applyEnter msg st) { asRunState = RunningLLM, asNotice = Nothing })
          liftIO (startRun (asEnv st) (asSessionId st) body)
          M.vScrollToEnd chatScroll
      Just cmd -> do
        put st { asInput = emptyEditor, asNotice = Nothing }
        dispatchCommand cmd
```

> Note: `runHighlighted` (Enter while the autocomplete panel is open) calls
> `parseCommand name` on the highlighted entry. For a highlighted *prompt*
> name, `parseCommand` returns `CmdUnknown`. Fix `runHighlighted` to route
> through the prompt path too:

```haskell
runHighlighted :: EventM ResourceName AppState ()
runHighlighted = do
  st <- get
  case highlightedCommand st of
    Nothing   -> onEnter
    Just name -> do
      put st { asInput = E.editorText InputEditor (Just 1) name, asSuggestSel = 0 }
      onEnter
```

This sets the input to the highlighted name and reuses `onEnter`, so a prompt
name flows through `matchPrompt` and a built-in through `parseCommand`. (For a
prompt with required args, `matchPrompt`→`invokePrompt` will notice the missing
arg and show a notice, which is the desired behavior.)

Add `matchPrompt` and `invokePrompt`:

```haskell
-- | If the input is a known prompt invocation, resolve the entry + parsed args.
matchPrompt :: AppState -> Text -> Maybe (PromptEntry, [(Text, Text)])
matchPrompt st body = do
  (nm, args) <- parsePromptInvocation body
  entry      <- find ((== nm) . peFullName) (allPromptEntries st)
  pure (entry, args)

allPromptEntries :: AppState -> [PromptEntry]
allPromptEntries st = concatMap promptEntries (envMcp (asEnv st))

-- | Run an MCP prompt: validate required args, fetch via getPrompt, then submit
-- the combined message text as a user turn (reusing the normal run path so the
-- user message is persisted exactly as a typed one would be).
-- | Run an MCP prompt: validate required args, fetch via getPrompt, then submit
-- the combined message text as a user turn. Uses 'appendUserMessage' (which
-- appends unconditionally and clears the input) rather than 'applyEnter' — the
-- latter's 'shouldSubmit' guard would reject the cleared input. Persistence and
-- the run itself are reused from the normal typed-message path via 'startRun'.
invokePrompt :: PromptEntry -> [(Text, Text)] -> AppState -> EventM ResourceName AppState ()
invokePrompt entry args st = case missingArgs entry args of
  (m : _) -> put st { asInput = emptyEditor, asNotice = Just ("missing required arg: " <> m) }
  []      -> case find ((== peServer entry) . mcName) (envMcp (asEnv st)) of
    Nothing -> put st { asInput = emptyEditor, asNotice = Just "prompt server unavailable" }
    Just c  -> do
      result <- liftIO (try (getPrompt c (peName entry) args)
                          :: IO (Either SomeException (Either McpError GetPromptResult)))
      case result of
        Left ex        -> put st { asInput = emptyEditor
                                 , asNotice = Just ("prompt error: " <> T.pack (displayException ex)) }
        Right (Left e) -> put st { asInput = emptyEditor
                                 , asNotice = Just ("prompt error: " <> renderMcpError e) }
        Right (Right gp) ->
          let promptText = T.intercalate "\n\n" (map pmText (gprMessages gp))
          in if T.null (T.strip promptText)
               then put st { asInput = emptyEditor, asNotice = Just "prompt returned no content" }
               else do
                 msg <- liftIO (mkUserMessage promptText)
                 put ((appendUserMessage msg st)
                        { asRunState = RunningLLM, asNotice = Nothing, asSuggestSel = 0 })
                 liftIO (startRun (asEnv st) (asSessionId st) promptText)
                 M.vScrollToEnd chatScroll
```

Add the needed imports to `App.hs` if missing:
`import Control.Exception (SomeException, displayException, try)` (extend the
existing `Control.Exception` import). `appendUserMessage` is already defined and
exported in `App.hs`.

> v1 semantics: the returned prompt messages' text is concatenated into a single
> user turn and run. This reuses the typed-message persistence + run path
> exactly. (Role distinctions are ignored — MCP prompts almost always return
> user content.)

- [ ] **Step 7: Run tests + build**

Run: `~/.ghcup/bin/stack test --fast`
Expected: all green. The new pure tests (`/prompts` parse, `promptsOverlay`
labels) pass; existing AppSpec/RenderSpec/OverlaySpec behave unchanged (dummy
env has no prompts). Then `~/.ghcup/bin/stack build --fast --ghc-options -Werror`
and `hlint src test`.

- [ ] **Step 8: Manual smoke (optional, documented)**

Live key→action wiring is untestable (brick 2.x). Smoke it with a real or mock
MCP server in `~/.config/opencode-hs/config.yaml`, then:
`OPENCODE_MOCK=1 ~/.ghcup/bin/stack run opencode-hs` → type `/`, see prompts in
the panel; `/prompts` opens the picker; selecting a no-arg prompt runs it.

- [ ] **Step 9: Commit**

```bash
git add src/OpenCode/TUI/Command.hs src/OpenCode/TUI/Types.hs src/OpenCode/TUI/Overlay.hs src/OpenCode/TUI/App.hs test/OpenCode/TUI/CommandSpec.hs test/OpenCode/TUI/OverlaySpec.hs
git commit -m "$(printf 'M14: invoke MCP prompts from the TUI (/prompts + autocomplete)\n\nCo-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>')"
```

---

### Task 11: Docs + memory + milestone

**Files:**
- Modify: `README.md`
- Modify: `MILESTONES.md`
- Modify: `/Users/dodofk/.claude/projects/-Users-dodofk-Misc-opencode-hs/memory/project_opencode_hs.md`

- [ ] **Step 1: README — add an MCP section**

After the "## Slash commands" section, add:

```markdown
## MCP servers

`opencode-hs` can connect to external [Model Context Protocol](https://modelcontextprotocol.io)
servers over stdio and use their **tools**, **resources**, and **prompts**.

Configure servers in `~/.config/opencode-hs/config.yaml`:

```yaml
mcpServers:
  filesystem:
    command: npx
    args: ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"]
    env: { }          # optional, merged over the inherited environment
    enabled: true     # optional, default true
```

- **Tools** are exposed to the model namespaced as `<server>_<tool>` (e.g.
  `filesystem_read_file`).
- **Resources** are exposed as two tools per server: `<server>_list_resources`
  and `<server>_read_resource`.
- **Prompts** appear in the `/` autocomplete and the `/prompts` picker; invoke
  one with `/<server>_<prompt>` (add `key=value` arguments after the name).

Servers are started when a session runs (the TUI and `run`), and shut down on
exit. A server that fails to start is skipped with a message on stderr; the rest
of the app continues. The `list`, `export`, and `config check` commands do not
start any servers.
```

(Use the exact triple-backtick nesting your README already uses for fenced
blocks; the inner yaml block keeps its own fence.)

- [ ] **Step 2: MILESTONES — mark M14 done**

In the snapshot table, change the M14 row to:

```markdown
| M14 | MCP client (tools/resources/prompts)    | done      | `730a582..`        |
```

Replace the `## M14 — MCP client (sub-project B) — PLANNED` heading body with a
`— DONE` section summarizing: stdio JSON-RPC client (hand-rolled, no new deps);
`DynamicTool` path; tools + resource-tools merged into the registry at run
startup; prompts via `/` autocomplete + `/prompts`; graceful per-server failure;
in-repo mock server + integration test. Note M15 (skill system) is next and will
fold MCP prompts in as one skill source.

- [ ] **Step 3: Update project memory**

Append an M14 bullet to
`/Users/dodofk/.claude/projects/-Users-dodofk-Misc-opencode-hs/memory/project_opencode_hs.md`
(after the M13.1 bullet), recording: new modules `OpenCode.MCP.Protocol/Client/
Adapters/Startup`, the `DynamicTool` GADT tag, `Config.mcpServers`,
`AppEnv.envMcp`, the `opencode-mcp-mock` test executable, and that M15 is next.

- [ ] **Step 4: Final full verification**

Run, in order:
- `~/.ghcup/bin/stack build --fast --ghc-options -Werror` → clean
- `~/.ghcup/bin/stack test --fast` → 0 failures
- `hlint src test` → "No hints"

- [ ] **Step 5: Commit**

```bash
git add README.md MILESTONES.md
git commit -m "$(printf 'M14: document MCP servers; mark milestone done\n\nCo-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>')"
```

(The memory file is outside the repo; it is saved separately, not committed.)

---

## Spec coverage map

| Spec acceptance criterion | Task(s) |
|---|---|
| 1. Tools namespaced + callable; result as `ToolResultPart` | 2 (tag), 4 (client), 7 (adapter), 8 (merge) |
| 2. Resources → `_list_resources` / `_read_resource` | 7 (adapter), 8 (merge) |
| 3. Prompts in `/` autocomplete + `/prompts`; invoke → run | 7 (parse), 9 (autocomplete), 10 (overlay+invoke) |
| 4. Failing/missing server skipped; failing call → error part | 4 (Left paths), 7 (`failWith`), 8 (diagnostics) |
| 5. Admin commands spawn nothing; shutdown on exit | 8 (`needsMcp`, `bracket`) |
| 6. No new deps; `-Werror` + hlint clean; mock integration test | 3–7, every task's verify steps |

## Notes for the implementer

- **No new dependencies.** `process`, `aeson`, `bytestring`, `text`, `directory`,
  `filepath` are all already available. If a build complains a package isn't in
  the test stanza, it is already declared transitively via `opencode-hs`; only
  `test/mcp-mock` declares its own (aeson/bytestring/text).
- **hpack regenerates `opencode-hs.cabal`** on build; always `git add` it
  alongside `package.yaml`.
- **LambdaCase / OverloadedStrings:** `LambdaCase` is on project-wide. The new
  MCP modules use `OverloadedStrings` (added per-file as shown).
- **Import cycles:** the safe layering is
  `Protocol → Client`; `Client → {Config, Protocol}` (and is imported by
  `App.Types` for `envMcp`); `Adapters → {App.Error, Tool.Types, Client, Protocol}`;
  `TUI.Types → Adapters`. Never make `Client` import `App.Types`, and never make
  `Adapters` import any `TUI.*` module. (`Adapters` does **not** import
  `App.Types` — the tool executors' `AppM` type is fixed by the `SomeTool`
  field, so it's inferred without naming it.)
```

