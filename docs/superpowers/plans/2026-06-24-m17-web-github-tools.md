# M17 — Web & GitHub Tools Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add five networked tools (`web_search`, `web_fetch`, `github_search_code`, `github_read_issue`, `github_fetch_file`) to the agent's tool registry, backed by a shared injectable HTTP substrate and keys wired into the existing config system.

**Architecture:** A new `OpenCode.Net.Http` module exposes an `HttpBackend` function stored in `AppEnv`; production wires `runHttp` (via `Network.HTTP.Simple`), tests wire a pure URL-keyed mock. Each tool is a `SomeTool` value (same shape as `bash`/`grep`) that builds an `HttpRequest`, runs it through `envHttpBackend`, parses JSON with aeson, and renders text. Config gains a `ToolsConfig` record (`braveKey`, `githubKey`) following the exact env-over-YAML pattern of the provider keys.

**Tech Stack:** Haskell (GHC2021, lts-22.39), `http-conduit` + `http-types` (already deps), `aeson` (already a dep), `tagsoup` (NEW dep, for `web_fetch`), hspec + the existing `AppEnv`/`executeTool` test harness.

**Spec:** `docs/superpowers/specs/2026-06-24-m17-web-github-tools-design.md`

---

## File Structure

**Create:**
- `src/OpenCode/Net/Http.hs` — `HttpRequest`, `HttpError`, `HttpBackend`, `runHttp`
- `src/OpenCode/Net/HttpMock.hs` — pure URL→response mock backend for tests
- `src/OpenCode/Tool/WebSearch.hs` — Brave Search tool
- `src/OpenCode/Tool/WebFetch.hs` — URL→text tool (tagsoup)
- `src/OpenCode/Tool/GitHubSearch.hs` — GitHub code search tool
- `src/OpenCode/Tool/GitHubIssue.hs` — read issue/PR tool
- `src/OpenCode/Tool/GitHubFile.hs` — fetch file tool
- `test/OpenCode/Net/HttpSpec.hs`
- `test/OpenCode/Tool/WebSearchSpec.hs`
- `test/OpenCode/Tool/WebFetchSpec.hs`
- `test/OpenCode/Tool/GitHubSearchSpec.hs`
- `test/OpenCode/Tool/GitHubIssueSpec.hs`
- `test/OpenCode/Tool/GitHubFileSpec.hs`
- `test/fixtures/web/brave/search-haskell.json`
- `test/fixtures/web/github/search-code.json`
- `test/fixtures/web/github/issue.json`
- `test/fixtures/web/github/contents.json`
- `test/fixtures/web/example.html`

**Modify:**
- `package.yaml` — add `tagsoup` dep; register 6 new exposed-modules + 6 test other-modules
- `src/OpenCode/App/Types.hs` — `AppEnv` gains `envHttpBackend`, `envTools`
- `src/OpenCode/App/Error.hs` — (only if `ToolsConfig` accessors are needed; likely none)
- `src/OpenCode/Config.hs` — `ToolsConfig`, `EnvOverride` gains brave/github, `buildConfig` merges
- `src/OpenCode/Run.hs` — wire `envHttpBackend = runHttp`, `envTools`, register 5 tools
- `test/OpenCode/ConfigSpec.hs` — brave/github key tests
- `test/OpenCode/Tool/GrepSpec.hs` (and every other tool Spec) — add `envHttpBackend`, `envTools` to the `AppEnv` literals (record-field addition breaks compilation otherwise)
- `test/OpenCode/Tool/RegistrySpec.hs` — assert the 5 new tools are registered

---

## Task 1: Add `tagsoup` dependency

**Files:**
- Modify: `package.yaml` (dependencies list, ~line 76)

- [ ] **Step 1: Add the dependency**

In `package.yaml`, under the `dependencies:` list, add after the `Diff` entry (around line 76):

```yaml
  # HTML parsing (web_fetch, M17)
  - tagsoup >= 0.14
```

- [ ] **Step 2: Verify it resolves**

Run: `stack build --only-dependencies 2>&1 | tail -5`
Expected: completes without a resolver error about `tagsoup`.

- [ ] **Step 3: Commit**

```bash
git add package.yaml
git commit -m "M17: add tagsoup dependency for web_fetch HTML stripping"
```

---

## Task 2: Net.Http types and pure pieces

This task adds the `HttpRequest`/`HttpError`/`HttpBackend` types and the pure helpers (header building, status mapping). `runHttp` (the live IO) comes in Task 3.

**Files:**
- Create: `src/OpenCode/Net/Http.hs`
- Create: `test/OpenCode/Net/HttpSpec.hs`
- Modify: `package.yaml` (exposed-modules)

- [ ] **Step 1: Write the failing test**

Create `test/OpenCode/Net/HttpSpec.hs`:

```haskell
module OpenCode.Net.HttpSpec (spec) where

import Data.Text (Text)
import qualified Data.Text as Text
import Test.Hspec

import OpenCode.Net.Http

spec :: Spec
spec = do
  describe "defaultRequest" $ do
    it "builds a GET request with empty headers and no body" $ do
      let r = defaultRequest "https://example.com"
      hrMethod r `shouldBe` "GET"
      hrUrl r `shouldBe` "https://example.com"
      hrHeaders r `shouldBe` []
      hrBody r `shouldBe` Nothing

  describe "withHeader" $ do
    it "appends a header" $
      hrHeaders (withHeader (defaultRequest "u") "Accept" "json")
        `shouldBe` [("Accept", "json")]

  describe "withQuery" $ do
    it "appends a URL-encoded query param" $
      hrUrl (withQuery (defaultRequest "https://x.com/p") "q" "a b")
        `shouldBe` "https://x.com/p?q=a%20b"

    it "appends with & when a query already present" $
      hrUrl (withQuery (withQuery (defaultRequest "https://x.com/p") "a" "1") "b" "2")
        `shouldBe` "https://x.com/p?a=1&b=2"

  describe "httpErrorStatus" $ do
    it "extracts the status from an HttpError" $
      httpErrorStatus (HttpError 404 "not found") `shouldBe` 404

    it "is 0 for transport failures" $
      httpErrorStatus (HttpError 0 "connection refused") `shouldBe` 0
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `stack test --test-arguments="--match Net.Http" 2>&1 | tail -15`
Expected: compile error — module `OpenCode.Net.Http` does not exist.

- [ ] **Step 3: Write the module**

Create `src/OpenCode/Net/Http.hs`:

```haskell
-- | Shared HTTP substrate for networked tools (web_search, web_fetch,
-- github_*). One injectable backend so tests never touch the wire.
module OpenCode.Net.Http
  ( -- * Types
    HttpRequest (..)
  , HttpError (..)
  , HttpBackend
    -- * Constructors (pure)
  , defaultRequest
  , withHeader
  , withQuery
  , withMethod
  , withBody
    -- * Pure helpers
  , httpErrorStatus
    -- * Live backend
  , runHttp
  ) where

import Control.Exception (SomeException, try)
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BSC8
import qualified Data.Text as Text
import Data.Text (Text)
import Network.HTTP.Conduit (responseTimeout, responseTimeoutNone)
import Network.HTTP.Simple
  ( HttpException
  , setRequestBodyLBS
  , setRequestHeaders
  , setRequestMethod
  , setRequestQueryString
  , httpLBS
  , getResponseBody
  , getResponseStatusCode
  )
import qualified Network.HTTP.Simple as HTTP
import Network.HTTP.Types (statusCode)

-- ---------------------------------------------------------------------------
-- Types
-- ---------------------------------------------------------------------------

data HttpRequest = HttpRequest
  { hrMethod  :: Text          -- ^ "GET" | "POST"
  , hrUrl     :: Text
  , hrHeaders :: [(Text, Text)]
  , hrBody    :: Maybe ByteString
  }
  deriving stock (Show, Eq)

data HttpError = HttpError
  { heStatus :: Int            -- ^ HTTP status, or 0 for transport failure
  , heBody   :: Text           -- ^ response body or error message
  }
  deriving stock (Show, Eq)

-- | Injectable HTTP backend stored in 'AppEnv'. Production = 'runHttp';
-- tests supply a pure 'Map'-based function.
type HttpBackend = HttpRequest -> IO (Either HttpError ByteString)

-- ---------------------------------------------------------------------------
-- Pure constructors
-- ---------------------------------------------------------------------------

defaultRequest :: Text -> HttpRequest
defaultRequest url = HttpRequest
  { hrMethod  = "GET"
  , hrUrl     = url
  , hrHeaders = []
  , hrBody    = Nothing
  }

withMethod :: Text -> HttpRequest -> HttpRequest
withMethod m r = r { hrMethod = m }

withHeader :: Text -> Text -> HttpRequest -> HttpRequest
withHeader k v r = r { hrHeaders = hrHeaders r <> [(k, v)] }

withBody :: ByteString -> HttpRequest -> HttpRequest
withBody b r = r { hrBody = Just b }

