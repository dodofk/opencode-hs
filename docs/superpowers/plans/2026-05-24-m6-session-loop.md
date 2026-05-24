# M6 — Session Loop Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** An agentic conversation loop that drives LLM streaming and tool execution to a terminal state, emitting `SessionEvent`s into the `envEventChan` for the TUI to consume.

**Architecture:** `OpenCode.Session.agentic` consumes a `Streamer = LLMRequest -> ConduitT () StreamEvent (ResourceT IO) ()` (which is `streamOpenAI` in production, `mockStreamCompletion`-derived in tests). It drains the full stream into a list in `IO`, then processes the events inside `AppM`, accumulating `MessagePart`s, executing tool calls via `executeTool`, persisting the assembled assistant `Message`, and recursing if any tool ran (capped at 10 rounds). Abort is checked between rounds (not mid-stream), keeping the design simple while honoring the spec's abort test. `SessionEvent`s are emitted to `envEventChan` so the M9 TUI can render the loop's progress.

**Tech stack:** `brick.BChan` (for `envEventChan`), `stm.TVar` (for `envAbort`), `conduit` + `conduit-extra`, existing `OpenCode.LLM.OpenAI.streamOpenAI` and `OpenCode.LLM.Mock.mockStreamCompletion`. `Diff`, `aeson`, `sqlite-simple`, `text` — all already in deps.

---

## Spec resolution items (from final M5 review)

Before the M6-specific work, two carryover items from M5 are addressed up-front in Task 2:
- `MILESTONES.md` §M5 has a stale `registerTool :: Text -> SomeTool -> ToolRegistry -> ToolRegistry` signature; implementation correctly takes only `SomeTool`. One-line doc fix.
- The `envRegistry` vs explicit-registry ambiguity in `verify/M5Acceptance.hs` — addressed by introducing `askExecuteTool :: Text -> Value -> AppM Text` in `OpenCode.App` and using it from the acceptance driver. Establishes the pattern M6's `agentic` will follow.

---

## Skeleton vs spec reconciliation

The M0 skeleton at `src/OpenCode/Session.hs` has signatures that DON'T match the M6 spec:

| Skeleton | Spec | Reconciliation |
| -------- | ---- | -------------- |
| `createSession :: ModelId -> AppM SessionId` | `createSession :: ModelId -> AppM Session` | Spec wins — return the full `Session`. |
| `loadSession :: SessionId -> AppM ()` | `loadSession :: SessionId -> AppM (Maybe Session)` | Spec wins — return the loaded session. |
| `abortSession :: SessionId -> AppM ()` | `abortSession :: AppM ()` | Spec wins — drop the parameter; abort is a global env flag. |
| `RunState` in `OpenCode.Session` | RunState in `OpenCode.Session.Events` (with `SessionEvent`) | Move to `Session.Events`; re-export from `Session` for backward compat. |

These reshapes happen in Tasks 4, 7, and 1 respectively.

---

## File structure

| Path | Action | Responsibility |
| ---- | ------ | -------------- |
| `src/OpenCode/Session/Events.hs` | create | `SessionEvent` ADT + `RunState` (leaf module, no project deps beyond `OpenCode.Types`) |
| `src/OpenCode/App/Types.hs` | edit | Add `envEventChan :: BChan SessionEvent` and `envAbort :: TVar Bool` to `AppEnv` |
| `src/OpenCode/App.hs` | edit | Add `askExecuteTool` helper; re-export `envEventChan`/`envAbort` via `AppEnv (..)` |
| `src/OpenCode/Session/Prompt.hs` | create | `systemPrompt :: ToolRegistry -> Text` builder |
| `src/OpenCode/Session.hs` | edit (large) | Real `createSession`/`loadSession`/`processUserMessage`/`agentic`/`abortSession`; re-export `RunState` from `Session.Events` |
| `src/OpenCode/LLM/Types.hs` | edit | Add `Streamer` type alias |
| `src/OpenCode/LLM/Mock.hs` | edit | Add `scriptedStreamer :: IORef [[StreamEvent]] -> Streamer` for multi-round tests |
| `test/OpenCode/TestEnv.hs` | create | `withTestEnv :: (AppEnv -> Session -> IO a) -> IO a` shared test helper |
| `test/OpenCode/Session/EventsSpec.hs` | create | Shape tests for `SessionEvent`/`RunState` |
| `test/OpenCode/Session/PromptSpec.hs` | create | Tests for `systemPrompt` |
| `test/OpenCode/SessionSpec.hs` | replace | Real session-loop tests (covers `createSession`/`loadSession`/`processUserMessage`/`agentic`/`abortSession`) |
| `test/OpenCode/Tool/TypesSpec.hs` | edit | Add `envEventChan = undefined, envAbort = undefined` to env helper |
| `test/OpenCode/Tool/ReadFileSpec.hs` | edit | Same |
| `test/OpenCode/Tool/WriteFileSpec.hs` | edit | Same |
| `test/OpenCode/Tool/EditFileSpec.hs` | edit | Same |
| `test/OpenCode/Tool/RegistrySpec.hs` | edit | Same (this one DOES exercise the registry, but agentic still uses undefined for chan/abort) |
| `verify/M5Acceptance.hs` | edit | Use `askExecuteTool` instead of explicit `defaultBuiltinRegistry` arg; add real `BChan`/`TVar` for new fields |
| `verify/M6Acceptance.hs` | create | End-to-end mock-driven acceptance driver |
| `package.yaml` | edit | Add `OpenCode.Session.Events`, `OpenCode.Session.Prompt` to exposed-modules; add `m6-acceptance` executable |
| `MILESTONES.md` | edit | (Task 2) fix stale `registerTool` signature in §M5; (Task 9) mark M6 done |

The `hs-boot` file for `App.Types` does NOT need updating: it declares `data AppEnv` abstractly, so adding fields to the real definition doesn't require boot changes.

---

## Toolchain note

`stack`/`ghc` at `~/.ghcup/bin` — prefix every Bash with `export PATH="$HOME/.ghcup/bin:$PATH" &&`. `hlint` at `/opt/homebrew/bin/hlint`.

---

## Task 1 — `OpenCode.Session.Events` (SessionEvent + RunState)

**Files:**
- Create: `src/OpenCode/Session/Events.hs`
- Create: `test/OpenCode/Session/EventsSpec.hs`
- Edit: `package.yaml` (add new module to exposed-modules)

### Step 1.1: Write the failing test

Create `test/OpenCode/Session/EventsSpec.hs`:

```haskell
module OpenCode.Session.EventsSpec (spec) where

import Test.Hspec

import OpenCode.Session.Events

spec :: Spec
spec = do
  describe "RunState shape" $ do

    it "Idle, RunningLLM, AwaitingInput are distinct" $ do
      Idle `shouldNotBe` RunningLLM
      RunningLLM `shouldNotBe` AwaitingInput
      Idle `shouldNotBe` AwaitingInput

    it "RunningTool carries the tool name" $
      RunningTool "bash" `shouldNotBe` RunningTool "grep"

  describe "SessionEvent shape" $ do

    it "PartialText carries the text" $
      PartialText "hi" `shouldNotBe` PartialText "bye"

    it "ToolStarted / ToolFinished are distinct constructors" $
      ToolStarted "bash" `shouldNotBe` ToolFinished "bash" "ok"

    it "RunStateChanged wraps a RunState" $
      RunStateChanged Idle `shouldNotBe` RunStateChanged RunningLLM

    it "ErrorOccurred carries a message" $
      ErrorOccurred "boom" `shouldNotBe` ErrorOccurred "kaboom"
```

### Step 1.2: Run tests to confirm fail

```
export PATH="$HOME/.ghcup/bin:$PATH" && stack test --match "OpenCode.Session.Events" 2>&1 | tail -10
```

Expected: doesn't compile (`OpenCode.Session.Events` doesn't exist).

### Step 1.3: Create `src/OpenCode/Session/Events.hs`

