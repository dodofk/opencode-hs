# M5 — Tool System: file I/O Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a type-safe `executeTool` dispatch over the `ToolRegistry` GADT plus three file-manipulation tools (`read_file`, `write_file`, `edit_file`), wired into `AppEnv` via `envRegistry`.

**Architecture:** The M0 skeleton already has the heavy structural pieces (input/output records for all 6 tools, the `ToolDef` GADT with all constructors, `SomeTool` existential wrapper, `ToolRegistry`/`registerTool`/`lookupTool`). M5 fills in: (a) `executeTool` — the JSON-args → typed-input → run-handler → render-output dispatch; (b) three real tool values (`readFileTool`, `writeFileTool`, `editFileTool`) backed by IO inside `AppM`; (c) hand-written JSON Schemas per tool input; (d) `defaultBuiltinRegistry` aggregating the three; (e) `envRegistry :: ToolRegistry` field on `AppEnv`. The plan also reshapes `SomeTool` to add a `toolRender :: o -> Text` field (replacing the existential `ToJSON o` constraint) so file tools can return raw text instead of JSON-quoted text — see "Spec resolution" below.

**Tech stack:** `Diff >= 0.4` (already in `package.yaml`) for unified-diff output in `editFileTool`. `directory`, `filepath`, `bytestring`, `text` — all already present. No new dependencies.

---

## Spec resolution: tool output rendering

The M5 spec in `MILESTONES.md` describes `executeTool` as "encodes the output as JSON text", but the acceptance test expects `Right "wrote 2 bytes to /tmp/x"` (raw text, not the JSON-quoted form `"\"wrote 2 bytes…\""`).

**Resolution:** add a `toolRender :: o -> Text` field to `SomeTool` so each tool controls its own output rendering. File tools (M5: all return `Text`) use `id` — output is the raw text directly. Structured-output tools in M7 (Bash returns `BashOutput`, Grep returns `[GrepMatch]`) will set `toolRender = Text.decodeUtf8 . BSL.toStrict . Aeson.encode` to opt into JSON encoding.

This drops the existential `ToJSON o` constraint on `SomeTool` (the current skeleton has it) and replaces it with the new function field. Cleaner: rendering choice is per-tool, not per-output-type. Touched in Task 1.

---

## File structure

| Path | Action | Responsibility |
| ---- | ------ | -------------- |
| `src/OpenCode/Tool/Types.hs` | edit | Drop `ToJSON o` from `SomeTool`; add `toolRender :: o -> Text`; add JSON `inputOptions` (strip field prefix); replace `deriving anyclass (FromJSON, ToJSON)` with explicit instances for the 6 input/output records; add `executeTool`; remove `_someToolDefinition` placeholder; tighten exports |
| `src/OpenCode/Tool/ReadFile.hs` | edit | Implement `readFileTool`; binary detection; offset/limit; 100 KB cap |
| `src/OpenCode/Tool/WriteFile.hs` | edit | Implement `writeFileTool`; atomic write via `.tmp` + `renameFile`; create parent dirs |
| `src/OpenCode/Tool/EditFile.hs` | edit | Implement `editFileTool`; unique-match check; replace; unified diff via `Data.Algorithm.Diff` |
| `src/OpenCode/App.hs` | edit | Add `envRegistry :: ToolRegistry` field to `AppEnv` |
| `test/OpenCode/ToolSpec.hs` | delete | M0 placeholder; replaced by per-tool specs |
| `test/OpenCode/Tool/TypesSpec.hs` | create | Tests for `executeTool` (unknown tool, malformed args, happy path) and `inputOptions` (prefix stripping round-trip) |
| `test/OpenCode/Tool/ReadFileSpec.hs` | create | Tests for `readFileTool` (full read, offset+limit, binary refusal, 100 KB cap) |
| `test/OpenCode/Tool/WriteFileSpec.hs` | create | Tests for `writeFileTool` (write, mkdir parent, no `.tmp` leftover, byte count) |
| `test/OpenCode/Tool/EditFileSpec.hs` | create | Tests for `editFileTool` (unique replacement, ambiguous error, zero matches, diff content) |
| `test/OpenCode/Tool/RegistrySpec.hs` | create | Tests for `defaultBuiltinRegistry` (all 3 tools registered, names match, executeTool dispatch round-trip) |
| `MILESTONES.md` | edit (final task) | Mark M5 done |

The plan does NOT create a separate `OpenCode.Tool.Schema` module — JSON Schemas live in each tool's own module (e.g., `readFileSchema :: Value` in `OpenCode.Tool.ReadFile`). Keeps each tool file self-contained.

---

## Toolchain note

`stack` and `ghc` at `~/.ghcup/bin` — prefix every Bash with `export PATH="$HOME/.ghcup/bin:$PATH" &&`. `hlint` at `/opt/homebrew/bin/hlint`.

---

## Pre-flight: skeleton vs spec reconciliation

The M0 skeleton already provides:

- All 6 tool input/output records (`ReadFileInput`, `WriteFileInput`, `EditFileInput`, `BashInput`, `BashOutput`, `GlobInput`, `GrepInput`, `GrepMatch`) with `deriving anyclass (FromJSON, ToJSON)` and `rfi`/`wfi`/`efi`/`bi`/`bo`/`gi`/`gri`/`gm` field prefixes.
- The `ToolDef` GADT with all 6 constructors.
- `data SomeTool = forall i o. (FromJSON i, ToJSON o) => SomeTool { toolDef, toolName, toolDesc, toolSchema, toolExecute }`.
- `ToolRegistry`, `emptyRegistry`, `registerTool :: SomeTool -> ToolRegistry -> ToolRegistry`, `lookupTool :: Text -> ToolRegistry -> Maybe SomeTool`.
- `someToolDefinition :: SomeTool -> ToolDefinition` (plus a `_someToolDefinition` placeholder hack to suppress unused warnings).
- Stub tools: `readFileTool`, `writeFileTool`, `editFileTool` all `error "..."`.

M5 changes the skeleton in these ways:
- Replaces `(FromJSON i, ToJSON o) => SomeTool { …, toolExecute :: i -> AppM o }` with `FromJSON i => SomeTool { …, toolExecute :: i -> AppM o, toolRender :: o -> Text }`.
- Replaces `deriving anyclass (FromJSON, ToJSON)` on the 6 records with explicit instances using `genericParseJSON inputOptions` / `genericToJSON inputOptions` where `inputOptions` strips the prefix and omits Nothing fields.
- Adds `executeTool :: ToolRegistry -> Text -> Aeson.Value -> AppM Text`.
- Adds `defaultBuiltinRegistry :: ToolRegistry` containing the 3 file tools.
- Adds `envRegistry :: ToolRegistry` to `AppEnv`.
- Removes the `_someToolDefinition` placeholder hack.

---

## Task 1 — Reshape `SomeTool`, add `executeTool`, fix JSON field names

**Files:**
- Modify: `src/OpenCode/Tool/Types.hs`
- Create: `test/OpenCode/Tool/TypesSpec.hs`
- Delete: `test/OpenCode/ToolSpec.hs` (M0 placeholder)

### Step 1.1: Delete the M0 placeholder spec

```
git -C /Users/dodofk/Misc/opencode-hs rm test/OpenCode/ToolSpec.hs
```

### Step 1.2: Write the failing tests

Create `test/OpenCode/Tool/TypesSpec.hs`:

```haskell
module OpenCode.Tool.TypesSpec (spec) where

import Control.Monad.Except (runExceptT)
import Control.Monad.Reader (runReaderT)
import Data.Aeson (Value, object, (.=))
import qualified Data.Aeson as Aeson
import Data.Text (Text)
import qualified Data.Text as Text
import Test.Hspec

import OpenCode.App (AppEnv (..), AppError (..), AppM)
import OpenCode.Tool.Types

spec :: Spec
spec = do
  describe "inputOptions field stripping" $ do

    it "round-trips a ReadFileInput through JSON with stripped field names" $ do
      let input = ReadFileInput { rfiPath = "/tmp/x", rfiOffset = Just 5, rfiLimit = Just 10 }
          encoded = Aeson.encode input
      -- Should contain "path", "offset", "limit" — NOT "rfiPath" etc.
      encoded `shouldSatisfy` (\b -> "\"path\":" `Text.isInfixOf` Text.pack (show b))
      encoded `shouldSatisfy` (\b -> "\"offset\":" `Text.isInfixOf` Text.pack (show b))
      encoded `shouldNotSatisfy` (\b -> "\"rfiPath\":" `Text.isInfixOf` Text.pack (show b))
      -- And the round-trip is total.
      Aeson.eitherDecode encoded `shouldBe` Right input

    it "round-trips a WriteFileInput" $ do
      let input = WriteFileInput { wfiPath = "/tmp/y", wfiContent = "hello\nworld" }
      Aeson.eitherDecode (Aeson.encode input) `shouldBe` Right input

    it "round-trips an EditFileInput" $ do
      let input = EditFileInput "/tmp/z" "old text" "new text"
      Aeson.eitherDecode (Aeson.encode input) `shouldBe` Right input

    it "omits Nothing fields from JSON" $ do
      let input = ReadFileInput { rfiPath = "/tmp/x", rfiOffset = Nothing, rfiLimit = Nothing }
          encoded = Text.pack (show (Aeson.encode input))
      encoded `shouldNotSatisfy` ("offset" `Text.isInfixOf`)
      encoded `shouldNotSatisfy` ("limit"  `Text.isInfixOf`)

  describe "executeTool" $ do

    it "raises ToolError on an unknown tool name" $ do
      let reg = emptyRegistry
      result <- runTool reg "no_such_tool" (object [])
      result `shouldBe` Left (ToolError "no_such_tool" "unknown tool")

    it "raises ToolError on malformed JSON arguments" $ do
      let reg = registerTool (echoTool "echo") emptyRegistry
      result <- runTool reg "echo" (Aeson.Number 42)   -- not an object
      case result of
        Left (ToolError "echo" msg) -> Text.unpack msg `shouldContain` "Error in $"
        _ -> expectationFailure ("expected ToolError on malformed args, got " <> show result)

    it "dispatches a registered tool and returns its rendered output" $ do
      let reg = registerTool (echoTool "echo") emptyRegistry
      result <- runTool reg "echo" (object ["wfiPath" .= ("/tmp/x" :: Text), "wfiContent" .= ("hello" :: Text)])
      -- echoTool's renderer is id and it returns its wfiContent verbatim.
      -- But! The args use prefix-stripped names ("path", "content"), not the raw record field names.
      pendingWith "see next test — this one demonstrates that raw record names are NOT what executeTool decodes"

    it "decodes prefix-stripped JSON when dispatching" $ do
      let reg = registerTool (echoTool "echo") emptyRegistry
      result <- runTool reg "echo" (object ["path" .= ("/tmp/x" :: Text), "content" .= ("hello" :: Text)])
      result `shouldBe` Right "hello"

-- ---------------------------------------------------------------------------
-- Test helpers
-- ---------------------------------------------------------------------------

-- | Run an 'executeTool' invocation against a stub AppEnv whose only valid
-- field is a placeholder Config / Connection — we don't exercise either here.
runTool :: ToolRegistry -> Text -> Value -> IO (Either AppError Text)
runTool reg name args = do
  -- The executeTool path doesn't touch envConfig or envDb for the tools we're
  -- testing here; placeholder values are fine.
  let env = AppEnv { envConfig = stubConfig, envDb = stubConn }
  runExceptT (runReaderT (executeTool reg name args) env)

-- These are 'undefined' — the executeTool dispatch in this spec doesn't touch
-- them. If a future test introduces a tool that DOES touch them, supply real
-- values.
stubConfig :: OpenCode.Config.Config
stubConfig = undefined

stubConn :: Database.SQLite.Simple.Connection
stubConn = undefined

-- | A WriteFileInput-shaped echo tool that returns wfiContent verbatim,
-- with toolRender = id. Used for testing executeTool dispatch.
echoTool :: Text -> SomeTool
echoTool name = SomeTool
  { toolDef     = WriteFileTool
  , toolName    = name
  , toolDesc    = "echo for testing"
  , toolSchema  = object []
  , toolExecute = \input -> pure (wfiContent input)
  , toolRender  = id
  }
```

(Add imports for `OpenCode.Config` and `Database.SQLite.Simple` as referenced.)

### Step 1.3: Run tests to confirm fail

```
export PATH="$HOME/.ghcup/bin:$PATH" && stack test --match "OpenCode.Tool.Types" 2>&1 | tail -15
```

Expected: doesn't compile (missing `inputOptions`, `executeTool`, new `toolRender` field; the existing `(FromJSON i, ToJSON o)` constraint on `SomeTool` doesn't match the new 6-field constructor).

### Step 1.4: Rewrite `src/OpenCode/Tool/Types.hs`

Overwrite the file with:

```haskell
-- | Type-safe tool system using GADTs and existential wrappers.
module OpenCode.Tool.Types
  ( -- * GADT
    ToolDef (..)
    -- * Input/output records (one per tool)
  , ReadFileInput (..)
  , WriteFileInput (..)
  , EditFileInput (..)
  , BashInput (..)
  , BashOutput (..)
  , GlobInput (..)
  , GrepInput (..)
  , GrepMatch (..)
    -- * Existential wrapper
  , SomeTool (..)
    -- * Registry
  , ToolRegistry (..)
  , emptyRegistry
  , registerTool
  , lookupTool
  , someToolDefinition
    -- * Dispatch
  , executeTool
    -- * Aeson helpers
  , inputOptions
  ) where

import Control.Monad.Except (throwError)
import Data.Aeson (FromJSON (..), ToJSON (..), Value (..))
import qualified Data.Aeson as Aeson
import qualified Data.ByteString.Lazy as BSL
import Data.Char (isLower, toLower)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import GHC.Generics (Generic)

import OpenCode.App (AppError (..), AppM)
import OpenCode.LLM.Types (ToolDefinition (..))

-- ---------------------------------------------------------------------------
-- Aeson options: strip field-name prefix, omit Nothing fields
--
-- Field naming convention: each record uses a 2-3 letter lowercase prefix
-- ('rfi' for ReadFileInput, 'bo' for BashOutput, etc.). The JSON wire format
-- strips this prefix so the LLM sees clean lowercase field names ('path',
-- 'offset', 'stdout', etc.).
-- ---------------------------------------------------------------------------

inputOptions :: Aeson.Options
inputOptions = Aeson.defaultOptions
  { Aeson.fieldLabelModifier = stripFieldPrefix
  , Aeson.omitNothingFields  = True
  }
  where
    -- Drop leading lowercase letters, then lowercase the next letter.
    -- "rfiPath" -> "path", "boStdout" -> "stdout", "path" (no prefix) -> "path".
    stripFieldPrefix s = case dropWhile isLower s of
      []       -> s
      (c:rest) -> toLower c : rest

-- ---------------------------------------------------------------------------
-- Tool input / output records
-- ---------------------------------------------------------------------------

data ReadFileInput = ReadFileInput
  { rfiPath   :: FilePath
  , rfiOffset :: Maybe Int   -- ^ start line (1-indexed)
  , rfiLimit  :: Maybe Int   -- ^ number of lines to read
  }
  deriving stock (Show, Eq, Generic)

instance FromJSON ReadFileInput where parseJSON = Aeson.genericParseJSON inputOptions
instance ToJSON   ReadFileInput where toJSON    = Aeson.genericToJSON    inputOptions

data WriteFileInput = WriteFileInput
  { wfiPath    :: FilePath
  , wfiContent :: Text
  }
  deriving stock (Show, Eq, Generic)

instance FromJSON WriteFileInput where parseJSON = Aeson.genericParseJSON inputOptions
instance ToJSON   WriteFileInput where toJSON    = Aeson.genericToJSON    inputOptions

data EditFileInput = EditFileInput
  { efiPath      :: FilePath
  , efiOldString :: Text
  , efiNewString :: Text
  }
  deriving stock (Show, Eq, Generic)

instance FromJSON EditFileInput where parseJSON = Aeson.genericParseJSON inputOptions
instance ToJSON   EditFileInput where toJSON    = Aeson.genericToJSON    inputOptions

data BashInput = BashInput
  { biCommand :: Text
  , biTimeout :: Maybe Int   -- ^ seconds; default 30
  }
  deriving stock (Show, Eq, Generic)

instance FromJSON BashInput where parseJSON = Aeson.genericParseJSON inputOptions
instance ToJSON   BashInput where toJSON    = Aeson.genericToJSON    inputOptions

data BashOutput = BashOutput
  { boStdout   :: Text
  , boStderr   :: Text
  , boExitCode :: Int
  }
  deriving stock (Show, Eq, Generic)

instance FromJSON BashOutput where parseJSON = Aeson.genericParseJSON inputOptions
instance ToJSON   BashOutput where toJSON    = Aeson.genericToJSON    inputOptions

data GlobInput = GlobInput
  { giPattern :: Text
  , giRoot    :: Maybe FilePath
  }
  deriving stock (Show, Eq, Generic)

instance FromJSON GlobInput where parseJSON = Aeson.genericParseJSON inputOptions
instance ToJSON   GlobInput where toJSON    = Aeson.genericToJSON    inputOptions

data GrepInput = GrepInput
  { griPattern   :: Text
  , griPath      :: Maybe FilePath
  , griRecursive :: Bool
  }
  deriving stock (Show, Eq, Generic)

instance FromJSON GrepInput where parseJSON = Aeson.genericParseJSON inputOptions
instance ToJSON   GrepInput where toJSON    = Aeson.genericToJSON    inputOptions

data GrepMatch = GrepMatch
  { gmFile :: FilePath
  , gmLine :: Int
  , gmText :: Text
  }
  deriving stock (Show, Eq, Generic)

instance FromJSON GrepMatch where parseJSON = Aeson.genericParseJSON inputOptions
instance ToJSON   GrepMatch where toJSON    = Aeson.genericToJSON    inputOptions

-- ---------------------------------------------------------------------------
-- GADT
-- ---------------------------------------------------------------------------

data ToolDef input output where
  ReadFileTool  :: ToolDef ReadFileInput  Text
  WriteFileTool :: ToolDef WriteFileInput Text
  EditFileTool  :: ToolDef EditFileInput  Text
  BashTool      :: ToolDef BashInput      BashOutput
  GlobTool      :: ToolDef GlobInput      [FilePath]
  GrepTool      :: ToolDef GrepInput      [GrepMatch]

-- | Existential wrapper: pairs a GADT tag with its executor and renderer.
-- Only 'FromJSON' is required on the input type — the output renderer is
-- supplied per-tool, so structured-output tools (M7's Bash, Grep) can JSON-
-- encode while text-output tools (M5's file tools) can pass text through.
data SomeTool = forall i o.
  FromJSON i => SomeTool
  { toolDef     :: ToolDef i o
  , toolName    :: Text
  , toolDesc    :: Text
  , toolSchema  :: Value          -- ^ JSON Schema for this tool's input
  , toolExecute :: i -> AppM o
  , toolRender  :: o -> Text      -- ^ how to present output to the LLM
  }

-- ---------------------------------------------------------------------------
-- Registry
-- ---------------------------------------------------------------------------

newtype ToolRegistry = ToolRegistry
  { unRegistry :: Map Text SomeTool
  }

emptyRegistry :: ToolRegistry
emptyRegistry = ToolRegistry Map.empty

registerTool :: SomeTool -> ToolRegistry -> ToolRegistry
registerTool t (ToolRegistry m) = ToolRegistry (Map.insert (toolName t) t m)

lookupTool :: Text -> ToolRegistry -> Maybe SomeTool
lookupTool name (ToolRegistry m) = Map.lookup name m

-- | Convert a registry entry to the wire format sent to the LLM.
someToolDefinition :: SomeTool -> ToolDefinition
someToolDefinition t = ToolDefinition
  { tdName        = toolName t
  , tdDescription = toolDesc t
  , tdSchema      = toolSchema t
  }

-- ---------------------------------------------------------------------------
-- Dispatch
-- ---------------------------------------------------------------------------

-- | Look up a tool by name, decode the JSON arguments to its typed input,
-- run the handler, and render the output as 'Text'. Raises 'ToolError' on
-- unknown name or malformed arguments.
executeTool :: ToolRegistry -> Text -> Value -> AppM Text
executeTool reg name args = case lookupTool name reg of
  Nothing -> throwError (ToolError name "unknown tool")
  Just SomeTool { toolExecute = exec, toolRender = render } ->
    case Aeson.fromJSON args of
      Aeson.Error e   -> throwError (ToolError name (Text.pack e))
      Aeson.Success input -> do
        output <- exec input
        pure (render output)

-- (The 'BSL', 'Text.encodeUtf8' / 'decodeUtf8' imports are kept for use by
-- structured-output tools in M7, which will set 'toolRender = Text.decodeUtf8
-- . BSL.toStrict . Aeson.encode'. They're unused at M5 but harmless to import.)
```

Note: `BSL` and `Text.encodeUtf8` / `Text.decodeUtf8` are imported in anticipation of M7 use. If GHC flags them as unused at M5, remove the imports — M7 will re-add them.

The placeholder `_someToolDefinition :: SomeTool -> ToolDefinition` is GONE. `someToolDefinition` is exported in the public API list.

### Step 1.5: Run tests to confirm pass

```
export PATH="$HOME/.ghcup/bin:$PATH" && stack test --match "OpenCode.Tool.Types" 2>&1 | tail -15
```

Expected: build clean (or with at most a few unused-import warnings — fix those by removing the unused imports). All 4 `inputOptions` tests pass; all 4 `executeTool` tests pass (one is `pending`); full suite climbs by ~7 net (`-1` for the deleted M0 placeholder; `+7` for the 7 active specs in TypesSpec). Pending tests don't fail the suite.

### Step 1.6: hlint clean

```
hlint src app test verify 2>&1 | tail -3
```

Expected: `No hints`. The `dropWhile isLower` partial-style is safe (`case … of` matches every shape). If hlint suggests `Data.Bifunctor.first` or similar, apply only if it improves clarity.

### Step 1.7: Commit

```
git add src/OpenCode/Tool/Types.hs test/OpenCode/Tool/TypesSpec.hs test/OpenCode/ToolSpec.hs
git commit -m "M5: reshape SomeTool (toolRender), prefix-strip JSON, add executeTool"
```

(The `git rm` from Step 1.1 already staged the deletion of `ToolSpec.hs`.)

---

## Task 2 — `readFileTool`

**Files:**
- Modify: `src/OpenCode/Tool/ReadFile.hs`
- Create: `test/OpenCode/Tool/ReadFileSpec.hs`