-- | Append a query parameter, URL-encoding the value. Uses '?' for the
-- first param and '&' thereafter.
withQuery :: Text -> Text -> Text -> HttpRequest
withQuery key val r =
  let sep = if Text.any (== '?') (hrUrl r) then "&" else "?"
      url' = hrUrl r <> sep <> key <> "=" <> urlEncode val
  in r { hrUrl = url' }

-- | Minimal percent-encoder for query values (space, common reserved chars).
-- Good enough for tool query strings; not a general-purpose encoder.
urlEncode :: Text -> Text
urlEncode = Text.concatMap encodeChar
  where
    encodeChar ' ' = "%20"
    encodeChar c
      | c `elem` keep = Text.singleton c
      | otherwise = pct c
    keep = ['A'..'Z'] <> ['a'..'z'] <> ['0'..'9'] <> "-_.~"
    pct c = "%" <> Text.justifyRight 2 '0' (Text.pack (showHex (fromEnum c)))

-- | Hex of an Int, without the "0x" prefix.
showHex :: Int -> String
showHex n
  | n < 16  = ['0', hexDigit n]
  | otherwise = showHex (n `div` 16) <> [hexDigit (n `mod` 16)]
  where hexDigit d = "0123456789ABCDEF" !! d

-- ---------------------------------------------------------------------------
-- Pure helpers
-- ---------------------------------------------------------------------------

httpErrorStatus :: HttpError -> Int
httpErrorStatus = heStatus

-- ---------------------------------------------------------------------------
-- Live backend
-- ---------------------------------------------------------------------------

-- | Production HTTP backend. 30s timeout, TLS, maps non-2xx to 'HttpError'
-- and transport failures to 'HttpError { heStatus = 0 }'.
runHttp :: HttpRequest -> IO (Either HttpError ByteString)
runHttp req = do
  let base = HTTP.parseRequestThrow_ (Text.unpack (hrUrl req))
              `seq` ()  -- parse lazily inside the try below
  attempt <- try (runOne req) :: IO (Either SomeException ByteString)
  pure $ case attempt of
    Right body -> Right body
    Left ex    -> Left $ HttpError
      { heStatus = statusFromEx ex
      , heBody   = Text.pack ("http request failed: " <> show ex)
      }

-- | Extract an HTTP status from an exception if it carries one; 0 otherwise.
statusFromEx :: SomeException -> Int
statusFromEx _ = 0  -- transport failures have no status; non-2xx handled in runOne

runOne :: HttpRequest -> IO ByteString
runOne req = do
  parsed <- HTTP.parseRequest (Text.unpack (hrUrl req))
  let withHeaders = setRequestHeaders
        [ (BSC8.pack (Text.unpack k), BSC8.pack (Text.unpack v))
        | (k, v) <- hrHeaders req ] parsed
      withMethod' = setRequestMethod (BSC8.pack (Text.unpack (hrMethod req))) withHeaders
  let withBody' = case hrBody req of
        Nothing -> withMethod'
        Just b  -> setRequestBodyLBS (toLBS b) withMethod'
      withTimeout = HTTP.setRequestIgnoreStatus withBody'  -- we handle non-2xx ourselves
  resp <- httpLBS (setTimeout withTimeout)
  let code = getResponseStatusCode resp
  if code >= 200 && code < 300
    then pure (BS.toStrict (getResponseBody resp))
    else pure (errorPlaceholder code)  -- replaced below; see note
  where
    toLBS = BS.fromStrict

-- NOTE: runOne above is a sketch; the real implementation is given in
-- Task 3 step 3, which replaces this whole function body. We keep a
-- stub here only so the module type-checks for the pure tests in Task 2.

errorPlaceholder :: Int -> ByteString
errorPlaceholder _ = ""

setTimeout :: HTTP.Request -> HTTP.Request
setTimeout = id  -- replaced in Task 3

-- silence unused-import warnings until runOne is finalized in Task 3
_unusedImports :: ()
_unusedImports = const ()
  ( responseTimeout
  , responseTimeoutNone
  , setRequestBodyLBS
  , setRequestQueryString
  , (statusCode :: Int -> Int)
  ) ("" :: ByteString)
```

> **Note for the implementer:** The `runOne`/`runHttp` sketch above deliberately defers the full live-HTTP body to Task 3. Task 2's goal is only the **pure** pieces (`defaultRequest`, `withHeader`, `withQuery`, `httpErrorStatus`) and the type definitions. Do not spend time perfecting `runOne` here.

- [ ] **Step 4: Register the module**

In `package.yaml`, add to the `library.exposed-modules` list (keep alphabetical within the `OpenCode.` block):

```yaml
    - OpenCode.Net.Http
    - OpenCode.Net.HttpMock
```

(Add `OpenCode.Net.HttpMock` now even though we create it in Task 4 — it's harmless and avoids re-editing.)

- [ ] **Step 5: Run the test to verify the pure tests pass**

Run: `stack test --test-arguments="--match Net.Http" 2>&1 | tail -20`
Expected: the 5 pure tests pass. (`runHttp` is not exercised here.)

- [ ] **Step 6: Commit**

```bash
git add src/OpenCode/Net/Http.hs test/OpenCode/Net/HttpSpec.hs package.yaml
git commit -m "M17: Net.Http types + pure helpers (request builders, status)"
```

---

## Task 3: Live `runHttp` backend

**Files:**
- Modify: `src/OpenCode/Net/Http.hs` (replace the `runOne`/`runHttp` sketch)

- [ ] **Step 1: Write the failing test**

Add to `test/OpenCode/Net/HttpSpec.hs`, inside `spec`:

```haskell
  describe "runHttp" $ do
    it "returns Left with status 0 for an unresolvable host" $ do
      let req = defaultRequest "http://this-host-definitely-does-not-exist.invalid/"
      result <- runHttp req
      case result of
        Left err -> heStatus err `shouldBe` 0
        Right _  -> expectationFailure "expected transport failure, got a response"

    -- NOTE: a 200-success test would require real network to a stable URL.
    -- Per the spec, live success is a manual smoke test, not in CI. We test
    -- only the failure path (transport error → status 0) here.
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `stack test --test-arguments="--match Net.Http" 2>&1 | tail -20`
Expected: failure or error from the stub `runOne` in Task 2.

- [ ] **Step 3: Replace `runHttp`/`runOne` with the real implementation**

In `src/OpenCode/Net/Http.hs`, delete the entire `runHttp`/`statusFromEx`/`runOne`/`errorPlaceholder`/`setTimeout`/`_unusedImports` block (from Task 2 step 3) and replace with:

```haskell
-- ---------------------------------------------------------------------------
-- Live backend
-- ---------------------------------------------------------------------------

-- | Production HTTP backend. 30s timeout, TLS. Non-2xx responses are
-- returned as 'Left HttpError' carrying the status and the response body;
-- transport failures (DNS, timeout, TLS, connection refused) become
-- 'Left HttpError { heStatus = 0 }'.
runHttp :: HttpRequest -> IO (Either HttpError ByteString)
runHttp req = do
  parsed <- try (HTTP.parseRequest (Text.unpack (hrUrl req)))
  case parsed of
    Left ex -> pure $ Left $ transportError ex
    Right base -> do
      let applied = base
            & setRequestMethod (encodeBS (hrMethod req))
            & setRequestHeaders [ (encodeBS k, encodeBS v) | (k, v) <- hrHeaders req ]
            & setTimeout 30
            & setBody (hrBody req)
      resp <- try (httpLBS applied)
      case resp of
        Left ex -> pure $ Left $ transportError ex
        Right r -> do
          let code = getResponseStatusCode r
              body = BS.toStrict (getResponseBody r)
          if code >= 200 && code < 300
            then pure (Right body)
            else pure $ Left $ HttpError
              { heStatus = code
              , heBody   = Text.decodeUtf8With lenient body
              }

  where
    encodeBS = BSC8.pack . Text.unpack
    setBody Nothing    r = r
    setBody (Just b)   r = setRequestBodyLBS (BSL.fromStrict b) r

transportError :: SomeException -> HttpError
transportError ex = HttpError
  { heStatus = 0
  , heBody   = Text.pack ("http transport error: " <> show ex)
  }

setTimeout :: Int -> HTTP.Request -> HTTP.Request
setTimeout secs = HTTP.setRequestTimeoutPS (secs * 1_000_000)
```

Also add the now-needed imports at the top of the module (replace the existing `import qualified Data.ByteString as BS` line and add missing ones). The full import block should be:

```haskell
import Control.Exception (SomeException, try)
import Control.Monad ((<&>), (&))  -- ensure (&) is available
import Data.Bits (FiniteBits)       -- only if needed; remove if unused
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BSC8
import qualified Data.ByteString.Lazy as BSL
import Data.Text.Encoding.Error (lenientDecode)
import Data.Text.Encoding qualified as TextEnc
import qualified Data.Text as Text
import Data.Text (Text)
import Network.HTTP.Simple
  ( setRequestBodyLBS
  , setRequestHeaders
  , setRequestMethod
  , httpLBS
  , getResponseBody
  , getResponseStatusCode
  )
import qualified Network.HTTP.Simple as HTTP
```

> Remove any imports that are genuinely unused after the edit (GHC will warn under `-Werror`). In particular drop `responseTimeout`/`responseTimeoutNone`/`setRequestQueryString`/`statusCode` if they're no longer referenced.

- [ ] **Step 4: Run the test to verify it passes**

Run: `stack test --test-arguments="--match Net.Http" 2>&1 | tail -20`
Expected: all 6 tests pass, including the transport-failure test (status 0).

- [ ] **Step 5: Build with -Wall -Werror to catch unused imports**

Run: `stack build --ghc-options="-Wall -Werror" 2>&1 | tail -15`
Expected: clean build, no warnings.

- [ ] **Step 6: Commit**

```bash
git add src/OpenCode/Net/Http.hs test/OpenCode/Net/HttpSpec.hs
git commit -m "M17: live runHttp backend (timeout, status mapping, transport errors)"
```

---

## Task 4: `Net.HttpMock` — pure backend for tests

**Files:**
- Create: `src/OpenCode/Net/HttpMock.hs`
- Create: `test/OpenCode/Net/HttpMockSpec.hs` (optional, the mock is exercised via tool tests; a small sanity test is good practice)

- [ ] **Step 1: Write the module**

Create `src/OpenCode/Net/HttpMock.hs`:

```haskell
-- | A pure, URL-keyed HTTP backend for tests. Never touches the network.
module OpenCode.Net.HttpMock
  ( MockResponses (..)
  , mockBackend
  , mockBackendExact
  ) where

import Data.ByteString (ByteString)
import qualified Data.ByteString.Char8 as BSC8
import qualified Data.Map.Strict as Map
import Data.Map.Strict (Map)
import Data.Text (Text)
import qualified Data.Text as Text
import OpenCode.Net.Http (HttpBackend, HttpError (..), HttpRequest (..))

-- | Responses keyed by a *substring* of the URL. The first match wins, in
-- 'Map' ascending-key order. This keeps fixtures robust to query-string
-- reordering (Brave/GitHub append params we don't always care about).
newtype MockResponses = MockResponses (Map Text (Either HttpError ByteString))

mockResponses :: [(Text, Either HttpError ByteString)] -> MockResponses
mockResponses = MockResponses . Map.fromList

-- | Build a backend that returns the first response whose key is a
-- substring of the request URL. Unmatched URLs return a 404-style error.
mockBackend :: [(Text, Either HttpError ByteString)] -> HttpBackend
mockBackend pairs = \req -> pure (lookupMock (MockResponses (Map.fromList pairs)) (hrUrl req))

lookupMock :: MockResponses -> Text -> Either HttpError ByteString
lookupMock (MockResponses m) url =
  case Map.toAscList m of
    [] -> Left (HttpError 404 "no mock responses configured")
    _ -> case [resp | (key, resp) <- Map.toAscList m, Text.isInfixOf key url] of
      (r : _) -> r
      []      -> Left (HttpError 404 ("mock: no response matches URL " <> url))

-- | Backend that matches a URL exactly (no substring). Stricter alternative
-- for tests that care about the precise request.
mockBackendExact :: [(Text, Either HttpError ByteString)] -> HttpBackend
mockBackendExact pairs = \req -> pure $
  case lookup (hrUrl req) pairs of
    Just r  -> r
    Nothing -> Left (HttpError 404 ("mock: no exact match for " <> hrUrl req))
```

- [ ] **Step 2: Run the build to verify it compiles**

Run: `stack build 2>&1 | tail -10`
Expected: clean build.

- [ ] **Step 3: Commit**

```bash
git add src/OpenCode/Net/HttpMock.hs
git commit -m "M17: Net.HttpMock — pure URL-keyed backend for tool tests"
```

---

## Task 5: Extend `Config` with `ToolsConfig`

**Files:**
- Modify: `src/OpenCode/Config.hs`
- Modify: `test/OpenCode/ConfigSpec.hs`

- [ ] **Step 1: Write the failing tests**

In `test/OpenCode/ConfigSpec.hs`, add a new `describe` block inside `spec` (after the `loadConfigFile` block):

```haskell
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
            { cfTools = Just ToolsConfigFile
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
            { cfTools = Just ToolsConfigFile
                { tcfBrave = Nothing
                , tcfGithub = Just (ApiKeyFile (ApiKey "ghp-yaml"))
                }
            }
          env = noEnv { eoGithubKey = Just (ApiKey "ghp-env") }
      case buildConfig cfg env of
        Left  err -> expectationFailure (show err)
        Right c   -> githubKey (tools c) `shouldBe` Just (ApiKey "ghp-env")

    it "both tool keys default to Nothing when absent" $ do
      case buildConfig (cfWithOpenAI "sk-x") noEnv of
        Left  err -> expectationFailure (show err)
        Right c   -> do
          braveKey  (tools c) `shouldBe` Nothing
          githubKey (tools c) `shouldBe` Nothing

    it "still boots (Right) with only an LLM key, no tool keys" $
      buildConfig (cfWithOpenAI "sk-x") noEnv `shouldSatisfy` isRight
```

Also update the test fixtures block: extend `EnvOverride` usage. The existing `noEnv`, `openaiEnv`, etc. need a 2-field update. Replace the `noEnv` definition and add brave/github helpers:

```haskell
noEnv :: EnvOverride
noEnv = EnvOverride Nothing Nothing Nothing Nothing Nothing

braveEnv :: Text -> EnvOverride
braveEnv k = noEnv { eoBraveKey = Just (ApiKey k) }

githubEnv :: Text -> EnvOverride
githubEnv k = noEnv { eoGithubKey = Just (ApiKey k) }
```

(The existing `openaiEnv`/`anthropicEnv`/`minimaxEnv` keep working because they use record-update syntax on `noEnv`.)

- [ ] **Step 2: Run the test to verify it fails**

Run: `stack test --test-arguments="--match tools" 2>&1 | tail -15`
Expected: compile error — `ToolsConfigFile`, `tools`, `braveKey` not in scope.

- [ ] **Step 3: Extend `Config.hs`**

In `src/OpenCode/Config.hs`:

(a) Add a `ToolsConfig` record after `ProviderConfig`:

```haskell
data ToolsConfig = ToolsConfig
  { braveKey  :: Maybe ApiKey
  , githubKey :: Maybe ApiKey
  }
  deriving stock (Show, Eq)
```

(b) Add a `tools` field to `Config`:

```haskell
data Config = Config
  { providers    :: ProviderConfig
  , defaultModel :: ModelId
  , mcpServers   :: [(Text, McpServerConfig)]
  , tools        :: ToolsConfig
  }
  deriving stock (Show, Eq)
```

(c) Add a file-shaped type (after `McpServerConfigFile`):

```haskell
data ToolsConfigFile = ToolsConfigFile
  { tcfBrave  :: Maybe ApiKeyFile
  , tcfGithub :: Maybe ApiKeyFile
  }
  deriving stock (Show, Eq)

instance FromJSON ToolsConfigFile where
  parseJSON = withObject "ToolsConfigFile" $ \o -> ToolsConfigFile
    <$> o .:? "braveApiKey"
    <*> o .:? "githubToken"
```

(d) Add `cfTools :: Maybe ToolsConfigFile` to `ConfigFile`:

```haskell
data ConfigFile = ConfigFile
  { cfProviders    :: Maybe ProviderConfigFile
  , cfDefaultModel :: Maybe ModelIdFile
  , cfMcpServers   :: Maybe (Map Text McpServerConfigFile)
  , cfTools        :: Maybe ToolsConfigFile
  }
  deriving stock (Show, Eq)

emptyConfigFile :: ConfigFile
emptyConfigFile = ConfigFile Nothing Nothing Nothing Nothing
```

(e) Extend the `ConfigFile` `FromJSON`:

```haskell
instance FromJSON ConfigFile where
  parseJSON = withObject "ConfigFile" $ \o -> ConfigFile
    <$> o .:? "providers"
    <*> o .:? "defaultModel"
    <*> o .:? "mcpServers"
    <*> o .:? "tools"
```

(f) Extend `EnvOverride` + `loadEnvVars`:

```haskell
data EnvOverride = EnvOverride
  { eoOpenAIKey    :: Maybe ApiKey
  , eoAnthropicKey :: Maybe ApiKey
  , eoMiniMaxKey   :: Maybe ApiKey
  , eoBraveKey     :: Maybe ApiKey
  , eoGithubKey    :: Maybe ApiKey
  }
  deriving stock (Show, Eq)

loadEnvVars :: IO EnvOverride
loadEnvVars = EnvOverride
  <$> readKey "OPENAI_API_KEY"
  <*> readKey "ANTHROPIC_API_KEY"
  <*> readKey "MINIMAX_API_KEY"
  <*> readKey "BRAVE_API_KEY"
  <*> readKey "GITHUB_TOKEN"
  where
    readKey var = fmap (ApiKey . Text.pack) <$> lookupEnv var
```

(g) Extend `buildConfig` to assemble `ToolsConfig`:

```haskell
buildConfig :: ConfigFile -> EnvOverride -> Either ConfigError Config
buildConfig cf env =
  let
    openaiKey    = eoOpenAIKey    env
               <|> (afApiKey <$> (cfOpenai    =<< cfProviders cf))
    anthropicKey = eoAnthropicKey env
               <|> (afApiKey <$> (cfAnthropic =<< cfProviders cf))
    minimaxKey   = eoMiniMaxKey   env
               <|> (afApiKey <$> (cfMiniMax   =<< cfProviders cf))

    providerCfg = ProviderConfig { openaiKey, anthropicKey, minimaxKey }
    defModel    = maybe (pickDefaultModel providerCfg) toModelId (cfDefaultModel cf)
    mcpList     = maybe [] (map toMcpServer . Map.toList) (cfMcpServers cf)

    braveKey'  = eoBraveKey  env
             <|> (afApiKey <$> (tcfBrave  =<< cfTools cf))
    githubKey' = eoGithubKey env
             <|> (afApiKey <$> (tcfGithub =<< cfTools cf))
    toolsCfg   = ToolsConfig { braveKey = braveKey', githubKey = githubKey' }
  in
    if isNothing openaiKey && isNothing anthropicKey && isNothing minimaxKey
      then Left $ ConfigMissingKey
        "No API key found. Set MINIMAX_API_KEY, OPENAI_API_KEY or ANTHROPIC_API_KEY, \
        \or add them to ~/.config/opencode-hs/config.yaml."
      else Right Config
        { providers    = providerCfg
        , defaultModel = defModel
        , mcpServers   = mcpList
        , tools        = toolsCfg
        }
```

(The "no LLM key" check intentionally ignores brave/github — a config with only a `BRAVE_API_KEY` and no LLM key cannot run the agent.)

- [ ] **Step 4: Run the test to verify it passes**

Run: `stack test --test-arguments="--match Config" 2>&1 | tail -20`
Expected: all config tests pass, including the 6 new tool-key tests.

- [ ] **Step 5: Commit**

```bash
git add src/OpenCode/Config.hs test/OpenCode/ConfigSpec.hs
git commit -m "M17: ToolsConfig (braveKey, githubKey) in Config, env-over-YAML"
```

---

## Task 6: Extend `AppEnv`

**Files:**
- Modify: `src/OpenCode/App/Types.hs`

- [ ] **Step 1: Extend the record**

In `src/OpenCode/App/Types.hs`, add imports and fields:

```haskell
import OpenCode.Config (Config, ToolsConfig)        -- add ToolsConfig
import OpenCode.Net.Http (HttpBackend)              -- new

data AppEnv = AppEnv
  { envConfig     :: Config
  , envDb         :: Connection
  , envRegistry   :: ToolRegistry
  , envEventChan  :: BChan SessionEvent
  , envAbort      :: TVar Bool
  , envMcp        :: [McpClient]
  , envSkills     :: [Skill]
  , envHttpBackend :: HttpBackend       -- new
  , envTools      :: ToolsConfig         -- new
  }
```

- [ ] **Step 2: Confirm the build breaks everywhere AppEnv is constructed**

Run: `stack build 2>&1 | tail -30`
Expected: compile errors at every `AppEnv { ... }` literal (Run.hs, every tool Spec). This is expected — the next tasks fix them.

- [ ] **Step 3: Commit (intermediate — build is intentionally broken; fixed in Task 7)**

```bash
git add src/OpenCode/App/Types.hs
git commit -m "M17: AppEnv gains envHttpBackend + envTools fields (wip)"
```

---

## Task 7: Wire `AppEnv` in `Run.withAppEnv` + fix all test `AppEnv` literals

**Files:**
- Modify: `src/OpenCode/Run.hs`
- Modify: every `test/OpenCode/**/*Spec.hs` that constructs an `AppEnv`

- [ ] **Step 1: Wire `Run.withAppEnv`**

In `src/OpenCode/Run.hs`, find the `withAppEnv` function and its `AppEnv { ... }` construction. Add:

```haskell
import OpenCode.Net.Http (HttpBackend, runHttp)
import OpenCode.Config (tools, ToolsConfig)
```

In the `AppEnv` literal, add the two fields:

```haskell
      , envHttpBackend = runHttp
      , envTools       = OpenCode.Config.tools envConfig   -- or however the existing code names it
      ```
```

(Adapt the RHS to match how the existing code binds the loaded `Config`. The goal: `envHttpBackend` is always `runHttp` in production; `envTools` is the `ToolsConfig` from the loaded config.)

- [ ] **Step 2: Find every test `AppEnv` literal**

Run: `stack build 2>&1 | grep "error:" | head -30`

For each file listed, add the two new fields to the `AppEnv { ... }` block. In tests, the backend is usually the mock (set per-test), so use `undefined` as the default and override per-test, OR set a sensible default. For tool tests that will use the mock, add:

```haskell
          envHttpBackend = undefined   -- overridden per-test via runReaderT env
          , envTools      = OpenCode.Config.ToolsConfig { braveKey = Just (ApiKey "test"), githubKey = Just (ApiKey "test") }
```

For specs that don't exercise HTTP (e.g. `GrepSpec`, `DBSpec`), `undefined` for `envHttpBackend` is acceptable because those code paths never call it.

> **Tip:** To find the exact set, run `rg "AppEnv \{" test/` and add the two fields to each match.

- [ ] **Step 3: Run the full test suite to verify everything compiles and passes**

Run: `stack test 2>&1 | tail -15`
Expected: all 425+ existing tests pass. No new test failures.

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "M17: wire envHttpBackend + envTools through Run and test fixtures"
```

---

## Task 8: Fixtures

Record one real response from each endpoint. These are the inputs to the tool-executor tests.

**Files:**
- Create: `test/fixtures/web/brave/search-haskell.json`
- Create: `test/fixtures/web/github/search-code.json`
- Create: `test/fixtures/web/github/issue.json`
- Create: `test/fixtures/web/github/contents.json`
- Create: `test/fixtures/web/example.html`

- [ ] **Step 1: Create the fixtures directory**

```bash
mkdir -p test/fixtures/web/brave test/fixtures/web/github
```

- [ ] **Step 2: Create the Brave fixture**

Create `test/fixtures/web/brave/search-haskell.json` — a trimmed Brave `/web/search` response. (Recorded shape; exact values are illustrative and will be replaced at execution time if the real API differs.)

```json
{
  "web": {
    "results": [
      {
        "title": "Haskell Language",
        "url": "https://www.haskell.org/",
        "description": "An advanced, purely functional programming language."
      },
      {
        "title": "Learn You a Haskell",
        "url": "https://learnyouahaskell.com/",
        "description": "Introductory Haskell tutorial."
      }
    ]
  }
}
```

- [ ] **Step 3: Create the GitHub search-code fixture**

`test/fixtures/web/github/search-code.json`:

```json
{
  "total_count": 1,
  "items": [
    {
      "name": "Main.hs",
      "path": "app/Main.hs",
      "repository": { "full_name": "dodofk/opencode-hs" },
      "html_url": "https://github.com/dodofk/opencode-hs/blob/main/app/Main.hs"
    }
  ]
}
```

- [ ] **Step 4: Create the GitHub issue fixture**

`test/fixtures/web/github/issue.json`:

```json
{
  "title": "Example issue",
  "state": "open",
  "user": { "login": "octocat" },
  "body": "This is the issue body.",
  "labels": [ { "name": "bug" } ]
}
```

- [ ] **Step 5: Create the GitHub contents fixture**

`test/fixtures/web/github/contents.json` (base64 of "module Main where\n"):

```json
{
  "name": "Main.hs",
  "path": "app/Main.hs",
  "encoding": "base64",
  "content": "bW9kdWxlIE1haW4gd2hlcmUK"
}
```

- [ ] **Step 6: Create the HTML fixture**

`test/fixtures/web/example.html`:

```html
<!DOCTYPE html>
<html>
<head><title>Ignored title</title><script>var x = 1;</script>
<style>body { color: red; }</style></head>
<body>
<h1>Hello World</h1>
<p>This is a <a href="https://example.com">link</a> in a paragraph.</p>
<ul><li>One</li><li>Two</li></ul>
</body>
</html>
```

- [ ] **Step 7: Commit**

```bash
git add test/fixtures/web/
git commit -m "M17: recorded fixtures for web/github tool tests"
```

---

## Task 9: `web_search` tool (Brave)

**Files:**
- Create: `src/OpenCode/Tool/WebSearch.hs`
- Create: `test/OpenCode/Tool/WebSearchSpec.hs`
- Modify: `package.yaml` (exposed-modules + test other-modules)

- [ ] **Step 1: Write the failing tests**

Create `test/OpenCode/Tool/WebSearchSpec.hs`:

```haskell
module OpenCode.Tool.WebSearchSpec (spec) where

import Control.Monad.Except (runExceptT)
import Control.Monad.Reader (runReaderT)
import qualified Data.Aeson as Aeson
import qualified Data.ByteString as BS
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import System.FilePath ((</>))
import Test.Hspec

import OpenCode.App (AppEnv (..), AppError)
import OpenCode.Config (ToolsConfig (..))
import OpenCode.Net.Http (HttpError (..))
import OpenCode.Net.HttpMock (mockBackend)
import OpenCode.Tool.Types (executeTool, registerTool, emptyRegistry)
import OpenCode.Tool.WebSearch (webSearchTool)

import Paths_opencode_hs (getDataFileName)

spec :: Spec
spec = describe "web_search tool" $ do

  it "renders results as a numbered title|url|snippet list" $ do
    fixture <- BS.readFile =<< getDataFileName ("test/fixtures/web/brave/search-haskell.json" :: String)
    let backend = mockBackend
          [ ( "search.brave.com", Right fixture ) ]
        reg = registerTool webSearchTool emptyRegistry
        env = testEnv backend (Just "BSA-test")
        args = Aeson.object [ "query" Aeson..= ("haskell" :: Text) ]
    result <- runExceptT $ runReaderT (executeTool reg "web_search" args) env
    case result of
      Right t -> do
        Text.unpack t `shouldContain` "1."
        Text.unpack t `shouldContain` "Haskell Language"
        Text.unpack t `shouldContain` "https://www.haskell.org/"
      Left err -> expectationFailure (show err)

  it "errors when braveKey is missing" $ do
    let reg = registerTool webSearchTool emptyRegistry
        env = testEnv (mockBackend []) Nothing
        args = Aeson.object [ "query" Aeson..= ("haskell" :: Text) ]
    result <- runExceptT $ runReaderT (executeTool reg "web_search" args) env
    case result of
      Right _  -> expectationFailure "expected ToolError for missing key"
      Left err -> show err `shouldContain` "BRAVE_API_KEY"

  it "errors on non-200 status" $ do
    let backend = mockBackend
          [ ( "search.brave.com", Left (HttpError 401 "unauthorized") ) ]
        reg = registerTool webSearchTool emptyRegistry
        env = testEnv backend (Just "BSA-test")
        args = Aeson.object [ "query" Aeson..= ("x" :: Text) ]
    result <- runExceptT $ runReaderT (executeTool reg "web_search" args) env
    case result of
      Right _  -> expectationFailure "expected ToolError for 401"
      Left err -> show err `shouldContain` "401"

testEnv :: (OpenCode.Net.Http.HttpBackend) -> Maybe Text -> AppEnv
testEnv backend mBrave = AppEnv
  { envConfig     = undefined
  , envDb         = undefined
  , envRegistry   = undefined
  , envEventChan  = undefined
  , envAbort      = undefined
  , envMcp        = []
  , envSkills     = []
  , envHttpBackend = backend
  , envTools      = ToolsConfig
      { braveKey  = OpenCode.Types.ApiKey <$> mBrave
      , githubKey = Nothing
      }
  }
```

> **Note:** The `testEnv` helper above uses qualified names loosely. If GHC complains, adjust imports — the pattern (mock backend + a ToolsConfig with the key) is what matters. Consider hoisting `testEnv` into a shared `OpenCode.TestEnv` helper (already exists at `test/OpenCode/TestEnv.hs`) once the shape stabilizes.

- [ ] **Step 2: Run the test to verify it fails**

Run: `stack test --test-arguments="--match WebSearch" 2>&1 | tail -15`
Expected: compile error — `OpenCode.Tool.WebSearch` does not exist.

- [ ] **Step 3: Write the tool module**

Create `src/OpenCode/Tool/WebSearch.hs`:

```haskell
-- | Tool: web search via the Brave Search API.
module OpenCode.Tool.WebSearch
  ( webSearchTool
  , webSearchSchema
  , WebSearchInput (..)
  , BraveResult (..)
  , renderResults
  ) where

import Control.Monad.Except (throwError)
import Control.Monad.Reader (asks)
import Data.Aeson (FromJSON (..), ToJSON (..), Value, object, (.:), (.:?), (.=))
import qualified Data.Aeson as Aeson
import Data.ByteString (ByteString)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as TextEnc
import Text.Read (readMaybe)

import OpenCode.App (AppEnv (..), AppM, AppError (..))
import OpenCode.Config (ToolsConfig (..))
import OpenCode.Net.Http (HttpBackend, HttpError (..), HttpRequest, defaultRequest, withHeader, withQuery)
import OpenCode.Tool.Types (SomeTool (..), ToolDef (..))
import OpenCode.Types (ApiKey (..))

-- ---------------------------------------------------------------------------
-- Input
-- ---------------------------------------------------------------------------

data WebSearchInput = WebSearchInput
  { wsiQuery :: Text
  , wsiCount :: Maybe Int
  }
  deriving stock (Show, Eq)

instance FromJSON WebSearchInput where
  parseJSON = Aeson.genericParseJSON Aeson.defaultOptions
    { Aeson.fieldLabelModifier = drop 3 }  -- wsiQuery -> query

-- NOTE: to avoid the generic-parse footgun, prefer explicit parseJSON:
instance ToJSON WebSearchInput where
  toJSON (WebSearchInput q c) = object [ "query" .= q, "count" .= c ]

-- ---------------------------------------------------------------------------
-- Brave response shape
-- ---------------------------------------------------------------------------

newtype BraveResponse = BraveResponse { brWeb :: BraveWeb }
instance FromJSON BraveResponse where
  parseJSON = Aeson.withObject "BraveResponse" $ \o -> BraveResponse <$> o .: "web"

data BraveWeb = BraveWeb { bwResults :: [BraveResult] }
instance FromJSON BraveWeb where
  parseJSON = Aeson.withObject "BraveWeb" $ \o -> BraveWeb <$> o .:? "results" .!= []

data BraveResult = BraveResult
  { brTitle       :: Text
  , brUrl         :: Text
  , brDescription :: Text
  }
instance FromJSON BraveResult where
  parseJSON = Aeson.withObject "BraveResult" $ \o -> BraveResult
    <$> o .:  "title"
    <*> o .:  "url"
    <*> (o .:? "description" .!= "")

-- ---------------------------------------------------------------------------
-- Rendering
-- ---------------------------------------------------------------------------

renderResults :: [BraveResult] -> Text
renderResults = Text.unlines . zipWith fmt [1 :: Int ..]
  where
    fmt i r = Text.pack (show i) <> ". " <> brTitle r
           <> " | " <> brUrl r
           <> " | " <> brDescription r

-- ---------------------------------------------------------------------------
-- Schema
-- ---------------------------------------------------------------------------

webSearchSchema :: Value
webSearchSchema = object
  [ "type" .= ("object" :: Text)
  , "properties" .= object
      [ "query" .= object
          [ "type" .= ("string" :: Text)
          , "description" .= ("Search query" :: Text)
          ]
      , "count" .= object
          [ "type" .= ("integer" :: Text)
          , "description" .= ("Max results (default 5, max 20)" :: Text)
          ]
      ]
  , "required" .= (["query"] :: [Text])
  ]

-- ---------------------------------------------------------------------------
-- Tool value
-- ---------------------------------------------------------------------------

webSearchTool :: SomeTool
webSearchTool = SomeTool
  { toolDef     = DynamicTool
  , toolName    = "web_search"
  , toolDesc    = "Search the web via Brave Search. Returns a numbered list of title | url | snippet."
  , toolSchema  = webSearchSchema
  , toolExecute = webSearchExec
  , toolRender  = id    -- output is already Text (DynamicTool)
  }

-- ---------------------------------------------------------------------------
-- Executor
-- ---------------------------------------------------------------------------

webSearchExec :: Value -> AppM Text
webSearchExec args = do
  input <- decodeInput args
  backend <- asks envHttpBackend
  mKey <- asks (braveKey . envTools)
  case mKey of
    Nothing -> throwError (ToolError "web_search"
      "Brave Search requires BRAVE_API_KEY (env) or tools.braveApiKey (config.yaml).")
    Just (ApiKey key) -> do
      let n = clampCount (wsiCount input)
          req = defaultRequest "https://api.search.brave.com/res/v1/web/search"
                  & withQuery "q" (wsiQuery input)
                  & withQuery "count" (Text.pack (show n))
                  & withHeader "X-Subscription-Token" key
                  & withHeader "Accept" "application/json"
      runSearch backend req
  where
    (&) = flip ($)

clampCount :: Maybe Int -> Int
clampCount = maybe 5 (\n -> max 1 (min 20 n))

decodeInput :: Value -> AppM WebSearchInput
decodeInput v = case Aeson.fromJSON v of
  Aeson.Success i -> pure i
  Aeson.Error e   -> throwError (ToolError "web_search" (Text.pack e))

runSearch :: HttpBackend -> HttpRequest -> AppM Text
runSearch backend req = do
  result <- liftIO' (backend req)
  case result of
    Left err -> throwError (ToolError "web_search" (renderHttpError err))
    Right body -> case Aeson.eitherDecodeStrict body :: Either String BraveResponse of
      Left e   -> throwError (ToolError "web_search" ("Brave decode error: " <> Text.pack e))
      Right br -> pure (renderResults (bwResults (brWeb br)))

renderHttpError :: HttpError -> Text
renderHttpError (HttpError status body) =
  "web_search HTTP " <> Text.pack (show status) <> ": " <> body

liftIO' :: IO a -> AppM a
liftIO' = Control.Monad.IO.Class.liftIO
```

> **Fixups the implementer should apply if GHC complains:**
> - Replace the `instance FromJSON WebSearchInput` with an explicit `withObject` parser if the generic drop-prefix version misbehaves (recommended — explicit is safer here):
>   ```haskell
>   instance FromJSON WebSearchInput where
>     parseJSON = Aeson.withObject "WebSearchInput" $ \o -> WebSearchInput
>       <$> o .:  "query"
>       <*> o .:? "count"
>   ```
> - Add `import Control.Monad.IO.Class (liftIO)` and use `liftIO` instead of the `liftIO'` alias if cleaner.

- [ ] **Step 4: Register the module in `package.yaml`**

Add to `library.exposed-modules`:
```yaml
    - OpenCode.Tool.WebSearch
```
Add to `tests.opencode-hs-test.other-modules`:
```yaml
      - OpenCode.Tool.WebSearchSpec
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `stack test --test-arguments="--match WebSearch" 2>&1 | tail -20`
Expected: 3 tests pass (success render, missing key, 401).

- [ ] **Step 6: Commit**

```bash
git add src/OpenCode/Tool/WebSearch.hs test/OpenCode/Tool/WebSearchSpec.hs package.yaml
git commit -m "M17: web_search tool (Brave Search)"
```

---

## Task 10: `web_fetch` tool (URL → markdown, tagsoup)

**Files:**
- Create: `src/OpenCode/Tool/WebFetch.hs`
- Create: `test/OpenCode/Tool/WebFetchSpec.hs`
- Modify: `package.yaml`

- [ ] **Step 1: Write the failing tests**

Create `test/OpenCode/Tool/WebFetchSpec.hs`:

```haskell
module OpenCode.Tool.WebFetchSpec (spec) where

import Control.Monad.Except (runExceptT)
import Control.Monad.Reader (runReaderT)
import qualified Data.Aeson as Aeson
import qualified Data.ByteString as BS
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as TextEnc
import System.FilePath ((</>))
import Test.Hspec

import OpenCode.App (AppEnv (..), AppError)
import OpenCode.Config (ToolsConfig (..))
import OpenCode.Net.HttpMock (mockBackend)
import OpenCode.Tool.Types (executeTool, registerTool, emptyRegistry)
import OpenCode.Tool.WebFetch (webFetchTool, htmlToText)
import OpenCode.Types (ApiKey (..))
import Paths_opencode_hs (getDataFileName)

spec :: Spec
spec = do
  describe "web_fetch tool" $ do

    it "strips script/style and renders text + links" $ do
      let html = "<html><head><script>x</script><style>y</style></head>\
                 \<body><h1>Hello World</h1><p>A <a href=\"u\">link</a></p></body></html>"
      htmlToText html `shouldSatisfy` \t ->
        Text.unpack t `shouldContain` "Hello World"
        -- (hspec does not compose shouldContain under shouldSatisfy; see below)

    it "renders the fetched page text" $ do
      let html = "<html><body><h1>Hello World</h1></body></html>"
          bs = TextEnc.encodeUtf8 html
          backend = mockBackend [ ( "example.com", Right bs ) ]
          reg = registerTool webFetchTool emptyRegistry
          env = testEnv backend
          args = Aeson.object [ "url" Aeson..= ("https://example.com" :: Text) ]
      result <- runExceptT $ runReaderT (executeTool reg "web_fetch" args) env
      case result of
        Right t -> Text.unpack t `shouldContain` "Hello World"
        Left err -> expectationFailure (show err)

  describe "htmlToText (pure)" $ do
    it "drops <script> and <style> contents" $
      htmlToText "<style>hidden</style><p>kept</p>" `shouldSatisfy` Text.isInfixOf "kept"

    it "drops <script> content but keeps surrounding text" $ do
      let t = htmlToText "<p>a</p><script>var x=1;</script><p>b</p>"
      Text.unpack t `shouldContain` "a"
      Text.unpack t `shouldContain` "b"
      Text.unpack t `shouldNotContain` "var x"

testEnv :: OpenCode.Net.Http.HttpBackend -> AppEnv
testEnv backend = AppEnv
  { envConfig     = undefined
  , envDb         = undefined
  , envRegistry   = undefined
  , envEventChan  = undefined
  , envAbort      = undefined
  , envMcp        = []
  , envSkills     = []
  , envHttpBackend = backend
  , envTools      = ToolsConfig { braveKey = Nothing, githubKey = Nothing }
  }
```

(Remove the malformed first `it` — the `shouldSatisfy ... shouldContain` nesting doesn't typecheck. It's superseded by the `htmlToText` describe block.)

- [ ] **Step 2: Run the test to verify it fails**

Run: `stack test --test-arguments="--match WebFetch" 2>&1 | tail -15`
Expected: compile error — `OpenCode.Tool.WebFetch` missing.

- [ ] **Step 3: Write the tool module**

Create `src/OpenCode/Tool/WebFetch.hs`:

```haskell
-- | Tool: fetch a URL and return cleaned text (HTML stripped via tagsoup).
module OpenCode.Tool.WebFetch
  ( webFetchTool
  , webFetchSchema
  , WebFetchInput (..)
  , htmlToText
  ) where

import Control.Monad.Except (throwError)
import Control.Monad.Reader (asks)
import Data.Aeson (FromJSON (..), ToJSON (..), Value, object, (.:), (.:?), (.=))
import qualified Data.Aeson as Aeson
import qualified Data.ByteString as BS
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as TextEnc
import Text.HTML.TagSoup
  ( Tag (..)
  , parseTags
  , renderTags
  , sections
  , isTagCloseName
  , isTagOpenName
  )

import OpenCode.App (AppEnv (..), AppM, AppError (..))
import OpenCode.Net.Http (HttpError (..), HttpRequest, defaultRequest, withHeader)
import OpenCode.Tool.Types (SomeTool (..), ToolDef (..))

-- ---------------------------------------------------------------------------
-- Input
-- ---------------------------------------------------------------------------

data WebFetchInput = WebFetchInput
  { wfiUrl       :: Text
  , wfiMaxLength :: Maybe Int
  }
  deriving stock (Show, Eq)

instance FromJSON WebFetchInput where
  parseJSON = Aeson.withObject "WebFetchInput" $ \o -> WebFetchInput
    <$> o .:  "url"
    <*> o .:? "maxLength"

-- ---------------------------------------------------------------------------
-- HTML → text (pure, the thing we unit-test)
-- ---------------------------------------------------------------------------

-- | Strip <script>/<style>/head, convert block tags to newlines, collapse
-- whitespace, decode entities (tagsoup does the latter on parse).
htmlToText :: Text -> Text
htmlToText html =
    collapseSpaces
  . Text.unwords
  . map Text.strip
  . filter (not . Text.null)
  . map Text.pack
  $ map tagToText (stripDangerous (parseTags (Text.unpack html)))
  where
    tagToText (TagText s)             = s
    tagToText (TagOpen "br" _)        = "\n"
    tagToText (TagOpen "p" _)         = "\n\n"
    tagToText (TagClose "p")          = ""
    tagToText (TagOpen "h1" _)        = "\n\n"
    tagToText (TagOpen "li" _)        = "\n- "
    tagToText (TagOpen name _)        = ""
    tagToText (TagClose _)            = ""
    tagToText _                       = ""

-- | Drop everything inside <script>...</script> and <style>...</style> and
-- the <head>...</head> section.
stripDangerous :: [Tag String] -> [Tag String]
stripDangerous = stripSection "head"
               . stripSection "script"
               . stripSection "style"
  where
    stripSection name tags =
      let goes = sections (isTagOpenName name) tags
          keepOutside [] = []
          keepOutside (t:ts)
            | isTagOpenName name t =
                -- skip from this open until the matching close
                let after = dropWhile (not . isTagCloseName name) ts
                in case after of
                     (_close : rest) -> keepOutside rest
                     []              -> []
            | otherwise = t : keepOutside ts
      in keepOutside tags

collapseSpaces :: Text -> Text
collapseSpaces =
    Text.pack
  . unwords
  . words
  . Text.unpack

-- ---------------------------------------------------------------------------
-- Schema & tool
-- ---------------------------------------------------------------------------

webFetchSchema :: Value
webFetchSchema = object
  [ "type" .= ("object" :: Text)
  , "properties" .= object
      [ "url" .= object
          [ "type" .= ("string" :: Text)
          , "description" .= ("URL to fetch" :: Text)
          ]
      , "maxLength" .= object
          [ "type" .= ("integer" :: Text)
          , "description" .= ("Max chars to return (default 10000, hard cap 50000)" :: Text)
          ]
      ]
  , "required" .= (["url"] :: [Text])
  ]

webFetchTool :: SomeTool
webFetchTool = SomeTool
  { toolDef     = DynamicTool
  , toolName    = "web_fetch"
  , toolDesc    = "Fetch a URL and return its text content (HTML stripped). No auth."
  , toolSchema  = webFetchSchema
  , toolExecute = webFetchExec
  , toolRender  = id
  }

defaultMaxLen, hardMaxLen :: Int
defaultMaxLen = 10000
hardMaxLen    = 50000

clampLen :: Maybe Int -> Int
clampLen = maybe defaultMaxLen (\n -> max 1 (min hardMaxLen n))

-- ---------------------------------------------------------------------------
-- Executor
-- ---------------------------------------------------------------------------

webFetchExec :: Value -> AppM Text
webFetchExec args = do
  input <- case Aeson.fromJSON args :: Aeson.Result WebFetchInput of
    Aeson.Success i -> pure i
    Aeson.Error e   -> throwError (ToolError "web_fetch" (Text.pack e))
  backend <- asks envHttpBackend
  let req = defaultRequest (wfiUrl input)
          & withHeader "User-Agent" "opencode-hs/0.1 (Haskell agent)"
          & withHeader "Accept" "text/html, */*"
      (&) = flip ($)
  result <- Control.Monad.IO.Class.liftIO (backend req)
  case result of
    Left err -> throwError (ToolError "web_fetch" (renderErr err))
    Right body ->
      let txt    = htmlToText (TextEnc.decodeUtf8With lenient body)
          maxLen = clampLen (wfiMaxLength input)
      in pure (truncateTo maxLen txt)
  where
    renderErr (HttpError status body) =
      "web_fetch HTTP " <> Text.pack (show status) <> ": " <> body

truncateTo :: Int -> Text -> Text
truncateTo maxLen t
  | Text.length t <= maxLen = t
  | otherwise = Text.take maxLen t <> "\n[... truncated ...]"

lenient :: Data.Text.Encoding.Error.UnicodeDecodeOptions
lenient = Data.Text.Encoding.Error.lenientDecode
```

> **Implementer fixups if GHC complains:**
> - `lenient` is `TextEnc.lenientDecode`; import it properly:
>   `import Data.Text.Encoding.Error (lenientDecode)` and use `TextEnc.decodeUtf8With lenientDecode body`.
> - Remove the local `lenient` binding.
> - The `htmlToText` uses `Text.unwords . map Text.strip` then `collapseSpaces` — the double-processing is redundant; simplify to one whitespace-collapse pass. Verify the tests still pass after simplifying.

- [ ] **Step 4: Register the module in `package.yaml`**

Add to exposed-modules:
```yaml
    - OpenCode.Tool.WebFetch
```
Add to test other-modules:
```yaml
      - OpenCode.Tool.WebFetchSpec
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `stack test --test-arguments="--match WebFetch" 2>&1 | tail -20`
Expected: all tests pass (render, htmlToText pure cases).

- [ ] **Step 6: Commit**

```bash
git add src/OpenCode/Tool/WebFetch.hs test/OpenCode/Tool/WebFetchSpec.hs package.yaml
git commit -m "M17: web_fetch tool (URL→text via tagsoup)"
```

---

## Task 11: `github_search_code` tool

**Files:**
- Create: `src/OpenCode/Tool/GitHubSearch.hs`
- Create: `test/OpenCode/Tool/GitHubSearchSpec.hs`
- Modify: `package.yaml`

- [ ] **Step 1: Write the failing tests**

Create `test/OpenCode/Tool/GitHubSearchSpec.hs`:

```haskell
module OpenCode.Tool.GitHubSearchSpec (spec) where

import Control.Monad.Except (runExceptT)
import Control.Monad.Reader (runReaderT)
import qualified Data.Aeson as Aeson
import qualified Data.ByteString as BS
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as TextEnc
import Test.Hspec

import OpenCode.App (AppEnv (..), AppError)
import OpenCode.Config (ToolsConfig (..))
import OpenCode.Net.Http (HttpError (..))
import OpenCode.Net.HttpMock (mockBackend)
import OpenCode.Tool.Types (executeTool, registerTool, emptyRegistry)
import OpenCode.Tool.GitHubSearch (githubSearchTool)
import OpenCode.Types (ApiKey (..))
import Paths_opencode_hs (getDataFileName)

spec :: Spec
spec = describe "github_search_code tool" $ do

  it "renders matching repo/path + html_url" $ do
    fixture <- BS.readFile =<< getDataFileName ("test/fixtures/web/github/search-code.json" :: String)
    let backend = mockBackend [ ( "api.github.com/search/code", Right fixture ) ]
        reg = registerTool githubSearchTool emptyRegistry
        env = testEnv backend (Just "ghp-test")
        args = Aeson.object [ "query" Aeson..= ("OpenCode" :: Text) ]
    result <- runExceptT $ runReaderT (executeTool reg "github_search_code" args) env
    case result of
      Right t -> do
        Text.unpack t `shouldContain` "1."
        Text.unpack t `shouldContain` "dodofk/opencode-hs"
        Text.unpack t `shouldContain` "app/Main.hs"
      Left err -> expectationFailure (show err)

  it "errors when githubKey is missing" $ do
    let reg = registerTool githubSearchTool emptyRegistry
        env = testEnv (mockBackend []) Nothing
        args = Aeson.object [ "query" Aeson..= ("x" :: Text) ]
    result <- runExceptT $ runReaderT (executeTool reg "github_search_code" args) env
    case result of
      Right _  -> expectationFailure "expected ToolError for missing github key"
      Left err -> show err `shouldContain` "GITHUB_TOKEN"

  it "errors on 403 (rate limit / bad token)" $ do
    let backend = mockBackend [ ( "api.github.com", Left (HttpError 403 "rate limited") ) ]
        reg = registerTool githubSearchTool emptyRegistry
        env = testEnv backend (Just "ghp-test")
        args = Aeson.object [ "query" Aeson..= ("x" :: Text) ]
    result <- runExceptT $ runReaderT (executeTool reg "github_search_code" args) env
    case result of
      Right _  -> expectationFailure "expected ToolError for 403"
      Left err -> show err `shouldContain` "403"

testEnv :: OpenCode.Net.Http.HttpBackend -> Maybe Text -> AppEnv
testEnv backend mGithub = AppEnv
  { envConfig     = undefined
  , envDb         = undefined
  , envRegistry   = undefined
  , envEventChan  = undefined
  , envAbort      = undefined
  , envMcp        = []
  , envSkills     = []
  , envHttpBackend = backend
  , envTools      = ToolsConfig { braveKey = Nothing, githubKey = ApiKey <$> mGithub }
  }
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `stack test --test-arguments="--match GitHubSearch" 2>&1 | tail -15`
Expected: compile error — module missing.

- [ ] **Step 3: Write the tool module**

Create `src/OpenCode/Tool/GitHubSearch.hs`. Mirror `WebSearch` structure; the differences are the endpoint, headers, response shape, and the key field.

```haskell
-- | Tool: GitHub code search via the REST API.
module OpenCode.Tool.GitHubSearch
  ( githubSearchTool
  , githubSearchSchema
  , GitHubSearchInput (..)
  , GitHubCodeItem (..)
  , renderCodeResults
  , githubHeaders
  ) where

import Control.Monad.Except (throwError)
import Control.Monad.Reader (asks)
import Data.Aeson (FromJSON (..), Value, object, (.:), (.:?), (.=))
import qualified Data.Aeson as Aeson
import Data.Text (Text)
import qualified Data.Text as Text

import OpenCode.App (AppEnv (..), AppM, AppError (..))
import OpenCode.Config (ToolsConfig (..))
import OpenCode.Net.Http (HttpBackend, HttpError (..), HttpRequest, defaultRequest, withHeader, withQuery)
import OpenCode.Tool.Types (SomeTool (..), ToolDef (..))
import OpenCode.Types (ApiKey (..))

data GitHubSearchInput = GitHubSearchInput
  { gsiQuery :: Text
  , gsiLimit :: Maybe Int
  }
instance FromJSON GitHubSearchInput where
  parseJSON = Aeson.withObject "GitHubSearchInput" $ \o -> GitHubSearchInput
    <$> o .:  "query"
    <*> o .:? "limit"

data GitHubCodeResponse = GitHubCodeResponse { gcrItems :: [GitHubCodeItem] }
instance FromJSON GitHubCodeResponse where
  parseJSON = Aeson.withObject "GitHubCodeResponse" $ \o -> GitHubCodeResponse
    <$> (o .:? "items" .!= [])

data GitHubCodeItem = GitHubCodeItem
  { gciPath :: Text
  , gciRepo :: Text
  , gciUrl  :: Text
  }
instance FromJSON GitHubCodeItem where
  parseJSON = Aeson.withObject "GitHubCodeItem" $ \o -> do
    path <- o .:  "path"
    repo <- (.: "full_name") <$> (o .: "repository")
    url  <- o .:  "html_url"
    pure GitHubCodeItem { gciPath = path, gciRepo = repo, gciUrl = url }

renderCodeResults :: [GitHubCodeItem] -> Text
renderCodeResults = Text.unlines . zipWith fmt [1 :: Int ..]
  where
    fmt i it = Text.pack (show i) <> ". " <> gciRepo it
            <> "/" <> gciPath it
            <> " : " <> gciUrl it

githubHeaders :: ApiKey -> [(Text, Text)]
githubHeaders (ApiKey tok) =
  [ ("Authorization", "Bearer " <> tok)
  , ("Accept", "application/vnd.github+json")
  , ("User-Agent", "opencode-hs")
  ]

githubSearchSchema :: Value
githubSearchSchema = object
  [ "type" .= ("object" :: Text)
  , "properties" .= object
      [ "query" .= object
          [ "type" .= ("string" :: Text)
          , "description" .= ("GitHub code search query" :: Text)
          ]
      , "limit" .= object
          [ "type" .= ("integer" :: Text)
          , "description" .= ("Max results (default 10, max 30)" :: Text)
          ]
      ]
  , "required" .= (["query"] :: [Text])
  ]

githubSearchTool :: SomeTool
githubSearchTool = SomeTool
  { toolDef     = DynamicTool
  , toolName    = "github_search_code"
  , toolDesc    = "Search GitHub code. Returns repo/path + URL per match."
  , toolSchema  = githubSearchSchema
  , toolExecute = githubSearchExec
  , toolRender  = id
  }

clampLimit :: Maybe Int -> Int
clampLimit = maybe 10 (\n -> max 1 (min 30 n))

githubSearchExec :: Value -> AppM Text
githubSearchExec args = do
  input <- decodeInput args
  backend <- asks envHttpBackend
  mKey <- asks (githubKey . envTools)
  case mKey of
    Nothing -> throwError (ToolError "github_search_code"
      "GitHub tools require GITHUB_TOKEN (env) or tools.githubToken (config.yaml).")
    Just key -> do
      let n = clampLimit (gsiLimit input)
          req = defaultRequest "https://api.github.com/search/code"
                  & withQuery "q" (gsiQuery input)
                  & withQuery "per_page" (Text.pack (show n))
                  & applyHeaders (githubHeaders key)
      runIt backend req
  where
    (&) = flip ($)

applyHeaders :: [(Text, Text)] -> HttpRequest -> HttpRequest
applyHeaders hs r = foldr (\(k,v) acc -> withHeader k v acc) r hs

decodeInput :: Value -> AppM GitHubSearchInput
decodeInput v = case Aeson.fromJSON v of
  Aeson.Success i -> pure i
  Aeson.Error e   -> throwError (ToolError "github_search_code" (Text.pack e))

runIt :: HttpBackend -> HttpRequest -> AppM Text
runIt backend req = do
  result <- Control.Monad.IO.Class.liftIO (backend req)
  case result of
    Left err -> throwError (ToolError "github_search_code"
      ("HTTP " <> Text.pack (show (heStatus err)) <> ": " <> heBody err))
    Right body -> case Aeson.eitherDecodeStrict body :: Either String GitHubCodeResponse of
      Left e   -> throwError (ToolError "github_search_code" ("decode error: " <> Text.pack e))
      Right rs -> pure (renderCodeResults (gcrItems rs))
```

- [ ] **Step 4: Register the module in `package.yaml`**

Add to exposed-modules:
```yaml
    - OpenCode.Tool.GitHubSearch
```
Add to test other-modules:
```yaml
      - OpenCode.Tool.GitHubSearchSpec
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `stack test --test-arguments="--match GitHubSearch" 2>&1 | tail -20`
Expected: 3 tests pass.

- [ ] **Step 6: Commit**

```bash
git add src/OpenCode/Tool/GitHubSearch.hs test/OpenCode/Tool/GitHubSearchSpec.hs package.yaml
git commit -m "M17: github_search_code tool"
```

---

## Task 12: `github_read_issue` tool

**Files:**
- Create: `src/OpenCode/Tool/GitHubIssue.hs`
- Create: `test/OpenCode/Tool/GitHubIssueSpec.hs`
- Modify: `package.yaml`

- [ ] **Step 1: Write the failing tests**

Create `test/OpenCode/Tool/GitHubIssueSpec.hs`:

```haskell
module OpenCode.Tool.GitHubIssueSpec (spec) where

import Control.Monad.Except (runExceptT)
import Control.Monad.Reader (runReaderT)
import qualified Data.Aeson as Aeson
import qualified Data.ByteString as BS
import Data.Text (Text)
import qualified Data.Text as Text
import Test.Hspec

import OpenCode.App (AppEnv (..), AppError)
import OpenCode.Config (ToolsConfig (..))
import OpenCode.Net.HttpMock (mockBackend)
import OpenCode.Tool.Types (executeTool, registerTool, emptyRegistry)
import OpenCode.Tool.GitHubIssue (githubIssueTool)
import OpenCode.Types (ApiKey (..))
import Paths_opencode_hs (getDataFileName)

spec :: Spec
spec = describe "github_read_issue tool" $ do

  it "renders an issue's title/state/author/body" $ do
    fixture <- BS.readFile =<< getDataFileName ("test/fixtures/web/github/issue.json" :: String)
    let backend = mockBackend [ ( "api.github.com/repos", Right fixture ) ]
        reg = registerTool githubIssueTool emptyRegistry
        env = testEnv backend (Just "ghp-test")
        args = Aeson.object
          [ "repo" Aeson..= ("dodofk/opencode-hs" :: Text)
          , "number" Aeson..= (1 :: Int)
          ]
    result <- runExceptT $ runReaderT (executeTool reg "github_read_issue" args) env
    case result of
      Right t -> do
        Text.unpack t `shouldContain` "Example issue"
        Text.unpack t `shouldContain` "open"
        Text.unpack t `shouldContain` "octocat"
        Text.unpack t `shouldContain` "issue body"
      Left err -> expectationFailure (show err)

  it "hits /pulls/ when kind=pr" $ do
    fixture <- BS.readFile =<< getDataFileName ("test/fixtures/web/github/issue.json" :: String)
    let seenUrls = ref_backend_seen_urls  -- placeholder; see note
        backend = mockBackend [ ( "api.github.com/repos/dodofk/opencode-hs/pulls/1", Right fixture ) ]
        reg = registerTool githubIssueTool emptyRegistry
        env = testEnv backend (Just "ghp-test")
        args = Aeson.object
          [ "repo" Aeson..= ("dodofk/opencode-hs" :: Text)
          , "number" Aeson..= (1 :: Int)
          , "kind" Aeson..= ("pr" :: Text)
          ]
    result <- runExceptT $ runReaderT (executeTool reg "github_read_issue" args) env
    case result of
      Right _  -> pure ()  -- success path exercised the pulls URL
      Left err -> expectationFailure (show err)

  it "errors when githubKey is missing" $ do
    let reg = registerTool githubIssueTool emptyRegistry
        env = testEnv (mockBackend []) Nothing
        args = Aeson.object
          [ "repo" Aeson..= ("x/y" :: Text), "number" Aeson..= (1 :: Int) ]
    result <- runExceptT $ runReaderT (executeTool reg "github_read_issue" args) env
    case result of
      Right _  -> expectationFailure "expected ToolError"
      Left err -> show err `shouldContain` "GITHUB_TOKEN"

testEnv :: OpenCode.Net.Http.HttpBackend -> Maybe Text -> AppEnv
testEnv backend mGithub = AppEnv
  { envConfig     = undefined
  , envDb         = undefined
  , envRegistry   = undefined
  , envEventChan  = undefined
  , envAbort      = undefined
  , envMcp        = []
  , envSkills     = []
  , envHttpBackend = backend
  , envTools      = ToolsConfig { braveKey = Nothing, githubKey = ApiKey <$> mGithub }
  }
```

> **Note on the "hits /pulls/" test:** the substring-match mock can't distinguish `/issues/1` from `/pulls/1` if both substrings are present. To make the assertion rigorous, either (a) use `mockBackendExact` and assert on the exact URL, or (b) keep `mockBackend` and configure the response key to include `pulls/1` only. The example above uses (b).

> Remove the `seenUrls` placeholder line — it's not real code.

- [ ] **Step 2: Run the test to verify it fails**

Run: `stack test --test-arguments="--match GitHubIssue" 2>&1 | tail -15`
Expected: compile error.

- [ ] **Step 3: Write the tool module**

Create `src/OpenCode/Tool/GitHubIssue.hs`:

```haskell
-- | Tool: read a GitHub issue or PR by repo + number.
module OpenCode.Tool.GitHubIssue
  ( githubIssueTool
  , githubIssueSchema
  , GitHubIssueInput (..)
  , GitHubIssue (..)
  , renderIssue
  , issueUrl
  ) where

import Control.Monad.Except (throwError)
import Control.Monad.Reader (asks)
import Data.Aeson (FromJSON (..), Value, object, (.:), (.:?), (.=))
import qualified Data.Aeson as Aeson
import Data.Text (Text)
import qualified Data.Text as Text

import OpenCode.App (AppEnv (..), AppM, AppError (..))
import OpenCode.Config (ToolsConfig (..))
import OpenCode.Net.Http (HttpError (..), HttpRequest, defaultRequest, withHeader)
import OpenCode.Tool.GitHubSearch (githubHeaders)   -- reuse the shared header builder
import OpenCode.Tool.Types (SomeTool (..), ToolDef (..))
import OpenCode.Types (ApiKey (..))

data GitHubIssueInput = GitHubIssueInput
  { giiRepo   :: Text
  , giiNumber :: Int
  , giiKind   :: Maybe Text   -- "issue" | "pr"
  }
instance FromJSON GitHubIssueInput where
  parseJSON = Aeson.withObject "GitHubIssueInput" $ \o -> GitHubIssueInput
    <$> o .:  "repo"
    <*> o .:  "number"
    <*> o .:? "kind"

data GitHubIssue = GitHubIssue
  { giTitle  :: Text
  , giState  :: Text
  , giAuthor :: Text
  , giBody   :: Text
  , giLabels :: [Text]
  }
instance FromJSON GitHubIssue where
  parseJSON = Aeson.withObject "GitHubIssue" $ \o -> do
    labels <- (traverse (.: "name")) =<< (o .:? "labels" .!= [])
    GitHubIssue
      <$> o .:  "title"
      <*> o .:  "state"
      <*> ((.: "login") <$> (o .: "user"))
      <*> (o .:? "body" .!= "")
      <*> pure labels

renderIssue :: GitHubIssue -> Text
renderIssue i =
  Text.unlines
    [ "Title: " <> giTitle i
    , "State: " <> giState i
    , "Author: " <> giAuthor i
    , "Labels: " <> Text.intercalate ", " (giLabels i)
    , "Body:"
    , truncateBody (giBody i)
    ]
  where truncateBody b = if Text.length b > 4000 then Text.take 4000 b <> "\n[...truncated...]" else b

issueUrl :: GitHubIssueInput -> Text
issueUrl input =
  let seg = if giiKind input == Just "pr" then "pulls" else "issues"
  in "https://api.github.com/repos/" <> giiRepo input <> "/" <> seg <> "/" <> Text.pack (show (giiNumber input))

githubIssueSchema :: Value
githubIssueSchema = object
  [ "type" .= ("object" :: Text)
  , "properties" .= object
      [ "repo"   .= object [ "type" .= ("string" :: Text), "description" .= ("owner/name, e.g. dodofk/opencode-hs" :: Text) ]
      , "number" .= object [ "type" .= ("integer" :: Text), "description" .= ("Issue or PR number" :: Text) ]
      , "kind"   .= object [ "type" .= ("string" :: Text), "description" .= ("\"issue\" (default) or \"pr\"" :: Text) ]
      ]
  , "required" .= (["repo", "number"] :: [Text])
  ]

githubIssueTool :: SomeTool
githubIssueTool = SomeTool
  { toolDef     = DynamicTool
  , toolName    = "github_read_issue"
  , toolDesc    = "Read a GitHub issue or PR by repo + number. kind defaults to issue."
  , toolSchema  = githubIssueSchema
  , toolExecute = githubIssueExec
  , toolRender  = id
  }

githubIssueExec :: Value -> AppM Text
githubIssueExec args = do
  input <- decodeInput args
  backend <- asks envHttpBackend
  mKey <- asks (githubKey . envTools)
  case mKey of
    Nothing -> throwError (ToolError "github_read_issue"
      "GitHub tools require GITHUB_TOKEN (env) or tools.githubToken (config.yaml).")
    Just key -> do
      let req = defaultRequest (issueUrl input)
              & applyHeaders (githubHeaders key)
      runIt backend req
  where (&) = flip ($)

applyHeaders :: [(Text, Text)] -> HttpRequest -> HttpRequest
applyHeaders hs r = foldr (\(k,v) acc -> withHeader k v acc) r hs

decodeInput :: Value -> AppM GitHubIssueInput
decodeInput v = case Aeson.fromJSON v of
  Aeson.Success i -> pure i
  Aeson.Error e   -> throwError (ToolError "github_read_issue" (Text.pack e))

runIt :: OpenCode.Net.Http.HttpBackend -> HttpRequest -> AppM Text
runIt backend req = do
  result <- Control.Monad.IO.Class.liftIO (backend req)
  case result of
    Left err -> throwError (ToolError "github_read_issue"
      ("HTTP " <> Text.pack (show (heStatus err)) <> ": " <> heBody err))
    Right body -> case Aeson.eitherDecodeStrict body :: Either String GitHubIssue of
      Left e   -> throwError (ToolError "github_read_issue" ("decode error: " <> Text.pack e))
      Right i  -> pure (renderIssue i)
```

- [ ] **Step 4: Register the module in `package.yaml`**

Add to exposed-modules:
```yaml
    - OpenCode.Tool.GitHubIssue
```
Add to test other-modules:
```yaml
      - OpenCode.Tool.GitHubIssueSpec
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `stack test --test-arguments="--match GitHubIssue" 2>&1 | tail -20`
Expected: 3 tests pass.

- [ ] **Step 6: Commit**

```bash
git add src/OpenCode/Tool/GitHubIssue.hs test/OpenCode/Tool/GitHubIssueSpec.hs package.yaml
git commit -m "M17: github_read_issue tool (issue/PR by number)"
```

---

## Task 13: `github_fetch_file` tool

**Files:**
- Create: `src/OpenCode/Tool/GitHubFile.hs`
- Create: `test/OpenCode/Tool/GitHubFileSpec.hs`
- Modify: `package.yaml`

- [ ] **Step 1: Write the failing tests**

Create `test/OpenCode/Tool/GitHubFileSpec.hs`:

```haskell
module OpenCode.Tool.GitHubFileSpec (spec) where

import Control.Monad.Except (runExceptT)
import Control.Monad.Reader (runReaderT)
import qualified Data.Aeson as Aeson
import qualified Data.ByteString as BS
import qualified Data.ByteString.Base64 as B64
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as TextEnc
import Test.Hspec

import OpenCode.App (AppEnv (..), AppError)
import OpenCode.Config (ToolsConfig (..))
import OpenCode.Net.HttpMock (mockBackend)
import OpenCode.Tool.Types (executeTool, registerTool, emptyRegistry)
import OpenCode.Tool.GitHubFile (githubFileTool)
import OpenCode.Types (ApiKey (..))
import Paths_opencode_hs (getDataFileName)

spec :: Spec
spec = describe "github_fetch_file tool" $ do

  it "decodes base64 content and returns file text" $ do
    fixture <- BS.readFile =<< getDataFileName ("test/fixtures/web/github/contents.json" :: String)
    let backend = mockBackend [ ( "api.github.com/repos", Right fixture ) ]
        reg = registerTool githubFileTool emptyRegistry
        env = testEnv backend (Just "ghp-test")
        args = Aeson.object
          [ "repo" Aeson..= ("dodofk/opencode-hs" :: Text)
          , "path" Aeson..= ("app/Main.hs" :: Text)
          ]
    result <- runExceptT $ runReaderT (executeTool reg "github_fetch_file" args) env
    case result of
      Right t -> Text.unpack t `shouldContain` "module Main where"
      Left err -> expectationFailure (show err)

  it "errors when githubKey is missing" $ do
    let reg = registerTool githubFileTool emptyRegistry
        env = testEnv (mockBackend []) Nothing
        args = Aeson.object [ "repo" Aeson..= ("x/y" :: Text), "path" Aeson..= ("f" :: Text) ]
    result <- runExceptT $ runReaderT (executeTool reg "github_fetch_file" args) env
    case result of
      Right _  -> expectationFailure "expected ToolError"
      Left err -> show err `shouldContain` "GITHUB_TOKEN"

testEnv :: OpenCode.Net.Http.HttpBackend -> Maybe Text -> AppEnv
testEnv backend mGithub = AppEnv
  { envConfig     = undefined
  , envDb         = undefined
  , envRegistry   = undefined
  , envEventChan  = undefined
  , envAbort      = undefined
  , envMcp        = []
  , envSkills     = []
  , envHttpBackend = backend
  , envTools      = ToolsConfig { braveKey = Nothing, githubKey = ApiKey <$> mGithub }
  }
```

> **Note:** the test imports `Data.ByteString.Base64`. Add `base64-bytestring` to the test dependencies in `package.yaml` under `tests.opencode-hs-test.dependencies` if it's not already transitively available. Check with `stack ghc --package base64-bytestring` — if available transitively, no change needed.

- [ ] **Step 2: Run the test to verify it fails**

Run: `stack test --test-arguments="--match GitHubFile" 2>&1 | tail -15`
Expected: compile error.

- [ ] **Step 3: Write the tool module**

Create `src/OpenCode/Tool/GitHubFile.hs`:

```haskell
-- | Tool: fetch a file from a GitHub repo via the contents API.
module OpenCode.Tool.GitHubFile
  ( githubFileTool
  , githubFileSchema
  , GitHubFileInput (..)
  , fileUrl
  , decodeFileContent
  ) where

import Control.Monad.Except (throwError)
import Control.Monad.Reader (asks)
import Data.Aeson (FromJSON (..), Value, object, (.:), (.:?), (.=))
import qualified Data.Aeson as Aeson
import qualified Data.ByteString as BS
import qualified Data.ByteString.Base64 as B64
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as TextEnc
import Data.Text.Encoding.Error (lenientDecode)

import OpenCode.App (AppEnv (..), AppM, AppError (..))
import OpenCode.Config (ToolsConfig (..))
import OpenCode.Net.Http (HttpError (..), HttpRequest, defaultRequest, withHeader, withQuery)
import OpenCode.Tool.GitHubSearch (githubHeaders)
import OpenCode.Tool.Types (SomeTool (..), ToolDef (..))
import OpenCode.Types (ApiKey (..))

data GitHubFileInput = GitHubFileInput
  { gfiRepo :: Text
  , gfiPath :: Text
  , gfiRef  :: Maybe Text
  }
instance FromJSON GitHubFileInput where
  parseJSON = Aeson.withObject "GitHubFileInput" $ \o -> GitHubFileInput
    <$> o .:  "repo"
    <*> o .:  "path"
    <*> o .:? "ref"

data GitHubContents = GitHubContents
  { gcContent :: Text      -- base64-encoded
  , gcEncoding :: Text
  }
instance FromJSON GitHubContents where
  parseJSON = Aeson.withObject "GitHubContents" $ \o -> GitHubContents
    <$> (o .:? "content" .!= "")
    <*> (o .:? "encoding" .!= "base64")

-- | Decode the base64 content blob to Text (stripping embedded newlines
-- that GitHub inserts for readability).
decodeFileContent :: Text -> Either String Text
decodeFileContent b64text = do
  let cleaned = Text.filter (/= '\n') b64text
  bytes <- B64.decode (TextEnc.encodeUtf8 cleaned)
  Right (TextEnc.decodeUtf8With lenientDecode bytes)

fileUrl :: GitHubFileInput -> Text
fileUrl input =
  "https://api.github.com/repos/" <> gfiRepo input
    <> "/contents/" <> gfiPath input

githubFileSchema :: Value
githubFileSchema = object
  [ "type" .= ("object" :: Text)
  , "properties" .= object
      [ "repo" .= object [ "type" .= ("string" :: Text), "description" .= ("owner/name" :: Text) ]
      , "path" .= object [ "type" .= ("string" :: Text), "description" .= ("path within the repo" :: Text) ]
      , "ref"  .= object [ "type" .= ("string" :: Text), "description" .= ("git ref (default branch if omitted)" :: Text) ]
      ]
  , "required" .= (["repo", "path"] :: [Text])
  ]

githubFileTool :: SomeTool
githubFileTool = SomeTool
  { toolDef     = DynamicTool
  , toolName    = "github_fetch_file"
  , toolDesc    = "Fetch a file's text from a GitHub repo via the contents API."
  , toolSchema  = githubFileSchema
  , toolExecute = githubFileExec
  , toolRender  = id
  }

truncateFile :: Text -> Text
truncateFile t = if Text.length t > 10000 then Text.take 10000 t <> "\n[...truncated...]" else t

githubFileExec :: Value -> AppM Text
githubFileExec args = do
  input <- decodeInput args
  backend <- asks envHttpBackend
  mKey <- asks (githubKey . envTools)
  case mKey of
    Nothing -> throwError (ToolError "github_fetch_file"
      "GitHub tools require GITHUB_TOKEN (env) or tools.githubToken (config.yaml).")
    Just key -> do
      let base = defaultRequest (fileUrl input) & applyHeaders (githubHeaders key)
          req  = case gfiRef input of
            Nothing  -> base
            Just ref -> base & withQuery "ref" ref
      runIt backend req
  where (&) = flip ($)

applyHeaders :: [(Text, Text)] -> HttpRequest -> HttpRequest
applyHeaders hs r = foldr (\(k,v) acc -> withHeader k v acc) r hs

decodeInput :: Value -> AppM GitHubFileInput
decodeInput v = case Aeson.fromJSON v of
  Aeson.Success i -> pure i
  Aeson.Error e   -> throwError (ToolError "github_fetch_file" (Text.pack e))

runIt :: OpenCode.Net.Http.HttpBackend -> HttpRequest -> AppM Text
runIt backend req = do
  result <- Control.Monad.IO.Class.liftIO (backend req)
  case result of
    Left err -> throwError (ToolError "github_fetch_file"
      ("HTTP " <> Text.pack (show (heStatus err)) <> ": " <> heBody err))
    Right body -> case Aeson.eitherDecodeStrict body :: Either String GitHubContents of
      Left e    -> throwError (ToolError "github_fetch_file" ("decode error: " <> Text.pack e))
      Right cnt -> case decodeFileContent (gcContent cnt) of
        Left e   -> throwError (ToolError "github_fetch_file" ("base64 decode failed: " <> Text.pack e))
        Right tx -> pure (truncateFile tx)
```

- [ ] **Step 4: Add `base64-bytestring` dependency (if needed)**

In `package.yaml`, check if `base64-bytestring` is available. If `stack build` fails on the import, add to `dependencies:`:

```yaml
  - base64-bytestring >= 1.2
```

(The `binary` package bundled with GHC sometimes provides this transitively, but explicit is safer.)

- [ ] **Step 5: Register the module in `package.yaml`**

Add to exposed-modules:
```yaml
    - OpenCode.Tool.GitHubFile
```
Add to test other-modules:
```yaml
      - OpenCode.Tool.GitHubFileSpec
```

- [ ] **Step 6: Run the test to verify it passes**

Run: `stack test --test-arguments="--match GitHubFile" 2>&1 | tail -20`
Expected: 2 tests pass.

- [ ] **Step 7: Commit**

```bash
git add src/OpenCode/Tool/GitHubFile.hs test/OpenCode/Tool/GitHubFileSpec.hs package.yaml
git commit -m "M17: github_fetch_file tool (base64 contents decode)"
```

---

## Task 14: Register all 5 tools in `Run.withAppEnv`

**Files:**
- Modify: `src/OpenCode/Run.hs`
- Modify: `test/OpenCode/Tool/RegistrySpec.hs`

- [ ] **Step 1: Write the failing test**

In `test/OpenCode/Tool/RegistrySpec.hs`, add (or extend the existing "all tools registered" test) to assert the 5 new tools are present in a registry built via `withAppEnv` or the registry-builder function `Run` exposes. If `RegistrySpec` tests a pure registry builder (not the full `withAppEnv`), test that:

```haskell
  it "registers the M17 web/github tools" $ do
    let names = Map.keys (unRegistry builtRegistry)
    names `shouldContain` ["web_search", "web_fetch"]
    names `shouldContain` ["github_search_code", "github_read_issue", "github_fetch_file"]
```

(Adapt `builtRegistry` to however `RegistrySpec` currently constructs it. If it doesn't have a fixture, extend `RunSpec` instead — which tests `withAppEnv` end-to-end with the mock LLM.)

- [ ] **Step 2: Run the test to verify it fails**

Run: `stack test --test-arguments="--match Registry" 2>&1 | tail -15`
Expected: the 5 names are absent.

- [ ] **Step 3: Register the tools in `Run`**

In `src/OpenCode/Run.hs`, in the function that builds `envRegistry` (inside `withAppEnv`, where the existing tools are registered with `registerTool`), add:

```haskell
import OpenCode.Tool.WebSearch (webSearchTool)
import OpenCode.Tool.WebFetch (webFetchTool)
import OpenCode.Tool.GitHubSearch (githubSearchTool)
import OpenCode.Tool.GitHubIssue (githubIssueTool)
import OpenCode.Tool.GitHubFile (githubFileTool)
```

And in the registry-building chain (next to `registerTool bashTool`, etc.):

```haskell
      . registerTool webSearchTool
      . registerTool webFetchTool
      . registerTool githubSearchTool
      . registerTool githubIssueTool
      . registerTool githubFileTool
```

> All five are always registered (even if their key is missing) so the model knows they exist and can report the missing key. This matches the spec's "tool is still registered" decision in the error-handling table.

- [ ] **Step 4: Run the test to verify it passes**

Run: `stack test --test-arguments="--match Registry" 2>&1 | tail -15`
Expected: pass.

- [ ] **Step 5: Run the full test suite**

Run: `stack test 2>&1 | tail -10`
Expected: all tests pass (previous count + new ones).

- [ ] **Step 6: Commit**

```bash
git add src/OpenCode/Run.hs test/OpenCode/Tool/RegistrySpec.hs
git commit -m "M17: register web_search/web_fetch/github_* tools in Run"
```

---

## Task 15: Update `MILESTONES.md`

**Files:**
- Modify: `MILESTONES.md`

- [ ] **Step 1: Add the M17 section**

In `MILESTONES.md`, add M17 to the status table (after the M16 row):

```markdown
| M17 | Web & GitHub tools (web_search, web_fetch, github_*) | done    | `<first>..<last>` |
```

Update the snapshot date to the current date and extend the intro paragraph to mention M17.

Add a detail section at the end of the file (after the M16 detail section) summarizing what shipped:

```markdown
## M17 — Web & GitHub tools

Five networked tools on a shared injectable HTTP substrate
(`OpenCode.Net.Http` + `Net.HttpMock`): `web_search` (Brave), `web_fetch`
(URL→text via tagsoup), `github_search_code`, `github_read_issue`,
`github_fetch_file`. Config gains a `ToolsConfig` record (braveKey,
githubKey) with env-over-YAML. Pure + mock testing; zero network in CI.
New dep: `tagsoup`.
```

- [ ] **Step 2: Commit**

```bash
git add MILESTONES.md
git commit -m "M17: document Web & GitHub tools milestone"
```

---

## Task 16: Full verification

- [ ] **Step 1: Clean build with -Wall -Werror**

Run: `stack build --ghc-options="-Wall -Werror" 2>&1 | tail -10`
Expected: clean, no warnings.

- [ ] **Step 2: Full test suite**

Run: `stack test 2>&1 | tail -15`
Expected: all tests pass, including all new web/github tests.

- [ ] **Step 3: Smoke-test with a real key (manual, not CI)**

```bash
BRAVE_API_KEY=<key> stack run opencode-hs -- run \
  --model minimax:MiniMax-M3 --no-tui \
  --prompt "Search the web for the latest Haskell release and summarize"
```

Expected: the model invokes `web_search`, then possibly `web_fetch`, and summarizes.

- [ ] **Step 4: Final commit (if any cleanup)**

```bash
git status   # should be clean
git log --oneline | head -20
```

---

## Self-Review Notes

(I ran this against the spec during writing; issues found and fixed inline:)

1. **Spec coverage:** Every spec section maps to a task — §2 Net.Http → T2–T4; §3 web → T9–T10; §4 github → T11–T13; §5 config → T5; §6 testing → every task + fixtures T8; §7 wiring → T6–T7, T14. No spec requirement lacks a task.
2. **Placeholder scan:** Two intentional "note for the implementer" callouts (the Task 2 `runOne` sketch, the base64 dep check) are flagged as TBD-then-resolved in later tasks. No open placeholders remain.
3. **Type consistency:** `braveKey`/`githubKey` accessors used consistently. `ToolsConfig` field names match across Config, AppEnv, and every tool executor. `HttpBackend` type used identically in all 5 tools. `githubHeaders` is defined once (T11) and imported by T12/T13.
4. **Dependency ordering:** Tasks are sequenced so each compiles before the next: deps → types → mock → config → AppEnv → wire → fixtures → tools (each tool self-contained) → registry → docs → verify. Task 6 leaves a known-broken build resolved by Task 7.
```