```haskell
-- | Session loop event types: 'SessionEvent' (drained from streaming) and
-- 'RunState' (current pipeline state).
--
-- Leaf module — depends only on 'OpenCode.Types' for 'Message'. Lives below
-- 'OpenCode.Session' in the dependency graph so 'OpenCode.App.Types' can
-- reference 'SessionEvent' without inducing a cycle.
module OpenCode.Session.Events
  ( SessionEvent (..)
  , RunState (..)
  ) where

import Data.Text (Text)
import OpenCode.Types (Message)

-- | What the session loop is currently doing. The TUI reads this for
-- status-bar rendering.
data RunState
  = Idle
  | RunningLLM
  | RunningTool Text    -- ^ currently-executing tool name
  | AwaitingInput
  deriving stock (Show, Eq)

-- | An event emitted by the session loop onto 'envEventChan'.
data SessionEvent
  = MessageAppended Message
      -- ^ A complete 'Message' was just persisted.
  | PartialText Text
      -- ^ A streaming text delta from the LLM.
  | ToolStarted Text
      -- ^ A tool execution is about to begin (carries the tool name).
  | ToolFinished Text Text
      -- ^ A tool execution completed (tool name, output text).
  | RunStateChanged RunState
      -- ^ The session's 'RunState' transitioned.
  | ErrorOccurred Text
      -- ^ An error to display to the user (transient; doesn't terminate the loop).
  deriving stock (Show, Eq)
```

### Step 1.4: Update `package.yaml`

In `library: exposed-modules:`, add `OpenCode.Session.Events` alphabetically (between `OpenCode.Session` and `OpenCode.Tool.*`).

### Step 1.5: Build + test

```
export PATH="$HOME/.ghcup/bin:$PATH" && stack build 2>&1 | tail -5 && stack test --match "OpenCode.Session.Events" 2>&1 | tail -10
```

Expected: clean build; all 6 EventsSpec specs pass. Full suite climbs by 6 (113 → 119).

### Step 1.6: hlint + commit

```
hlint src app test verify 2>&1 | tail -3
git add src/OpenCode/Session/Events.hs test/OpenCode/Session/EventsSpec.hs package.yaml opencode-hs.cabal
git commit -m "M6: OpenCode.Session.Events (SessionEvent + RunState ADTs)"
```

---

## Task 2 — AppEnv extension (`envEventChan` + `envAbort`) + `askExecuteTool` + M5 spec fix

**Files:**
- Edit: `src/OpenCode/App/Types.hs`
- Edit: `src/OpenCode/App.hs`
- Edit: `test/OpenCode/Tool/TypesSpec.hs`
- Edit: `test/OpenCode/Tool/ReadFileSpec.hs`
- Edit: `test/OpenCode/Tool/WriteFileSpec.hs`
- Edit: `test/OpenCode/Tool/EditFileSpec.hs`
- Edit: `test/OpenCode/Tool/RegistrySpec.hs`
- Edit: `verify/M5Acceptance.hs`
- Edit: `MILESTONES.md`

### Step 2.1: Extend `AppEnv` in `src/OpenCode/App/Types.hs`

Replace the existing definition:

```haskell
data AppEnv = AppEnv
  { envConfig   :: Config
  , envDb       :: Connection
  , envRegistry :: ToolRegistry
  -- envEventChan, envAbort: added in M6
  }
```

with:

```haskell
data AppEnv = AppEnv
  { envConfig    :: Config
  , envDb        :: Connection
  , envRegistry  :: ToolRegistry
  , envEventChan :: BChan SessionEvent
  , envAbort     :: TVar Bool
  }
```

Add the necessary imports (top of file):

```haskell
import Brick.BChan (BChan)
import Control.Concurrent.STM (TVar)

import OpenCode.Session.Events (SessionEvent)
```

### Step 2.2: Add `askExecuteTool` to `src/OpenCode/App.hs`

Append a new helper to the existing list. Open the file. Find the existing `askConfig`:

```haskell
askConfig :: AppM Config
askConfig = asks envConfig
```

Append below it:

```haskell
-- | Dispatch a tool call by name, decoding the JSON arguments and rendering
-- the output. Reads the registry from 'envRegistry' so callers don't have to
-- thread it explicitly. Raises 'ToolError' on unknown name or decode failure.
askExecuteTool :: Text -> Aeson.Value -> AppM Text
askExecuteTool name args = do
  reg <- asks envRegistry
  Tool.executeTool reg name args
```

Add imports at the top of the file:

```haskell
import qualified Data.Aeson as Aeson
import qualified OpenCode.Tool.Types as Tool
```

And add `askExecuteTool` to the export list:

```haskell
    -- * Helpers
  , liftIO'
  , throwAppError
  , askConfig
  , askExecuteTool
```

### Step 2.3: Update test helpers in M5 spec files

Each of these files has a `run*` helper containing:

```haskell
env = AppEnv { envConfig = undefined, envDb = undefined, envRegistry = undefined }
```

(or `envRegistry = defaultBuiltinRegistry` in RegistrySpec). Update each to:

```haskell
env = AppEnv
  { envConfig    = undefined
  , envDb        = undefined
  , envRegistry  = undefined           -- (or defaultBuiltinRegistry for RegistrySpec)
  , envEventChan = undefined
  , envAbort     = undefined
  }
```