### Step 2.1: Write the failing tests

Create `test/OpenCode/Tool/ReadFileSpec.hs`:

```haskell
module OpenCode.Tool.ReadFileSpec (spec) where

import Control.Monad.Except (runExceptT)
import Control.Monad.Reader (runReaderT)
import qualified Data.ByteString as BS
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.IO as TIO
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

import OpenCode.App (AppEnv (..), AppError (..))
import OpenCode.Tool.ReadFile
import OpenCode.Tool.Types

spec :: Spec
spec = describe "readFileTool" $ do

  it "reads an entire small file" $
    withSystemTempDirectory "rf" $ \dir -> do
      let path = dir </> "hello.txt"
      TIO.writeFile path "hello\nworld\n"
      result <- runRead (ReadFileInput path Nothing Nothing)
      result `shouldBe` Right "hello\nworld\n"

  it "honours offset and limit" $
    withSystemTempDirectory "rf" $ \dir -> do
      let path = dir </> "fifty.txt"
          body = Text.unlines [Text.pack ("line " <> show n) | n <- [1 :: Int .. 50]]
      TIO.writeFile path body
      result <- runRead (ReadFileInput path (Just 10) (Just 5))
      case result of
        Right t  -> Text.lines t `shouldBe`
          [ "line 10", "line 11", "line 12", "line 13", "line 14" ]
        Left err -> expectationFailure (show err)

  it "refuses a file with a NUL byte in the first 8 KB (binary detection)" $
    withSystemTempDirectory "rf" $ \dir -> do
      let path = dir </> "bin.dat"
      BS.writeFile path (BS.pack [97, 98, 99, 0, 100, 101, 102])  -- abc\0def
      result <- runRead (ReadFileInput path Nothing Nothing)
      case result of
        Left (ToolError "read_file" msg) -> Text.unpack msg `shouldContain` "binary"
        _ -> expectationFailure ("expected binary-refusal ToolError, got " <> show result)

  it "truncates output at 100 KB and appends a marker" $
    withSystemTempDirectory "rf" $ \dir -> do
      let path = dir </> "big.txt"
          body = Text.replicate 150000 "a"  -- 150 KB of 'a'
      TIO.writeFile path body
      result <- runRead (ReadFileInput path Nothing Nothing)
      case result of
        Right t  -> do
          Text.length t `shouldSatisfy` (< 150000)
          Text.unpack t `shouldContain` "[truncated:"
        Left err -> expectationFailure (show err)

-- ---------------------------------------------------------------------------
-- Helper: dispatch readFileTool through executeTool
-- ---------------------------------------------------------------------------

runRead :: ReadFileInput -> IO (Either AppError Text)
runRead input = do
  let reg = registerTool readFileTool emptyRegistry
      env = AppEnv { envConfig = undefined, envDb = undefined }
      args = Aeson.toJSON input
  runExceptT (runReaderT (executeTool reg "read_file" args) env)
```

Imports already include `Control.Monad.Except (runExceptT)`, `Control.Monad.Reader (runReaderT)`, `qualified Data.Aeson as Aeson` per the import block at the top.

(`undefined` for `envConfig`/`envDb` is acceptable because `readFileTool`'s executor doesn't touch them. Task 5 will add `envRegistry = undefined` to this and the other tool spec helpers when that field lands on `AppEnv`.)

### Step 2.2: Run tests to confirm fail

```
export PATH="$HOME/.ghcup/bin:$PATH" && stack test --match "OpenCode.Tool.ReadFile" 2>&1 | tail -15
```

Expected: 4 failures because `readFileTool` is still a stub.

### Step 2.3: Implement `readFileTool`

Rewrite `src/OpenCode/Tool/ReadFile.hs`:

```haskell
-- | Tool: read a file (or a line range within it).
module OpenCode.Tool.ReadFile
  ( readFileTool
  , readFileSchema
  ) where

import Control.Exception (try, SomeException)
import Control.Monad.Except (throwError)
import Control.Monad.IO.Class (liftIO)
import Data.Aeson (Value, object, (.=))
import qualified Data.ByteString as BS
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import qualified Data.Text.Encoding.Error as Text
import qualified Data.Text.IO as TIO

import OpenCode.App (AppError (..), AppM)
import OpenCode.Tool.Types
  ( ReadFileInput (..)
  , SomeTool (..)
  , ToolDef (ReadFileTool)
  )

-- | JSON Schema for the read_file tool input.
readFileSchema :: Value
readFileSchema = object
  [ "type"       .= ("object" :: Text)
  , "properties" .= object
      [ "path"   .= object
          [ "type"        .= ("string" :: Text)
          , "description" .= ("Path to the file to read" :: Text)
          ]
      , "offset" .= object
          [ "type"        .= ("integer" :: Text)
          , "description" .= ("1-based starting line number (omit for start of file)" :: Text)
          ]
      , "limit"  .= object
          [ "type"        .= ("integer" :: Text)
          , "description" .= ("Maximum number of lines to read (omit for whole file)" :: Text)
          ]
      ]
  , "required"   .= (["path"] :: [Text])
  ]

-- | The read_file 'SomeTool' value.
readFileTool :: SomeTool
readFileTool = SomeTool
  { toolDef     = ReadFileTool
  , toolName    = "read_file"
  , toolDesc    = "Read a file from disk. Optionally read a line range via offset/limit. Refuses binary files."
  , toolSchema  = readFileSchema
  , toolExecute = readFileExec
  , toolRender  = id
  }

-- ---------------------------------------------------------------------------
-- Executor
-- ---------------------------------------------------------------------------

maxBytes :: Int
maxBytes = 100 * 1024     -- 100 KB

probeBytes :: Int
probeBytes = 8 * 1024     -- first 8 KB for binary detection

readFileExec :: ReadFileInput -> AppM Text
readFileExec ReadFileInput { rfiPath = path, rfiOffset = offset, rfiLimit = limit } = do
  rawResult <- liftIO (try (BS.readFile path) :: IO (Either SomeException BS.ByteString))
  case rawResult of
    Left ex -> throwError (ToolError "read_file" (Text.pack ("read failed: " <> show ex)))
    Right raw -> do
      let probe = BS.take probeBytes raw
      if BS.elem 0 probe
        then throwError (ToolError "read_file" "binary file refused")
        else do
          -- Decode using lenient UTF-8 — broken codepoints become U+FFFD,
          -- never throw.
          let decoded = Text.decodeUtf8With Text.lenientDecode raw
              sliced  = applyOffsetLimit offset limit decoded
              capped  = cap maxBytes sliced (BS.length raw)
          pure capped

-- | Slice text by 1-based line offset + line count. If either bound is Nothing,
-- the corresponding end is unbounded. The output preserves trailing newlines.
applyOffsetLimit :: Maybe Int -> Maybe Int -> Text -> Text
applyOffsetLimit offset limit t =
  let allLines = Text.lines t
      startIdx = maybe 0 (\o -> max 0 (o - 1)) offset
      after    = drop startIdx allLines
      window   = maybe after (`take` after) limit
  in Text.unlines window

-- | Cap text at the given byte budget. If truncation occurs, append a marker
-- noting how many more bytes were skipped (computed against the original raw
-- byte length, not the decoded UTF-8 character length).
cap :: Int -> Text -> Int -> Text
cap budget t rawLen =
  let utf8len = BS.length (Text.encodeUtf8 t)
  in if utf8len <= budget
       then t
       else
         let kept = Text.decodeUtf8With Text.lenientDecode (BS.take budget (Text.encodeUtf8 t))
             dropped = rawLen - budget
         in kept <> Text.pack ("\n[truncated: " <> show dropped <> " more bytes]")
```