(`undefined` is acceptable here because these tests don't exercise the chan or abort.)

Files to edit:
- `test/OpenCode/Tool/TypesSpec.hs`
- `test/OpenCode/Tool/ReadFileSpec.hs`
- `test/OpenCode/Tool/WriteFileSpec.hs`
- `test/OpenCode/Tool/EditFileSpec.hs`
- `test/OpenCode/Tool/RegistrySpec.hs`

### Step 2.4: Update `verify/M5Acceptance.hs` to use `askExecuteTool` + real chan/abort

The current file invokes `executeTool defaultBuiltinRegistry "write_file" args` after putting `defaultBuiltinRegistry` in `envRegistry`. Both paths produce the same result, but the duplication is confusing for the M6 implementer.

Replace the existing `main` with:

```haskell
module Main where

import qualified Brick.BChan as BChan
import qualified Control.Concurrent.STM as STM
import qualified Data.Aeson as Aeson
import Data.Aeson ((.=))
import qualified Data.Text as Text
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)

import OpenCode.App (AppEnv (..), askExecuteTool, runAppM)
import OpenCode.Tool.Registry (defaultBuiltinRegistry)

main :: IO ()
main = do
  chan      <- BChan.newBChan 100
  abortVar  <- STM.newTVarIO False
  let env  = AppEnv
        { envConfig    = undefined
        , envDb        = undefined
        , envRegistry  = defaultBuiltinRegistry
        , envEventChan = chan
        , envAbort     = abortVar
        }
      args = Aeson.object
        [ "path"    .= ("/tmp/x" :: Text.Text)
        , "content" .= ("hi"     :: Text.Text)
        ]
  result <- runAppM env (askExecuteTool "write_file" args)
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

(The `askExecuteTool` call now reads the registry from `envRegistry` rather than passing it explicitly. `chan` and `abortVar` get real values to match the new `AppEnv` shape.)

### Step 2.5: Fix the stale `registerTool` signature in `MILESTONES.md`

In `MILESTONES.md` §M5 "Tasks" section, find the line:

```
  - `registerTool :: Text -> SomeTool -> ToolRegistry -> ToolRegistry`.
```

Change to:

```
  - `registerTool :: SomeTool -> ToolRegistry -> ToolRegistry` (name extracted from 'toolName' field of `SomeTool`).
```

### Step 2.6: Build + test

```
export PATH="$HOME/.ghcup/bin:$PATH" && stack build 2>&1 | tail -10 && stack test 2>&1 | tail -5
```

Expected: clean build (no warnings). All 119 prior tests still pass.

Also run the M5 acceptance to confirm the `askExecuteTool` swap didn't break it:

```
rm -f /tmp/x && stack run m5-acceptance
```

Expected: `M5 acceptance OK`.

### Step 2.7: hlint + commit

```
hlint src app test verify 2>&1 | tail -3
git add src/OpenCode/App/Types.hs src/OpenCode/App.hs test/OpenCode/Tool/TypesSpec.hs test/OpenCode/Tool/ReadFileSpec.hs test/OpenCode/Tool/WriteFileSpec.hs test/OpenCode/Tool/EditFileSpec.hs test/OpenCode/Tool/RegistrySpec.hs verify/M5Acceptance.hs MILESTONES.md
git commit -m "M6: AppEnv adds envEventChan+envAbort; askExecuteTool helper"
```

---

## Task 3 — `OpenCode.Session.Prompt` (systemPrompt builder)

**Files:**
- Create: `src/OpenCode/Session/Prompt.hs`
- Create: `test/OpenCode/Session/PromptSpec.hs`
- Edit: `package.yaml` (add new module)

### Step 3.1: Write the failing test

Create `test/OpenCode/Session/PromptSpec.hs`:

```haskell
module OpenCode.Session.PromptSpec (spec) where

import qualified Data.Map.Strict as Map
import qualified Data.Text as Text
import Test.Hspec

import OpenCode.Session.Prompt (systemPrompt)
import OpenCode.Tool.Registry (defaultBuiltinRegistry)
import OpenCode.Tool.Types (ToolRegistry (..), unRegistry)

spec :: Spec
spec = describe "systemPrompt" $ do

  it "includes a non-empty header section" $ do
    let p = systemPrompt defaultBuiltinRegistry
    Text.length p `shouldSatisfy` (> 0)

  it "mentions every tool name from the registry" $ do
    let p     = systemPrompt defaultBuiltinRegistry
        names = Map.keys (unRegistry defaultBuiltinRegistry)
    mapM_ (\name -> Text.unpack p `shouldContain` Text.unpack name) names

  it "produces an empty-registry prompt that still has the header" $ do
    let p = systemPrompt (ToolRegistry Map.empty)
    Text.length p `shouldSatisfy` (> 0)
    Text.unpack p `shouldContain` "AI coding"   -- a recognizable header phrase
```

### Step 3.2: Run tests to confirm fail

```
export PATH="$HOME/.ghcup/bin:$PATH" && stack test --match "OpenCode.Session.Prompt" 2>&1 | tail -10
```

Expected: doesn't compile (`OpenCode.Session.Prompt` doesn't exist).

### Step 3.3: Create `src/OpenCode/Session/Prompt.hs`

```haskell
-- | Builds the system-prompt string that gets passed to the LLM at the start
-- of every request. Includes a static agent header plus a per-tool block
-- enumerating available tools and their descriptions.
module OpenCode.Session.Prompt
  ( systemPrompt
  ) where

import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as Text

import OpenCode.Tool.Types (SomeTool (..), ToolRegistry (..))

-- | Build the system prompt for the given registry.
systemPrompt :: ToolRegistry -> Text
systemPrompt (ToolRegistry reg) =
  let toolBlock = if Map.null reg
        then ""
        else "\n\nAvailable tools:\n" <> Text.unlines (map describeTool (Map.elems reg))
  in header <> toolBlock
  where
    header =
      "You are an AI coding assistant. You can read, write, and edit files\n\
      \via the tools listed below. When you need to make a change, call the\n\
      \appropriate tool. Be concise."

    describeTool t = "  - " <> toolName t <> ": " <> toolDesc t
```

### Step 3.4: Update `package.yaml`

In `library: exposed-modules:`, add `OpenCode.Session.Prompt` alphabetically (after `OpenCode.Session.Events`).

### Step 3.5: Build + test

```
export PATH="$HOME/.ghcup/bin:$PATH" && stack build 2>&1 | tail -5 && stack test --match "OpenCode.Session.Prompt" 2>&1 | tail -10
```

Expected: 3 PromptSpec specs pass. Full suite 122 / 0.

### Step 3.6: hlint + commit

```
hlint src app test verify 2>&1 | tail -3
git add src/OpenCode/Session/Prompt.hs test/OpenCode/Session/PromptSpec.hs package.yaml opencode-hs.cabal
git commit -m "M6: OpenCode.Session.Prompt (systemPrompt with per-tool blocks)"
```

---

## Task 4 — `createSession` + `loadSession`

**Files:**
- Edit: `src/OpenCode/Session.hs`
- Replace: `test/OpenCode/SessionSpec.hs` (M0 placeholder)
- Create: `test/OpenCode/TestEnv.hs` (shared test helper for subsequent tasks)

### Step 4.1: Create the shared test-env helper

Create `test/OpenCode/TestEnv.hs`:

```haskell
-- | Shared test fixture: an 'AppEnv' backed by an in-memory SQLite DB, the
-- default builtin tool registry, a fresh 'BChan', and a fresh abort 'TVar'.
-- Used by the session-loop tests so each spec gets a clean environment.
module OpenCode.TestEnv
  ( withTestEnv
  ) where

import qualified Brick.BChan as BChan
import Control.Exception (bracket)
import qualified Control.Concurrent.STM as STM
import Data.Time (UTCTime (..), fromGregorian)
import Database.SQLite.Simple (close)

import OpenCode.App (AppEnv (..))
import OpenCode.Config (Config (..), ProviderConfig (..))
import OpenCode.DB (insertSession, newSessionId, openDb)
import OpenCode.Tool.Registry (defaultBuiltinRegistry)
import OpenCode.Types
  ( ApiKey (..)
  , ModelId (..)
  , ProviderId (..)
  , Session (..)
  )

-- | Set up an in-memory environment, create a starter session, run the
-- caller's action, then tear down. The caller gets the env and the session
-- id of the inserted starter session.
withTestEnv :: (AppEnv -> Session -> IO a) -> IO a
withTestEnv action = bracket (openDb ":memory:") close $ \conn -> do
  chan     <- BChan.newBChan 100
  abortVar <- STM.newTVarIO False
  sid      <- newSessionId
  let cfg = Config
        { providers    = ProviderConfig
            { openaiKey    = Just (ApiKey "sk-test-stub")
            , anthropicKey = Nothing
            }
        , defaultModel = ModelId OpenAI "gpt-4o"
        }
      session = Session
        { sessionId      = sid
        , sessionTitle   = "test session"
        , sessionModel   = ModelId OpenAI "gpt-4o"
        , sessionCreated = UTCTime (fromGregorian 2026 5 24) 0
        }
  insertSession conn session
  let env = AppEnv
        { envConfig    = cfg
        , envDb        = conn
        , envRegistry  = defaultBuiltinRegistry
        , envEventChan = chan
        , envAbort     = abortVar
        }
  action env session
```

### Step 4.2: Replace the M0 placeholder spec with real createSession/loadSession tests

Overwrite `test/OpenCode/SessionSpec.hs`:

```haskell
module OpenCode.SessionSpec (spec) where

import qualified Brick.BChan as BChan
import Control.Exception (bracket)
import qualified Control.Concurrent.STM as STM
import Control.Monad.Except (runExceptT)
import Control.Monad.Reader (runReaderT)
import Database.SQLite.Simple (close)
import Test.Hspec

import OpenCode.App (AppEnv (..))
import OpenCode.Config (Config (..), ProviderConfig (..))
import OpenCode.DB (openDb)
import OpenCode.Session (createSession, loadSession)
import OpenCode.Tool.Registry (defaultBuiltinRegistry)
import OpenCode.Types
  ( ApiKey (..)
  , ModelId (..)
  , ProviderId (..)
  , Session (..)
  , SessionId (..)
  )

spec :: Spec
spec = do
  describe "createSession" $ do

    it "creates a session with the given model and returns it" $
      withFreshEnv $ \env -> do
        result <- runExceptT $ runReaderT
          (createSession (ModelId OpenAI "gpt-4o")) env
        case result of
          Right s -> do
            sessionModel s    `shouldBe` ModelId OpenAI "gpt-4o"
            sessionTitle s    `shouldBe` "untitled"
          Left e -> expectationFailure (show e)

    it "persists the session so it can be retrieved" $
      withFreshEnv $ \env -> do
        result <- runExceptT $ runReaderT
          (createSession (ModelId OpenAI "gpt-4o")) env
        case result of
          Right s -> do
            loaded <- runExceptT $ runReaderT (loadSession (sessionId s)) env
            loaded `shouldBe` Right (Just s)
          Left e -> expectationFailure (show e)

  describe "loadSession" $ do

    it "returns Nothing for an unknown SessionId" $
      withFreshEnv $ \env -> do
        result <- runExceptT $ runReaderT
          (loadSession (SessionId "no-such-session")) env
        result `shouldBe` Right Nothing

-- ---------------------------------------------------------------------------
-- Helper: env with an empty in-memory DB (no starter session)
-- ---------------------------------------------------------------------------

withFreshEnv :: (AppEnv -> IO a) -> IO a
withFreshEnv action = bracket (openDb ":memory:") close $ \conn -> do
  chan     <- BChan.newBChan 100
  abortVar <- STM.newTVarIO False
  let cfg = Config
        { providers    = ProviderConfig
            { openaiKey    = Just (ApiKey "sk-test-stub")
            , anthropicKey = Nothing
            }
        , defaultModel = ModelId OpenAI "gpt-4o"
        }
      env = AppEnv
        { envConfig    = cfg
        , envDb        = conn
        , envRegistry  = defaultBuiltinRegistry
        , envEventChan = chan
        , envAbort     = abortVar
        }
  action env
```

### Step 4.3: Run tests to confirm fail

```
export PATH="$HOME/.ghcup/bin:$PATH" && stack test --match "createSession" 2>&1 | tail -15
```

Expected: 3 failures because `createSession :: ModelId -> AppM SessionId` (skeleton) doesn't match `createSession :: ModelId -> AppM Session` (spec), and `loadSession :: SessionId -> AppM (Maybe Session)` doesn't exist with that signature.

### Step 4.4: Replace `createSession` and `loadSession` in `src/OpenCode/Session.hs`

Open `src/OpenCode/Session.hs`. The current file has:

```haskell
module OpenCode.Session
  ( RunState (..)
  , createSession
  , loadSession
  , processUserMessage
  , abortSession
  ) where
```

with a `RunState` definition and four `error` stubs.

Rewrite the file (`processUserMessage`, `abortSession`, and `agentic` get implemented in later tasks; for now stub them but make their type signatures match the spec):

```haskell
-- | Agentic conversation loop: drives LLM streaming and tool execution.
module OpenCode.Session
  ( -- * Re-exports
    RunState (..)
    -- * Session management
  , createSession
  , loadSession
    -- * Stubs (filled in by later M6 tasks)
  , processUserMessage
  , abortSession
  ) where

import Control.Monad.IO.Class (liftIO)
import Control.Monad.Reader (asks)
import Data.Text (Text)
import Data.Time (getCurrentTime)

import OpenCode.App (AppEnv (..), AppM)
import qualified OpenCode.DB as DB
import OpenCode.Session.Events (RunState (..))
import OpenCode.Types (ModelId, Session (..), SessionId)

-- ---------------------------------------------------------------------------
-- Session management
-- ---------------------------------------------------------------------------

-- | Create a new session with the given model. Default title is "untitled".
-- Persists immediately via 'insertSession'.
createSession :: ModelId -> AppM Session
createSession m = do
  sid  <- liftIO DB.newSessionId
  now  <- liftIO getCurrentTime
  let session = Session
        { sessionId      = sid
        , sessionTitle   = "untitled"
        , sessionModel   = m
        , sessionCreated = now
        }
  conn <- asks envDb
  liftIO (DB.insertSession conn session)
  pure session

-- | Look up a session by id.
loadSession :: SessionId -> AppM (Maybe Session)
loadSession sid = do
  conn <- asks envDb
  liftIO (DB.getSession conn sid)

-- ---------------------------------------------------------------------------
-- Stubs (filled in by later M6 tasks)
-- ---------------------------------------------------------------------------

processUserMessage :: SessionId -> Text -> AppM ()
processUserMessage _ _ = error "OpenCode.Session.processUserMessage: not yet implemented (M6 Task 8)"

abortSession :: AppM ()
abortSession = error "OpenCode.Session.abortSession: not yet implemented (M6 Task 7)"
```

Note: the export of `RunState` is now a re-export from `OpenCode.Session.Events`. Existing consumers that `import OpenCode.Session (RunState (..))` keep working.

### Step 4.5: Build + test

```
export PATH="$HOME/.ghcup/bin:$PATH" && stack build 2>&1 | tail -5 && stack test --match "OpenCode.Session" 2>&1 | tail -10
```

Expected: clean build; 3 specs pass (the SessionSpec); full suite 125 / 0.

### Step 4.6: Add the `emitEvent` helper

Append to `src/OpenCode/Session.hs` (before the stubs at the bottom):

```haskell
-- ---------------------------------------------------------------------------
-- Event emission helper
-- ---------------------------------------------------------------------------

-- | Push a 'SessionEvent' onto 'envEventChan'. Used by the agentic loop to
-- broadcast progress to the TUI (M9). 'BChan.writeBChan' blocks if the
-- channel is full — for production sizing of 100+ this never blocks in
-- practice.
emitEvent :: SessionEvent -> AppM ()
emitEvent evt = do
  chan <- asks envEventChan
  liftIO (BChan.writeBChan chan evt)
```

Add imports:

```haskell
import qualified Brick.BChan as BChan
import OpenCode.Session.Events (RunState (..), SessionEvent (..))
```

(Replace the existing `import OpenCode.Session.Events (RunState (..))` with the combined form.)

Add `emitEvent` to the module's export list.

### Step 4.7: hlint + commit

```
hlint src app test verify 2>&1 | tail -3
git add src/OpenCode/Session.hs test/OpenCode/SessionSpec.hs test/OpenCode/TestEnv.hs
git commit -m "M6: createSession + loadSession + emitEvent + TestEnv helper"
```

---

## Task 5 — `agentic` loop (text-only, one round)

**Files:**
- Edit: `src/OpenCode/LLM/Types.hs` (add `Streamer` type alias)
- Edit: `src/OpenCode/LLM/Mock.hs` (add `staticStreamer` helper)
- Edit: `src/OpenCode/Session.hs` (add `agentic` for text-only case)
- Edit: `test/OpenCode/SessionSpec.hs` (add agentic text-only test)

### Step 5.1: Add `Streamer` type alias to `src/OpenCode/LLM/Types.hs`

Open `OpenCode/LLM/Types.hs`. Append after the existing `LLMProvider` class definition:

```haskell
-- ---------------------------------------------------------------------------
-- Streaming function alias
-- ---------------------------------------------------------------------------

-- | A streaming-completion function. Pure with respect to provider choice:
-- production code partial-applies 'streamOpenAI' or 'streamAnthropic' to get
-- one of these; tests use mock-based variants.
type Streamer = LLMRequest -> ConduitT () StreamEvent (ResourceT IO) ()
```

Add `Streamer` to the module's export list.

### Step 5.2: Add `staticStreamer` to `src/OpenCode/LLM/Mock.hs`

Open `OpenCode/LLM/Mock.hs`. Append after `mockStreamCompletion`:

```haskell
-- | Adapt 'mockStreamCompletion' to the 'Streamer' type by discarding the
-- 'LLMRequest' and emitting the same scripted events on every call.
staticStreamer :: [StreamEvent] -> Streamer
staticStreamer scripted = const (mockStreamCompletion scripted)
```

Add to imports: `import OpenCode.LLM.Types (Streamer)`.

Add `staticStreamer` to the module's export list.

### Step 5.3: Add the agentic text-only test

Append to `test/OpenCode/SessionSpec.hs` (inside the existing `spec`):

```haskell
  describe "agentic (text-only, one round)" $ do

    it "builds an assistant message from a scripted text-only stream" $ do
      withTestEnv $ \env session -> do
        let streamer = staticStreamer
              [ TextDelta "Hello"
              , TextDelta " world"
              , StreamDone (Usage 5 2 Nothing Nothing)
              ]
        result <- runExceptT $ runReaderT
          (agentic streamer (sessionId session) []) env
        case result of
          Right msgs -> do
            length msgs `shouldBe` 1
            -- The single message is the assistant response.
            let m = head msgs
            msgRole m `shouldBe` RoleAssistant
            NE.toList (msgParts m) `shouldBe` [TextPart "Hello world"]
          Left err -> expectationFailure (show err)

    it "persists the assistant message to the DB" $ do
      withTestEnv $ \env session -> do
        let streamer = staticStreamer [TextDelta "hi", StreamDone (Usage 1 1 Nothing Nothing)]
        _ <- runExceptT $ runReaderT
          (agentic streamer (sessionId session) []) env
        stored <- DB.getMessages (envDb env) (sessionId session)
        length stored `shouldBe` 1
        msgRole (head stored) `shouldBe` RoleAssistant
```

Add imports to `test/OpenCode/SessionSpec.hs`:

```haskell
import qualified Data.List.NonEmpty as NE
import qualified OpenCode.DB as DB
import OpenCode.LLM.Mock (staticStreamer)
import OpenCode.Session (agentic)
import OpenCode.TestEnv (withTestEnv)
import OpenCode.Types
  ( MessagePart (..)
  , Role (..)
  , StreamEvent (..)
  , Usage (..)
  , msgRole
  , msgParts
  )
```

(`withTestEnv` from Task 4. `agentic` is the new function being implemented.)

### Step 5.4: Run tests to confirm fail

```
export PATH="$HOME/.ghcup/bin:$PATH" && stack test --match "agentic" 2>&1 | tail -15
```

Expected: doesn't compile (`agentic` not defined or not exported from `OpenCode.Session`).

### Step 5.5: Implement `agentic` (text-only, one-round) in `src/OpenCode/Session.hs`

Replace the file with the expanded version. Build on Task 4's version by adding `agentic` and supporting helpers. Keep the existing `createSession`, `loadSession`, and the stubs for `processUserMessage` / `abortSession`:

```haskell
-- | Agentic conversation loop: drives LLM streaming and tool execution.
module OpenCode.Session
  ( -- * Re-exports
    RunState (..)
    -- * Session management
  , createSession
  , loadSession
    -- * Loop
  , agentic
  , maxToolRounds
    -- * Stubs (filled in by later M6 tasks)
  , processUserMessage
  , abortSession
  ) where

import Conduit ((.|))
import qualified Conduit
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Reader (asks)
import qualified Data.Aeson as Aeson
import Data.List.NonEmpty (NonEmpty)
import qualified Data.List.NonEmpty as NE
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Time (getCurrentTime)

import OpenCode.App (AppEnv (..), AppM)
import qualified OpenCode.DB as DB
import OpenCode.LLM.Types (LLMRequest (..), Streamer)
import OpenCode.Session.Events (RunState (..))
import OpenCode.Session.Prompt (systemPrompt)
import OpenCode.Tool.Types
  ( SomeTool (..)
  , ToolRegistry (..)
  , someToolDefinition
  )
import OpenCode.Types
  ( Message (..)
  , MessageId
  , MessagePart (..)
  , Role (..)
  , Session (..)
  , SessionId
  , StreamEvent (..)
  , Usage
  )

-- ---------------------------------------------------------------------------
-- Session management
-- ---------------------------------------------------------------------------

createSession :: OpenCode.Types.ModelId -> AppM Session
createSession m = do
  sid  <- liftIO DB.newSessionId
  now  <- liftIO getCurrentTime
  let session = Session
        { sessionId      = sid
        , sessionTitle   = "untitled"
        , sessionModel   = m
        , sessionCreated = now
        }
  conn <- asks envDb
  liftIO (DB.insertSession conn session)
  pure session

loadSession :: SessionId -> AppM (Maybe Session)
loadSession sid = do
  conn <- asks envDb
  liftIO (DB.getSession conn sid)

-- ---------------------------------------------------------------------------
-- The agentic loop
-- ---------------------------------------------------------------------------

-- | Maximum number of tool rounds before forcing termination.
maxToolRounds :: Int
maxToolRounds = 10

-- | Drive the agentic loop: stream a completion, accumulate parts, execute
-- tool calls, persist the assistant message, and recurse if any tool ran
-- (capped at 'maxToolRounds'). Returns the assistant messages appended in
-- this call (i.e., NOT including the prior history).
--
-- The 'Streamer' parameter is the streaming-completion function — production
-- callers partial-apply 'OpenCode.LLM.OpenAI.streamOpenAI', tests use
-- 'OpenCode.LLM.Mock.staticStreamer' or 'scriptedStreamer'.
agentic :: Streamer -> SessionId -> [Message] -> AppM [Message]
agentic streamer sid history = go 0 history []
  where
    go :: Int -> [Message] -> [Message] -> AppM [Message]
    go round soFar appended = do
      env <- asks id
      emitEvent (RunStateChanged RunningLLM)
      let req = buildRequest env soFar
          stream = streamer req
      events <- liftIO $ Conduit.runResourceT $ Conduit.runConduit $
        stream .| Conduit.sinkList
      mAssist <- buildAssistantMessage events
      case mAssist of
        Nothing -> do
          emitEvent (RunStateChanged Idle)
          pure (reverse appended)
        Just m -> do
          conn <- asks envDb
          liftIO (DB.insertMessage conn sid m)
          emitEvent (MessageAppended m)
          emitEvent (RunStateChanged Idle)
          -- For text-only Task 5: no tool execution yet, so never recurse.
          pure (reverse (m : appended))

buildRequest :: AppEnv -> [Message] -> LLMRequest
buildRequest env history = LLMRequest
  { reqModel        = "gpt-4o"   -- M11 will dispatch by sessionModel
  , reqMessages     = history
  , reqTools        = map someToolDefinition (Map.elems (unRegistry (envRegistry env)))
  , reqSystemPrompt = systemPrompt (envRegistry env)
  , reqMaxTokens    = Nothing
  }

-- | Process a flat list of 'StreamEvent's into one 'Message' (the assistant
-- response). Returns 'Nothing' if the stream produced no parts (no text, no
-- tool calls, just StreamDone/StreamError — e.g., an empty trailing round).
buildAssistantMessage :: [StreamEvent] -> AppM (Maybe Message)
buildAssistantMessage events = do
  let textParts = collectText events
      parts     = textParts
  case NE.nonEmpty parts of
    Nothing -> pure Nothing
    Just ne -> do
      mid <- liftIO DB.newMessageId
      now <- liftIO getCurrentTime
      pure $ Just Message
        { msgId      = mid
        , msgRole    = RoleAssistant
        , msgParts   = ne
        , msgCreated = now
        }

-- | Concatenate consecutive 'TextDelta' events into one 'TextPart'.
-- (Multiple tool-call accumulator paths are added in Task 6.)
collectText :: [StreamEvent] -> [MessagePart]
collectText events =
  let chunks = [t | TextDelta t <- events]
  in if null chunks
       then []
       else [TextPart (Text.concat chunks)]

-- ---------------------------------------------------------------------------
-- Stubs
-- ---------------------------------------------------------------------------

processUserMessage :: SessionId -> Text -> AppM ()
processUserMessage _ _ = error "OpenCode.Session.processUserMessage: not yet implemented (M6 Task 8)"

abortSession :: AppM ()
abortSession = error "OpenCode.Session.abortSession: not yet implemented (M6 Task 7)"
```

(The qualified `OpenCode.Types.ModelId` reference fixes a name collision risk; if the `Types` import already brings `ModelId` into scope unqualified, simplify to `ModelId`.)

Note: `Conduit.sinkList` collects all events into `[StreamEvent]` once `streamer` finishes. For mock streams this is immediate; for real OpenAI streams it blocks until the HTTP body ends. M6's design accepts this trade-off — abort-mid-stream is explicitly out of scope per spec.

### Step 5.6: Run tests to confirm pass

```
export PATH="$HOME/.ghcup/bin:$PATH" && stack test --match "agentic" 2>&1 | tail -10
```

Expected: 2 specs pass. Full suite 127 / 0.

### Step 5.7: hlint + commit

```
hlint src app test verify 2>&1 | tail -3
git add src/OpenCode/LLM/Types.hs src/OpenCode/LLM/Mock.hs src/OpenCode/Session.hs test/OpenCode/SessionSpec.hs
git commit -m "M6: agentic loop (text-only, single round)"
```

---

## Task 6 — `agentic` with tool execution + multi-round

**Files:**
- Edit: `src/OpenCode/LLM/Mock.hs` (add `scriptedStreamer` for multi-round)
- Edit: `src/OpenCode/Session.hs` (extend `agentic` to handle tool calls + recursion)
- Edit: `test/OpenCode/SessionSpec.hs` (add tool-call test)

### Step 6.1: Add `scriptedStreamer` to `src/OpenCode/LLM/Mock.hs`

Append after `staticStreamer`:

```haskell
-- | A multi-round 'Streamer' driven by an 'IORef' of scripted event lists.
-- The first call returns the first list, the second call returns the second,
-- and so on. Used to test the agentic loop's multi-round behavior.
--
-- Construct with 'newScriptedStreamer'; the 'IORef' lives inside the closure
-- so each test gets its own independent state.
scriptedStreamer :: IORef [[StreamEvent]] -> Streamer
scriptedStreamer ref _req = do
  rounds <- liftIO $ readIORef ref
  case rounds of
    []         -> pure ()   -- exhausted: emit no events
    (this:rest) -> do
      liftIO $ writeIORef ref rest
      yieldMany this

-- | Construct a 'scriptedStreamer' with its IORef pre-initialized.
newScriptedStreamer :: [[StreamEvent]] -> IO Streamer
newScriptedStreamer rounds = do
  ref <- newIORef rounds
  pure (scriptedStreamer ref)
```

Add imports:

```haskell
import Control.Monad.IO.Class (liftIO)
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
```

Add `scriptedStreamer` and `newScriptedStreamer` to the export list.

### Step 6.2: Add the multi-round tool-call test

Append to `test/OpenCode/SessionSpec.hs`:

```haskell
  describe "agentic (with tool execution, multi-round)" $ do

    it "executes a tool call and recurses for the next round" $
      withTestEnv $ \env session -> do
        let toolArgs = "{\"path\":\"/tmp/m6-test.txt\",\"content\":\"hi\"}"
            round1 =
              [ ToolCallStart "c1" "write_file"
              , ToolCallArgDelta "c1" toolArgs
              , ToolCallEnd "c1"
              , StreamDone (Usage 50 15 Nothing Nothing)
              ]
            round2 =
              [ TextDelta "Done."
              , StreamDone (Usage 5 2 Nothing Nothing)
              ]
        streamer <- newScriptedStreamer [round1, round2]
        result <- runExceptT $ runReaderT
          (agentic streamer (sessionId session) []) env
        case result of
          Right msgs -> do
            length msgs `shouldBe` 2   -- assistant msg 1 (tool call + result) + assistant msg 2 (text)
            -- Round 1 message: has ToolCallPart and ToolResultPart.
            let m1 = head msgs
            msgRole m1 `shouldBe` RoleAssistant
            (any isToolCall (NE.toList (msgParts m1)))   `shouldBe` True
            (any isToolResult (NE.toList (msgParts m1))) `shouldBe` True
            -- Round 2 message: has TextPart only.
            let m2 = msgs !! 1
            msgRole m2 `shouldBe` RoleAssistant
            NE.toList (msgParts m2) `shouldBe` [TextPart "Done."]
          Left err -> expectationFailure (show err)
        -- And the file actually exists on disk:
        contents <- readFile "/tmp/m6-test.txt"
        contents `shouldBe` "hi"

  where
    isToolCall (ToolCallPart _)   = True
    isToolCall _                  = False
    isToolResult (ToolResultPart _) = True
    isToolResult _                  = False
```

Add imports:

```haskell
import OpenCode.LLM.Mock (newScriptedStreamer)
```

(The `where` clause with `isToolCall`/`isToolResult` attaches to the outermost `spec` do-block; place it at the end after all `describe` blocks. If the test file already has a where clause, fold these into it.)

### Step 6.3: Run tests to confirm fail

```
export PATH="$HOME/.ghcup/bin:$PATH" && stack test --match "executes a tool call" 2>&1 | tail -15
```

Expected: fails — the current `agentic` doesn't handle tool calls at all (Task 5 only does text).

### Step 6.4: Extend `agentic` in `src/OpenCode/Session.hs` to handle tool calls

Replace `buildAssistantMessage` and add tool-execution logic. The full updated implementation:

```haskell
agentic :: Streamer -> SessionId -> [Message] -> AppM [Message]
agentic streamer sid history = go 0 history []
  where
    go :: Int -> [Message] -> [Message] -> AppM [Message]
    go round soFar appended
      | round >= maxToolRounds = pure (reverse appended)
      | otherwise = do
          env <- asks id
          let req    = buildRequest env soFar
              stream = streamer req
          events <- liftIO $ Conduit.runResourceT $ Conduit.runConduit $
            stream .| Conduit.sinkList
          mResult <- buildAssistantMessage events
          case mResult of
            Nothing -> pure (reverse appended)
            Just (m, ranTool) -> do
              conn <- asks envDb
              liftIO (DB.insertMessage conn sid m)
              let nextHistory = soFar ++ [m]
                  nextAppended = m : appended
              if ranTool
                then go (round + 1) nextHistory nextAppended
                else pure (reverse nextAppended)

-- | Process a list of 'StreamEvent's into:
--   * Nothing if no parts were produced (skip persistence)
--   * Just (assistantMessage, ranTool) where ranTool indicates whether any
--     tool was executed (triggers recursion).
buildAssistantMessage :: [StreamEvent] -> AppM (Maybe (Message, Bool))
buildAssistantMessage events = do
  -- 1. Collect text parts (concatenated TextDeltas into one TextPart).
  -- 2. Collect tool calls (Start + accumulated args + End).
  -- 3. For each completed tool call, execute and append ToolResultPart.
  let textParts = collectText events
      toolCalls = collectToolCalls events
  toolPairs <- mapM executeOne toolCalls
  let toolParts = concatMap (\(callPart, resultPart) -> [callPart, resultPart]) toolPairs
      parts     = textParts ++ toolParts
      ranTool   = not (null toolPairs)
  case NE.nonEmpty parts of
    Nothing -> pure Nothing
    Just ne -> do
      mid <- liftIO DB.newMessageId
      now <- liftIO getCurrentTime
      pure $ Just
        ( Message
            { msgId      = mid
            , msgRole    = RoleAssistant
            , msgParts   = ne
            , msgCreated = now
            }
        , ranTool
        )

-- | Pair each completed tool call with the result of executing it.
-- Emits 'ToolStarted'/'ToolFinished' SessionEvents around the execution.
executeOne :: PendingToolCall -> AppM (MessagePart, MessagePart)
executeOne (PendingToolCall callId toolName argsText) = do
  let callPart = ToolCallPart (ToolCall
        { OpenCode.Types.callId    = callId
        , OpenCode.Types.toolName  = toolName
        , OpenCode.Types.arguments = ToolArgs argsText
        })
      argsValue = case Aeson.eitherDecodeStrict (Text.encodeUtf8 argsText) of
        Right v  -> v
        Left _   -> Aeson.Null   -- malformed JSON; askExecuteTool will reject it
  emitEvent (RunStateChanged (RunningTool toolName))
  emitEvent (ToolStarted toolName)
  resultText <- App.askExecuteTool toolName argsValue
                  `catchError` \(ToolError _ msg) -> pure ("tool error: " <> msg)
  emitEvent (ToolFinished toolName resultText)
  let resultPart = ToolResultPart (ToolResult
        { resultCallId = callId
        , content      = resultText
        , isError      = False
        })
  pure (callPart, resultPart)

-- | Internal type tracking a tool call as it's accumulated from stream events.
data PendingToolCall = PendingToolCall
  { ptcCallId   :: Text
  , ptcToolName :: Text
  , ptcArgs     :: Text
  }

-- | Walk the event list and emit one 'PendingToolCall' per matched
-- (ToolCallStart, accumulated ArgDeltas, ToolCallEnd) triple.
collectToolCalls :: [StreamEvent] -> [PendingToolCall]
collectToolCalls = go Map.empty []
  where
    go :: Map.Map Text (Text, Text)  -- callId -> (toolName, args-accumulator)
       -> [PendingToolCall]
       -> [StreamEvent]
       -> [PendingToolCall]
    go _ done [] = reverse done
    go pending done (ToolCallStart cid name : rest) =
      go (Map.insert cid (name, "") pending) done rest
    go pending done (ToolCallArgDelta cid frag : rest) =
      let pending' = Map.adjust (\(n, a) -> (n, a <> frag)) cid pending
      in go pending' done rest
    go pending done (ToolCallEnd cid : rest) =
      case Map.lookup cid pending of
        Nothing       -> go pending done rest   -- stray End; ignore
        Just (n, a)   ->
          let ptc = PendingToolCall { ptcCallId = cid, ptcToolName = n, ptcArgs = a }
          in go (Map.delete cid pending) (ptc : done) rest
    go pending done (_ : rest) = go pending done rest
```

Add imports for the new types/functions:

```haskell
import Control.Monad.Except (catchError)
import qualified OpenCode.App as App
import OpenCode.App (AppError (..))   -- for ToolError pattern
import OpenCode.Types
  ( ToolArgs (..)
  , ToolCall (..)
  , ToolResult (..)
  )
```

Note: The `OpenCode.Types.callId` / `OpenCode.Types.toolName` / `OpenCode.Types.arguments` qualifications resolve a name collision with `SomeTool.toolName`. If hlint complains about redundant qualification, simplify based on what's in scope.

### Step 6.5: Run tests to confirm pass

```
export PATH="$HOME/.ghcup/bin:$PATH" && stack test --match "OpenCode.Session" 2>&1 | tail -15
```

Expected: 5 SessionSpec specs pass (3 from Task 4/5 + 1 multi-round tool-call from Task 6 = 6 specs, actually). Full suite 128 / 0.

### Step 6.6: hlint + commit

```
hlint src app test verify 2>&1 | tail -3
git add src/OpenCode/LLM/Mock.hs src/OpenCode/Session.hs test/OpenCode/SessionSpec.hs
git commit -m "M6: agentic tool execution + multi-round recursion"
```

---

## Task 7 — `abortSession` + abort behavior in `agentic`

**Files:**
- Edit: `src/OpenCode/Session.hs` (real `abortSession` + abort check in `agentic`)
- Edit: `test/OpenCode/SessionSpec.hs` (abort test)

### Step 7.1: Add the abort test

Append to `test/OpenCode/SessionSpec.hs`:

```haskell
  describe "agentic (abort)" $ do

    it "stops after the current round when envAbort is set" $
      withTestEnv $ \env session -> do
        -- Set the abort flag BEFORE invoking agentic.
        STM.atomically $ STM.writeTVar (envAbort env) True
        -- Script two rounds: round 1 has a tool call (would normally trigger
        -- recursion); round 2 has text. With abort set, round 2 must not run.
        let round1 =
              [ ToolCallStart "c1" "write_file"
              , ToolCallArgDelta "c1" "{\"path\":\"/tmp/m6-abort.txt\",\"content\":\"a\"}"
              , ToolCallEnd "c1"
              , StreamDone (Usage 10 5 Nothing Nothing)
              ]
            round2 =
              [ TextDelta "should not appear"
              , StreamDone (Usage 1 1 Nothing Nothing)
              ]
        streamer <- newScriptedStreamer [round1, round2]
        result <- runExceptT $ runReaderT
          (agentic streamer (sessionId session) []) env
        case result of
          Right msgs ->
            -- Only round 1's assistant message should be present.
            length msgs `shouldBe` 1
          Left err -> expectationFailure (show err)

    it "abortSession sets the envAbort flag" $
      withTestEnv $ \env _session -> do
        before <- STM.readTVarIO (envAbort env)
        before `shouldBe` False
        _ <- runExceptT $ runReaderT abortSession env
        after <- STM.readTVarIO (envAbort env)
        after `shouldBe` True
```

Add imports:

```haskell
import qualified Control.Concurrent.STM as STM
import OpenCode.Session (abortSession)
```

### Step 7.2: Run tests to confirm fail

```
export PATH="$HOME/.ghcup/bin:$PATH" && stack test --match "abort" 2>&1 | tail -15
```

Expected: failures — `abortSession` still errors out; `agentic` doesn't check abort.

### Step 7.3: Implement `abortSession` and add abort check in `agentic`

Replace the `abortSession` stub in `src/OpenCode/Session.hs`:

```haskell
-- | Set the abort flag. The session loop checks this between rounds and
-- terminates early if set.
abortSession :: AppM ()
abortSession = do
  var <- asks envAbort
  liftIO $ STM.atomically $ STM.writeTVar var True
```

Add the import:

```haskell
import qualified Control.Concurrent.STM as STM
```

Then modify the `go` loop in `agentic` to check abort between rounds. Find the existing recursion call:

```haskell
              if ranTool
                then go (round + 1) nextHistory nextAppended
                else pure (reverse nextAppended)
```

Replace with:

```haskell
              if ranTool
                then do
                  shouldAbort <- liftIO $ STM.readTVarIO (envAbort env)
                  if shouldAbort
                    then pure (reverse nextAppended)
                    else go (round + 1) nextHistory nextAppended
                else pure (reverse nextAppended)
```

### Step 7.4: Run tests to confirm pass

```
export PATH="$HOME/.ghcup/bin:$PATH" && stack test --match "OpenCode.Session" 2>&1 | tail -15
```

Expected: 7 SessionSpec specs pass. Full suite 130 / 0.

### Step 7.5: hlint + commit

```
hlint src app test verify 2>&1 | tail -3
git add src/OpenCode/Session.hs test/OpenCode/SessionSpec.hs
git commit -m "M6: abortSession + agentic respects envAbort between rounds"
```

---

## Task 8 — `processUserMessage`

**Files:**
- Edit: `src/OpenCode/Session.hs`
- Edit: `test/OpenCode/SessionSpec.hs`

### Step 8.1: Add the `processUserMessage` test

Append to `test/OpenCode/SessionSpec.hs`:

```haskell
  describe "processUserMessage" $ do

    it "persists the user message and drives one agentic round (via Mock)" $
      withTestEnv $ \env session -> do
        let scripted = [TextDelta "Hello, you!", StreamDone (Usage 3 4 Nothing Nothing)]
            streamer = staticStreamer scripted
        result <- runExceptT $ runReaderT
          (processUserMessageWith streamer (sessionId session) "hi there") env
        case result of
          Right () -> pure ()
          Left err -> expectationFailure (show err)
        msgs <- DB.getMessages (envDb env) (sessionId session)
        length msgs `shouldBe` 2     -- user + assistant
        msgRole (head msgs)         `shouldBe` RoleUser
        msgRole (msgs !! 1)         `shouldBe` RoleAssistant
```

Note the call to `processUserMessageWith` — we expose a streamer-parameterized variant for testability, since production `processUserMessage` hardcodes `streamOpenAI`.

Add the import:

```haskell
import OpenCode.Session (processUserMessage, processUserMessageWith)
```

### Step 8.2: Run tests to confirm fail

```
export PATH="$HOME/.ghcup/bin:$PATH" && stack test --match "processUserMessage" 2>&1 | tail -15
```

Expected: doesn't compile (`processUserMessageWith` doesn't exist; `processUserMessage` is a stub).

### Step 8.3: Implement `processUserMessage` and `processUserMessageWith`

In `src/OpenCode/Session.hs`, replace the `processUserMessage` stub:

```haskell
-- | Process a user prompt: persist a user 'Message', run one agentic loop,
-- and return. Production uses OpenAI streaming (hardcoded for M6; M11 will
-- dispatch by provider).
processUserMessage :: SessionId -> Text -> AppM ()
processUserMessage sid prompt = do
  env <- asks id
  case Config.openaiKey (Config.providers (envConfig env)) of
    Nothing -> throwError (LLMError "no OpenAI API key configured")
    Just key -> do
      let provider = OpenAI.defaultOpenAI key
          streamer = OpenAI.streamOpenAI provider
      processUserMessageWith streamer sid prompt

-- | Streamer-parameterized variant of 'processUserMessage'. Exposed for
-- tests that inject a mock 'Streamer'. Production callers use the
-- 'processUserMessage' wrapper above.
processUserMessageWith :: Streamer -> SessionId -> Text -> AppM ()
processUserMessageWith streamer sid prompt = do
  -- 1. Build and persist the user message.
  conn <- asks envDb
  mid  <- liftIO DB.newMessageId
  now  <- liftIO getCurrentTime
  let userMsg = Message
        { msgId      = mid
        , msgRole    = RoleUser
        , msgParts   = NE.singleton (TextPart prompt)
        , msgCreated = now
        }
  liftIO (DB.insertMessage conn sid userMsg)
  -- 2. Load the full message history (user + everything prior) and drive the loop.
  history <- liftIO (DB.getMessages conn sid)
  _ <- agentic streamer sid history
  pure ()
```

Add imports:

```haskell
import Control.Monad.Except (throwError)
import qualified OpenCode.Config as Config
import qualified OpenCode.LLM.OpenAI as OpenAI
import OpenCode.App (AppError (..))
```

Export `processUserMessageWith` in the module header.

### Step 8.4: Run tests to confirm pass

```
export PATH="$HOME/.ghcup/bin:$PATH" && stack test --match "OpenCode.Session" 2>&1 | tail -15
```

Expected: 8 SessionSpec specs pass. Full suite 131 / 0.

### Step 8.5: hlint + commit

```
hlint src app test verify 2>&1 | tail -3
git add src/OpenCode/Session.hs test/OpenCode/SessionSpec.hs
git commit -m "M6: processUserMessage + processUserMessageWith (streamer-parameterized)"
```

---

## Task 9 — Acceptance + mark M6 done

**Files:**
- Create: `verify/M6Acceptance.hs`
- Edit: `package.yaml` (add `m6-acceptance` executable)
- Edit: `MILESTONES.md`

### Step 9.1: Create the acceptance driver

Create `verify/M6Acceptance.hs`:

```haskell
module Main where

import qualified Brick.BChan as BChan
import qualified Control.Concurrent.STM as STM
import Control.Monad.Except (runExceptT)
import Control.Monad.Reader (runReaderT)
import qualified Data.Text as Text
import qualified Data.Text.IO as TIO
import Database.SQLite.Simple (close)
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)

import OpenCode.App (AppEnv (..))
import OpenCode.Config (Config (..), ProviderConfig (..))
import OpenCode.DB (getMessages, openDb)
import OpenCode.LLM.Mock (newScriptedStreamer)
import OpenCode.Session (createSession, processUserMessageWith)
import OpenCode.Tool.Registry (defaultBuiltinRegistry)
import OpenCode.Types
  ( ApiKey (..)
  , ModelId (..)
  , ProviderId (..)
  , Session (..)
  , StreamEvent (..)
  , Usage (..)
  )

main :: IO ()
main = do
  conn     <- openDb ":memory:"
  chan     <- BChan.newBChan 100
  abortVar <- STM.newTVarIO False
  let cfg = Config
        { providers    = ProviderConfig
            { openaiKey    = Just (ApiKey "sk-test-stub")
            , anthropicKey = Nothing
            }
        , defaultModel = ModelId OpenAI "gpt-4o"
        }
      env = AppEnv
        { envConfig    = cfg
        , envDb        = conn
        , envRegistry  = defaultBuiltinRegistry
        , envEventChan = chan
        , envAbort     = abortVar
        }

  -- Script a mock that calls write_file in round 1 and emits text in round 2.
  let toolArgs = "{\"path\":\"/tmp/m6-x.txt\",\"content\":\"hello m6\"}"
      round1 =
        [ ToolCallStart "c1" "write_file"
        , ToolCallArgDelta "c1" toolArgs
        , ToolCallEnd "c1"
        , StreamDone (Usage 50 15 Nothing Nothing)
        ]
      round2 =
        [ TextDelta "Wrote it."
        , StreamDone (Usage 3 2 Nothing Nothing)
        ]
  streamer <- newScriptedStreamer [round1, round2]

  -- Create session and process a user message.
  sessionResult <- runExceptT $ runReaderT (createSession (ModelId OpenAI "gpt-4o")) env
  session <- case sessionResult of
    Right s  -> pure s
    Left err -> hPutStrLn stderr ("FAIL: createSession: " <> show err) *> exitFailure

  procResult <- runExceptT $ runReaderT
    (processUserMessageWith streamer (sessionId session) "please write the file") env
  case procResult of
    Right () -> pure ()
    Left err -> hPutStrLn stderr ("FAIL: processUserMessageWith: " <> show err) *> exitFailure

  -- Verify: file exists on disk.
  contents <- TIO.readFile "/tmp/m6-x.txt"
  if contents /= "hello m6"
    then do
      hPutStrLn stderr ("FAIL: /tmp/m6-x.txt contains " <> show contents)
      exitFailure
    else pure ()

  -- Verify: getMessages returns user → assistant(tool) → assistant(text)
  msgs <- getMessages conn (sessionId session)
  if length msgs /= 3
    then do
      hPutStrLn stderr ("FAIL: expected 3 messages, got " <> show (length msgs))
      exitFailure
    else pure ()

  close conn
  putStrLn "M6 acceptance OK"