Note about `cap`: the byte-truncation may split a UTF-8 codepoint mid-character; `decodeUtf8With lenientDecode` substitutes U+FFFD for any incomplete sequence rather than throwing. This is correct for a user-facing display.

### Step 2.4: Run tests to confirm pass

```
export PATH="$HOME/.ghcup/bin:$PATH" && stack test --match "OpenCode.Tool.ReadFile" 2>&1 | tail -15
```

Expected: 4 specs pass.

### Step 2.5: hlint + commit

```
hlint src app test verify 2>&1 | tail -3
git add src/OpenCode/Tool/ReadFile.hs test/OpenCode/Tool/ReadFileSpec.hs
git commit -m "M5: implement readFileTool (offset/limit, binary refusal, 100 KB cap)"
```

---

## Task 3 — `writeFileTool`

**Files:**
- Modify: `src/OpenCode/Tool/WriteFile.hs`
- Create: `test/OpenCode/Tool/WriteFileSpec.hs`

### Step 3.1: Write the failing tests

Create `test/OpenCode/Tool/WriteFileSpec.hs`:

```haskell
module OpenCode.Tool.WriteFileSpec (spec) where

import Control.Monad.Except (runExceptT)
import Control.Monad.Reader (runReaderT)
import qualified Data.Aeson as Aeson
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.IO as TIO
import System.Directory (doesFileExist)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

import OpenCode.App (AppEnv (..), AppError)
import OpenCode.Tool.Types
import OpenCode.Tool.WriteFile

spec :: Spec
spec = describe "writeFileTool" $ do

  it "writes a small file and reports the byte count" $
    withSystemTempDirectory "wf" $ \dir -> do
      let path = dir </> "out.txt"
      result <- runWrite (WriteFileInput path "hello")
      result `shouldBe` Right (Text.pack ("wrote 5 bytes to " <> path))
      contents <- TIO.readFile path
      contents `shouldBe` "hello"

  it "creates missing parent directories" $
    withSystemTempDirectory "wf" $ \dir -> do
      let path = dir </> "a" </> "b" </> "c.txt"
      result <- runWrite (WriteFileInput path "ok")
      case result of
        Right _ -> doesFileExist path >>= (`shouldBe` True)
        Left  e -> expectationFailure (show e)

  it "leaves no .tmp file after a successful write" $
    withSystemTempDirectory "wf" $ \dir -> do
      let path = dir </> "atomic.txt"
      _ <- runWrite (WriteFileInput path "data")
      doesFileExist (path <> ".tmp") >>= (`shouldBe` False)

  it "counts bytes in UTF-8 (multi-byte characters)" $
    withSystemTempDirectory "wf" $ \dir -> do
      let path    = dir </> "utf8.txt"
          content = "héllo"   -- é is 2 bytes in UTF-8 (6 bytes total)
      result <- runWrite (WriteFileInput path content)
      result `shouldBe` Right (Text.pack ("wrote 6 bytes to " <> path))

-- ---------------------------------------------------------------------------
-- Helper
-- ---------------------------------------------------------------------------

runWrite :: WriteFileInput -> IO (Either AppError Text)
runWrite input = do
  let reg = registerTool writeFileTool emptyRegistry
      env = AppEnv { envConfig = undefined, envDb = undefined }
      args = Aeson.toJSON input
  runExceptT (runReaderT (executeTool reg "write_file" args) env)
```

### Step 3.2: Run tests to confirm fail

```
export PATH="$HOME/.ghcup/bin:$PATH" && stack test --match "OpenCode.Tool.WriteFile" 2>&1 | tail -15
```

Expected: 4 failures (`writeFileTool` is still a stub).

### Step 3.3: Implement `writeFileTool`

Rewrite `src/OpenCode/Tool/WriteFile.hs`:

```haskell
-- | Tool: write (or overwrite) a file atomically.
module OpenCode.Tool.WriteFile
  ( writeFileTool
  , writeFileSchema
  ) where

import Control.Exception (try, SomeException)
import Control.Monad.Except (throwError)
import Control.Monad.IO.Class (liftIO)
import Data.Aeson (Value, object, (.=))
import qualified Data.ByteString as BS
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import System.Directory (createDirectoryIfMissing, renameFile)
import System.FilePath (takeDirectory)

import OpenCode.App (AppError (..), AppM)
import OpenCode.Tool.Types
  ( SomeTool (..)
  , ToolDef (WriteFileTool)
  , WriteFileInput (..)
  )

-- | JSON Schema for the write_file tool input.
writeFileSchema :: Value
writeFileSchema = object
  [ "type"       .= ("object" :: Text)
  , "properties" .= object
      [ "path"    .= object
          [ "type"        .= ("string" :: Text)
          , "description" .= ("Path to the file to write (parents created if missing)" :: Text)
          ]
      , "content" .= object
          [ "type"        .= ("string" :: Text)
          , "description" .= ("File contents (UTF-8)" :: Text)
          ]
      ]
  , "required"   .= (["path", "content"] :: [Text])
  ]

writeFileTool :: SomeTool
writeFileTool = SomeTool
  { toolDef     = WriteFileTool
  , toolName    = "write_file"
  , toolDesc    = "Write (or overwrite) a file atomically. Creates parent directories if missing."
  , toolSchema  = writeFileSchema
  , toolExecute = writeFileExec
  , toolRender  = id
  }

-- ---------------------------------------------------------------------------
-- Executor
-- ---------------------------------------------------------------------------

writeFileExec :: WriteFileInput -> AppM Text
writeFileExec WriteFileInput { wfiPath = path, wfiContent = content } = do
  let bytes  = Text.encodeUtf8 content
      tmp    = path <> ".tmp"
  attempt <- liftIO $ try $ do
    createDirectoryIfMissing True (takeDirectory path)
    BS.writeFile tmp bytes
    renameFile tmp path
  case attempt :: Either SomeException () of
    Left ex -> throwError (ToolError "write_file" (Text.pack ("write failed: " <> show ex)))
    Right () -> pure (Text.pack ("wrote " <> show (BS.length bytes) <> " bytes to " <> path))
```

### Step 3.4: Run tests to confirm pass

```
export PATH="$HOME/.ghcup/bin:$PATH" && stack test --match "OpenCode.Tool.WriteFile" 2>&1 | tail -15
```

Expected: 4 specs pass.

### Step 3.5: hlint + commit

```
hlint src app test verify 2>&1 | tail -3
git add src/OpenCode/Tool/WriteFile.hs test/OpenCode/Tool/WriteFileSpec.hs
git commit -m "M5: implement writeFileTool (atomic write, mkdir parents, byte count)"
```

---

## Task 4 — `editFileTool`

**Files:**
- Modify: `src/OpenCode/Tool/EditFile.hs`
- Create: `test/OpenCode/Tool/EditFileSpec.hs`

### Step 4.1: Write the failing tests

Create `test/OpenCode/Tool/EditFileSpec.hs`:

```haskell
module OpenCode.Tool.EditFileSpec (spec) where

import Control.Monad.Except (runExceptT)
import Control.Monad.Reader (runReaderT)
import qualified Data.Aeson as Aeson
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.IO as TIO
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

import OpenCode.App (AppEnv (..), AppError (..))
import OpenCode.Tool.EditFile
import OpenCode.Tool.Types

spec :: Spec
spec = describe "editFileTool" $ do

  it "replaces a unique match and returns a non-empty diff" $
    withSystemTempDirectory "ef" $ \dir -> do
      let path = dir </> "f.txt"
      TIO.writeFile path "alpha\nbeta\ngamma\n"
      result <- runEdit (EditFileInput path "beta" "BETA")
      case result of
        Right diff -> do
          Text.length diff `shouldSatisfy` (> 0)
          Text.unpack diff `shouldContain` "-"
          Text.unpack diff `shouldContain` "+"
        Left err   -> expectationFailure (show err)
      after <- TIO.readFile path
      after `shouldBe` "alpha\nBETA\ngamma\n"

  it "errors when the old string is not found" $
    withSystemTempDirectory "ef" $ \dir -> do
      let path = dir </> "f.txt"
      TIO.writeFile path "alpha\nbeta\n"
      result <- runEdit (EditFileInput path "MISSING" "X")
      case result of
        Left (ToolError "edit_file" msg) -> Text.unpack msg `shouldContain` "not found"
        _ -> expectationFailure ("expected not-found ToolError, got " <> show result)

  it "errors when the old string matches more than once" $
    withSystemTempDirectory "ef" $ \dir -> do
      let path = dir </> "f.txt"
      TIO.writeFile path "x\nx\nx\n"
      result <- runEdit (EditFileInput path "x" "y")
      case result of
        Left (ToolError "edit_file" msg) -> Text.unpack msg `shouldContain` "ambiguous"
        _ -> expectationFailure ("expected ambiguous ToolError, got " <> show result)

  it "leaves the file untouched on error" $
    withSystemTempDirectory "ef" $ \dir -> do
      let path = dir </> "f.txt"
      TIO.writeFile path "x\nx\n"
      _ <- runEdit (EditFileInput path "x" "y")   -- ambiguous; should not write
      after <- TIO.readFile path
      after `shouldBe` "x\nx\n"

-- ---------------------------------------------------------------------------
-- Helper
-- ---------------------------------------------------------------------------

runEdit :: EditFileInput -> IO (Either AppError Text)
runEdit input = do
  let reg = registerTool editFileTool emptyRegistry
      env = AppEnv { envConfig = undefined, envDb = undefined }
      args = Aeson.toJSON input
  runExceptT (runReaderT (executeTool reg "edit_file" args) env)
```

### Step 4.2: Run tests to confirm fail

```
export PATH="$HOME/.ghcup/bin:$PATH" && stack test --match "OpenCode.Tool.EditFile" 2>&1 | tail -15
```

Expected: 4 failures (stub).

### Step 4.3: Implement `editFileTool`

Rewrite `src/OpenCode/Tool/EditFile.hs`:

```haskell
-- | Tool: edit a file by replacing an exact unique substring.
module OpenCode.Tool.EditFile
  ( editFileTool
  , editFileSchema
  ) where

import Control.Exception (try, SomeException)
import Control.Monad.Except (throwError)
import Control.Monad.IO.Class (liftIO)
import Data.Aeson (Value, object, (.=))
import qualified Data.Algorithm.Diff as Diff
import qualified Data.ByteString as BS
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import qualified Data.Text.Encoding.Error as Text
import System.Directory (renameFile)

import OpenCode.App (AppError (..), AppM)
import OpenCode.Tool.Types
  ( EditFileInput (..)
  , SomeTool (..)
  , ToolDef (EditFileTool)
  )

-- | JSON Schema for the edit_file tool input.
editFileSchema :: Value
editFileSchema = object
  [ "type"       .= ("object" :: Text)
  , "properties" .= object
      [ "path"      .= object
          [ "type"        .= ("string" :: Text)
          , "description" .= ("Path to the file to edit" :: Text)
          ]
      , "oldString" .= object
          [ "type"        .= ("string" :: Text)
          , "description" .= ("Exact substring to find (must match exactly once)" :: Text)
          ]
      , "newString" .= object
          [ "type"        .= ("string" :: Text)
          , "description" .= ("Replacement text" :: Text)
          ]
      ]
  , "required"   .= (["path", "oldString", "newString"] :: [Text])
  ]

editFileTool :: SomeTool
editFileTool = SomeTool
  { toolDef     = EditFileTool
  , toolName    = "edit_file"
  , toolDesc    = "Replace a unique substring in a file. Errors if the substring is missing or matches more than once."
  , toolSchema  = editFileSchema
  , toolExecute = editFileExec
  , toolRender  = id
  }

-- ---------------------------------------------------------------------------
-- Executor
-- ---------------------------------------------------------------------------

editFileExec :: EditFileInput -> AppM Text
editFileExec EditFileInput { efiPath = path, efiOldString = oldStr, efiNewString = newStr } = do
  readResult <- liftIO (try (BS.readFile path) :: IO (Either SomeException BS.ByteString))
  case readResult of
    Left ex -> throwError (ToolError "edit_file" (Text.pack ("read failed: " <> show ex)))
    Right raw -> do
      let before = Text.decodeUtf8With Text.lenientDecode raw
          n      = countOccurrences oldStr before
      case n of
        0 -> throwError (ToolError "edit_file" "not found")
        k | k > 1 -> throwError (ToolError "edit_file"
                                  (Text.pack ("ambiguous: " <> show k <> " matches")))
        _ -> do
          let after = Text.replace oldStr newStr before
              tmp   = path <> ".tmp"
          writeResult <- liftIO $ try $ do
            BS.writeFile tmp (Text.encodeUtf8 after)
            renameFile tmp path
          case writeResult :: Either SomeException () of
            Left ex -> throwError (ToolError "edit_file"
                                    (Text.pack ("write failed: " <> show ex)))
            Right () -> pure (renderDiff before after)

-- | Count non-overlapping occurrences of a substring.
countOccurrences :: Text -> Text -> Int
countOccurrences needle hay
  | Text.null needle = 0
  | otherwise        = length (Text.breakOnAll needle hay)

-- | Render a per-line diff between two Text values in a unified-ish style.
-- Unchanged lines: prefixed with two spaces.
-- Removed lines: prefixed with "- ".
-- Added lines: prefixed with "+ ".
renderDiff :: Text -> Text -> Text
renderDiff before after =
  let bs = Text.lines before
      as = Text.lines after
      groups = Diff.getGroupedDiff bs as
  in Text.unlines (concatMap renderGroup groups)
  where
    renderGroup (Diff.Both xs _) = map ("  " <>) xs
    renderGroup (Diff.First  xs) = map ("- " <>) xs
    renderGroup (Diff.Second xs) = map ("+ " <>) xs
```

### Step 4.4: Run tests to confirm pass

```
export PATH="$HOME/.ghcup/bin:$PATH" && stack test --match "OpenCode.Tool.EditFile" 2>&1 | tail -15
```

Expected: 4 specs pass.

### Step 4.5: hlint + commit

```
hlint src app test verify 2>&1 | tail -3
git add src/OpenCode/Tool/EditFile.hs test/OpenCode/Tool/EditFileSpec.hs
git commit -m "M5: implement editFileTool (unique-match check + atomic write + line diff)"
```

---

## Task 5 — `defaultBuiltinRegistry` + `AppEnv.envRegistry`

**Files:**
- Modify: `src/OpenCode/Tool/Types.hs` (add `defaultBuiltinRegistry`)
- Modify: `src/OpenCode/App.hs` (add `envRegistry`)
- Create: `test/OpenCode/Tool/RegistrySpec.hs`

### Step 5.1: Write the failing tests

Create `test/OpenCode/Tool/RegistrySpec.hs`:

```haskell
module OpenCode.Tool.RegistrySpec (spec) where

import Control.Monad.Except (runExceptT)
import Control.Monad.Reader (runReaderT)
import qualified Data.Aeson as Aeson
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text.IO as TIO
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

import OpenCode.App (AppEnv (..))
import OpenCode.Tool.Types

spec :: Spec
spec = describe "defaultBuiltinRegistry" $ do

  it "registers exactly the three M5 file tools by name" $
    Map.keys (unRegistry defaultBuiltinRegistry)
      `shouldMatchList` ["read_file", "write_file", "edit_file"]

  it "is accessible from AppEnv via envRegistry" $
    let env = AppEnv { envConfig = undefined, envDb = undefined, envRegistry = defaultBuiltinRegistry }
    in Map.size (unRegistry (envRegistry env)) `shouldBe` 3

  it "round-trips write_file then read_file through executeTool" $
    withSystemTempDirectory "reg" $ \dir -> do
      let path = dir </> "rt.txt"
          env  = AppEnv { envConfig = undefined, envDb = undefined, envRegistry = defaultBuiltinRegistry }
      written <- runExceptT $ runReaderT
        (executeTool defaultBuiltinRegistry "write_file"
          (Aeson.object ["path" Aeson..= path, "content" Aeson..= ("hi" :: Text)]))
        env
      written `shouldBe` Right ("wrote 2 bytes to " <> Text.pack path)

      readBack <- runExceptT $ runReaderT
        (executeTool defaultBuiltinRegistry "read_file"
          (Aeson.object ["path" Aeson..= path]))
        env
      readBack `shouldBe` Right "hi\n"
```

Add `import qualified Data.Text as Text` to the test file.

### Step 5.2: Run tests to confirm fail

```
export PATH="$HOME/.ghcup/bin:$PATH" && stack test --match "defaultBuiltinRegistry" 2>&1 | tail -15
```

Expected: doesn't compile (`defaultBuiltinRegistry` not defined; `AppEnv` has no `envRegistry` field).

### Step 5.3: Break the import cycle by splitting `OpenCode.App`

**Why this step exists:** the new `envRegistry :: ToolRegistry` field requires `AppEnv` (defined in `OpenCode.App`) to import from `OpenCode.Tool.Types`. But `OpenCode.Tool.Types` already imports from `OpenCode.App` (for `AppM` and `AppError`). Adding the registry field naively creates an import cycle.

**Resolution:** split `OpenCode.App` into three modules:
- `OpenCode.App.Error` — defines only `AppError`. No dependencies on anything else in the project.
- `OpenCode.App.Types` — defines `AppM` and `AppEnv` (the new `AppEnv` with `envRegistry`). Imports `App.Error`, `Config`, `Tool.Types`.
- `OpenCode.App` — thin re-export shell. Re-exports everything from `App.Error` and `App.Types`, plus its existing `runAppM`, `runApp`, `liftIO'`, `throwAppError`, `askConfig`.

`OpenCode.Tool.Types` imports `AppError` from `App.Error` and `AppM` from `App.Types`, NOT from `App` — that closes the cycle (Tool.Types → App.Error + App.Types, neither of which import Tool.*).

Test files keep using `OpenCode.App` (via re-export); no test imports need to change.

#### (i) Create `src/OpenCode/App/Error.hs`

```haskell
-- | Application error type. Kept in a leaf module to allow Tool/* modules
-- to refer to 'AppError' without inducing an import cycle through 'AppEnv'.
module OpenCode.App.Error
  ( AppError (..)
  ) where

import Data.Text (Text)

data AppError
  = ConfigError Text
  | LLMError Text
  | ToolError Text Text   -- ^ tool name, message
  | DatabaseError Text
  | MCPError Text
  | UnexpectedError Text
  deriving stock (Show, Eq)
```

#### (ii) Create `src/OpenCode/App/Types.hs`

```haskell
-- | Application monad and environment. Depends on Tool.Types for the
-- registry; lives in a sibling-of-App module so Tool/* can import the
-- monad type (via 'AppM' re-exported from 'OpenCode.App') without a cycle.
module OpenCode.App.Types
  ( AppM
  , AppEnv (..)
  ) where

import Control.Monad.Except (ExceptT)
import Control.Monad.Reader (ReaderT)
import Database.SQLite.Simple (Connection)

import OpenCode.App.Error (AppError)
import OpenCode.Config (Config)
import OpenCode.Tool.Types (ToolRegistry)

type AppM = ReaderT AppEnv (ExceptT AppError IO)

data AppEnv = AppEnv
  { envConfig   :: Config
  , envDb       :: Connection
  , envRegistry :: ToolRegistry
  -- envEventChan, envAbort: added in M6
  }
```

#### (iii) Refactor `src/OpenCode/Tool/Types.hs`

Change the import line from:

```haskell
import OpenCode.App (AppError (..), AppM)
```

to:

```haskell
import OpenCode.App.Error (AppError (..))
import OpenCode.App.Types (AppM)
```

That's the only change to `Tool/Types.hs` — just the import path.

#### (iv) Rewrite `src/OpenCode/App.hs` as a re-export shell

```haskell
-- | Application monad, environment, and top-level entry point.
-- This module re-exports the leaf types from 'OpenCode.App.Error' and
-- 'OpenCode.App.Types' so consumers can keep using 'OpenCode.App' as a
-- single entry point, while the leaf modules remain dependency-free of
-- 'OpenCode.Tool.*'.
module OpenCode.App
  ( -- * Re-exports
    AppM
  , AppEnv (..)
  , AppError (..)
    -- * Running
  , runAppM
  , runApp
    -- * Helpers
  , liftIO'
  , throwAppError
  , askConfig
  ) where

import Control.Exception (SomeException, try)
import Control.Monad.Except (ExceptT, runExceptT, throwError)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Reader (ReaderT, asks, runReaderT)
import qualified Data.Text as Text

import OpenCode.App.Error (AppError (..))
import OpenCode.App.Types (AppEnv (..), AppM)
import OpenCode.Config (Config)

runAppM :: AppEnv -> AppM a -> IO (Either AppError a)
runAppM env action = runExceptT (runReaderT action env)

runApp :: IO ()
runApp = putStrLn "opencode-hs: not yet implemented"

liftIO' :: IO a -> AppM a
liftIO' action = do
  result <- liftIO (try @SomeException action)
  case result of
    Left  ex -> throwError (UnexpectedError (Text.pack (show ex)))
    Right a  -> pure a

throwAppError :: AppError -> AppM a
throwAppError = throwError

askConfig :: AppM Config
askConfig = asks envConfig
```

(Imports use only `runExceptT`/`throwError` and `asks`/`runReaderT` at the value level — the types `ExceptT` / `ReaderT` are not referenced in this file since `AppM` is imported pre-applied from `App.Types`. If GHC flags `ExceptT`/`ReaderT` as unused, tighten the imports to:

```haskell
import Control.Monad.Except (runExceptT, throwError)
import Control.Monad.Reader (asks, runReaderT)
```

The code block above already uses that tighter form — verify it matches before saving.)

#### (v) Update `package.yaml`

In `library: exposed-modules:`, add `OpenCode.App.Error` and `OpenCode.App.Types` alphabetically (right after `OpenCode.App`).

#### (vi) Update the test helpers in Tasks 2/3/4 to include `envRegistry`

The `AppEnv` record now has three fields (`envConfig`, `envDb`, `envRegistry`), so the existing `env = AppEnv { envConfig = undefined, envDb = undefined }` constructions in `test/OpenCode/Tool/ReadFileSpec.hs`, `test/OpenCode/Tool/WriteFileSpec.hs`, and `test/OpenCode/Tool/EditFileSpec.hs` need a third field. Add `envRegistry = undefined` to each:

```haskell
env = AppEnv { envConfig = undefined, envDb = undefined, envRegistry = undefined }
```

(All three test files have this exact `env = AppEnv …` construction inside their `run*` helper. Apply identically.)

`test/OpenCode/Tool/TypesSpec.hs` (from Task 1) has a `stubConfig`/`stubConn` pattern — add `envRegistry = undefined` to its `env =` construction as well.