```

### Step 9.2: Add the executable to `package.yaml`

Under `executables:`, add:

```yaml
  m6-acceptance:
    main:         M6Acceptance.hs
    source-dirs:  verify
    other-modules: []
    dependencies:
      - opencode-hs
      - brick
      - mtl
      - sqlite-simple
      - stm
      - text
```

(`other-modules: []` is required because `verify/` is shared with `m2-verify-schema` and `m5-acceptance` — same pattern as M5 Task 6.)

### Step 9.3: Build + run the acceptance check

```
export PATH="$HOME/.ghcup/bin:$PATH" && rm -f /tmp/m6-x.txt && stack build 2>&1 | tail -5 && stack run m6-acceptance
```

Expected: `M6 acceptance OK`.

### Step 9.4: Run the full LLM + Tool + Session spec suite

```
export PATH="$HOME/.ghcup/bin:$PATH" && stack test 2>&1 | tail -5
```

Expected: full suite 131 / 0.

### Step 9.5: hlint clean

```
hlint src app test verify 2>&1 | tail -3
```

Expected: `No hints`.

### Step 9.6: Update `MILESTONES.md` M6 row

Get the M6-starting commit SHA (Task 1):

```
git -C /Users/dodofk/Misc/opencode-hs log --oneline | grep "M6:" | tail -1
```

In `MILESTONES.md`, find the M6 row:

```
| M6  | Session Loop                           | pending   | —                  |
```

Change to (substitute `<sha>` with the first-M6 short SHA):

```
| M6  | Session Loop                           | done      | `<sha>..`          |
```

### Step 9.7: Commit + push + watch CI

```
git -C /Users/dodofk/Misc/opencode-hs add verify/M6Acceptance.hs package.yaml opencode-hs.cabal MILESTONES.md
git -C /Users/dodofk/Misc/opencode-hs commit -m "M6: acceptance verification + mark milestone done"
git -C /Users/dodofk/Misc/opencode-hs push origin main
sleep 5
gh -R dodofk/opencode-hs run watch
```

Expected: all 3 CI jobs (ubuntu, macos, lint) green.

---

## Out of scope for M6 (do NOT add)

- **Anthropic provider dispatch** — `processUserMessage` hardcodes OpenAI per spec. M11 adds the dispatch.
- **Mid-stream abort** — the M6 spec's abort test only requires not-starting-the-next-round; we drain each stream fully. True mid-stream abort would require a TVar check inside the conduit (e.g., a custom `awaitOrAbort`), which is a M12 hardening item.
- **Context-window summarization** — explicit M12 item per the milestone plan.
- **Session title auto-generation** — explicit M12 item.
- **Streaming SessionEvent emission DURING stream consumption** — current design emits `MessageAppended` only after the whole stream drains. The TUI in M9 will display the assistant message as a single block update; PartialText events are not used here. Wire-up of PartialText is a follow-up in M9 once the TUI has streaming-render support.
- **Anything from M7+ (Bash/Glob/Grep tools, TUI, CLI).**

## Notes for the next milestone (M7 — Tool System: execution + search)

- `defaultBuiltinRegistry` is already structured to receive 3 more tools (`bashTool`, `globTool`, `grepTool`) via `registerTool` chaining.
- M7 tools will need to set `toolRender` differently: `bashTool`'s output is `BashOutput` (record), not `Text` — `toolRender = Text.decodeUtf8 . BSL.toStrict . Aeson.encode` is the right choice for JSON-rendering.
- `executeTool`'s dispatch already handles any `o` type because of the per-tool `toolRender`. No changes needed in the dispatch layer.
- The `Tool.Types` GADT already has `BashTool`/`GlobTool`/`GrepTool` constructors. The M7 tasks fill in the executors.