### Step 5.4: Create `src/OpenCode/Tool/Registry.hs` with `defaultBuiltinRegistry`

```haskell
-- | The default built-in tool registry.
-- Aggregates the three M5 file-I/O tools; M7 will extend this with bash, glob, grep.
module OpenCode.Tool.Registry
  ( defaultBuiltinRegistry
  ) where

import OpenCode.Tool.EditFile (editFileTool)
import OpenCode.Tool.ReadFile (readFileTool)
import OpenCode.Tool.Types (ToolRegistry, emptyRegistry, registerTool)
import OpenCode.Tool.WriteFile (writeFileTool)

defaultBuiltinRegistry :: ToolRegistry
defaultBuiltinRegistry =
    registerTool readFileTool
  $ registerTool writeFileTool
  $ registerTool editFileTool
  $ emptyRegistry
```

Add `OpenCode.Tool.Registry` to `package.yaml`'s `library: exposed-modules:` list alphabetically among the `OpenCode.Tool.*` entries.

Update `test/OpenCode/Tool/RegistrySpec.hs` (created in Step 5.1) imports to bring `defaultBuiltinRegistry` from the new module:

```haskell
import OpenCode.Tool.Registry (defaultBuiltinRegistry)
```

### Step 5.5: Build + test

```
export PATH="$HOME/.ghcup/bin:$PATH" && stack build 2>&1 | tail -10 && stack test --match "Registry" 2>&1 | tail -15
```

Expected: clean build, `defaultBuiltinRegistry` specs pass; full suite climbs accordingly.

### Step 5.6: hlint clean

```
hlint src app test verify 2>&1 | tail -3
```

Expected: `No hints`. Some warnings may appear for the App.hs re-exports — if so, add `{-# OPTIONS_GHC -Wno-redundant-imports #-}` only on `OpenCode.App` (NOT on the leaf modules), and document why.

### Step 5.7: Commit

```
git add src/OpenCode/App/Error.hs src/OpenCode/App/Types.hs src/OpenCode/App.hs src/OpenCode/Tool/Types.hs src/OpenCode/Tool/Registry.hs package.yaml opencode-hs.cabal test/OpenCode/Tool/RegistrySpec.hs test/OpenCode/Tool/TypesSpec.hs test/OpenCode/Tool/ReadFileSpec.hs test/OpenCode/Tool/WriteFileSpec.hs test/OpenCode/Tool/EditFileSpec.hs
git commit -m "M5: defaultBuiltinRegistry + envRegistry (split App into Error/Types)"
```

---

## Task 6 — Acceptance + mark M5 done

**Files:**
- Modify: `MILESTONES.md`

### Step 6.1: Run the full Tool spec suite

```
export PATH="$HOME/.ghcup/bin:$PATH" && stack test --match "OpenCode.Tool" 2>&1 | tail -15
```

Expected: all Tool specs pass (TypesSpec, ReadFileSpec, WriteFileSpec, EditFileSpec, RegistrySpec).

### Step 6.2: Run the spec acceptance round-trip from MILESTONES.md

This is the literal acceptance criterion: `runAppM env $ executeTool reg "write_file" (object ["path" .= "/tmp/x", "content" .= "hi"])` returns `Right "wrote 2 bytes to /tmp/x"` and `/tmp/x` contains `"hi"`.

Create a one-shot verification script at `verify/M5Acceptance.hs`:

```haskell
module Main where

import qualified Data.Aeson as Aeson
import qualified Data.ByteString.Lazy.Char8 as L8
import Data.Aeson ((.=))
import System.IO (hPutStrLn, stderr)
import System.Exit (exitFailure)
import qualified Data.Text as Text

import OpenCode.App (AppEnv (..), runAppM)
import OpenCode.Tool.Registry (defaultBuiltinRegistry)
import OpenCode.Tool.Types (executeTool)

main :: IO ()
main = do
  let env = AppEnv { envConfig = undefined, envDb = undefined, envRegistry = defaultBuiltinRegistry }
      args = Aeson.object ["path" .= ("/tmp/x" :: Text.Text), "content" .= ("hi" :: Text.Text)]
  result <- runAppM env (executeTool defaultBuiltinRegistry "write_file" args)
  case result of
    Right "wrote 2 bytes to /tmp/x" -> do
      contents <- readFile "/tmp/x"
      if contents == "hi"
        then putStrLn "M5 acceptance OK"
        else do
          hPutStrLn stderr ("FAIL: /tmp/x contains " <> show contents)
          exitFailure
    other -> do
      hPutStrLn stderr ("FAIL: unexpected result: " <> show other)
      exitFailure
```

Add a new executable stanza to `package.yaml` under `executables:`:

```yaml
  m5-acceptance:
    main:         M5Acceptance.hs
    source-dirs:  verify
    dependencies:
      - opencode-hs
      - aeson
      - bytestring
      - text
```

Run:

```
export PATH="$HOME/.ghcup/bin:$PATH" && rm -f /tmp/x && stack run m5-acceptance
```

Expected output: `M5 acceptance OK`.

### Step 6.3: Update `MILESTONES.md` M5 row

Get the M5-starting commit SHA:

```
git -C /Users/dodofk/Misc/opencode-hs log --oneline | grep "M5:" | tail -1
```

In `MILESTONES.md`, find the M5 row in the Status snapshot:

```
| M5  | Tool System: file I/O                  | pending   | —                  |
```

Change to (substitute `<sha>` with the first-M5 commit short SHA):

```
| M5  | Tool System: file I/O                  | done      | `<sha>..`          |
```

### Step 6.4: Commit and push

```
git -C /Users/dodofk/Misc/opencode-hs add verify/M5Acceptance.hs package.yaml opencode-hs.cabal MILESTONES.md
git -C /Users/dodofk/Misc/opencode-hs commit -m "M5: acceptance verification + mark milestone done"
git -C /Users/dodofk/Misc/opencode-hs push origin main
```

### Step 6.5: Watch CI

```
gh -R dodofk/opencode-hs run watch
```

Expected: all 3 jobs green.

---

## Out of scope for M5 (do NOT add)

- **Bash, Glob, Grep tools** — M7. The GADT constructors exist but stay unimplemented.
- **Tool argument validation against JSON Schema** — the Aeson `FromJSON` decoder is sufficient at this milestone; JSON-Schema-level validation is a M12 hardening item.
- **Per-tool timeout** — the executor runs synchronously; M12 may add per-tool timeouts.
- **Audit log of tool invocations** — out of scope; M6 session loop emits `ToolStarted`/`ToolFinished` events that can serve as a log.
- **Tool-call retries on transient errors** — out of scope.
- **A separate JSON Schema module** — schemas live inline in each tool's source file for now; can be extracted in M12 if duplication grows.
- **Anything from M6+ (Session loop, TUI, CLI).**

## Notes for the next milestone (M6 — Session Loop)

- `OpenCode.Tool.Registry.defaultBuiltinRegistry` is ready for M6's `agentic` loop to consume.
- `executeTool :: ToolRegistry -> Text -> Value -> AppM Text` is the dispatch entry point M6 will call from inside the agentic loop on every `ToolCallEnd` event.
- `AppEnv.envRegistry` is in place; M6 just reads it via `asks envRegistry`.
- The `App.Error` / `App.Types` split is ready to absorb M6's additional fields (`envEventChan`, `envAbort`) without further cycle-breaking work.
- `OpenCode.LLM.Mock.mockStreamCompletion` (from M4) is the right test fixture for M6's session-loop tests; pair it with `defaultBuiltinRegistry` to verify the end-to-end loop.
