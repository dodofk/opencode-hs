# M9 — TUI Streaming + Inline Tools + Abort — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Layer live token streaming, inline tool-execution rendering, and cooperative mid-stream abort onto M8's static `brick` TUI.

**Architecture:** The agentic loop's stream sink changes from "buffer the whole round" to a per-event fold that emits `PartialText` deltas onto `envEventChan` and checks `envAbort` after each event (cooperative abort → text-only finalize, pending tools skipped). The TUI consumes `envEventChan` via `customMain`, reduces each `SessionEvent` through a pure `applyEvent` function, forks each run with `async`, and aborts by flipping `envAbort` on `Esc`. A new top-level `OpenCode.Run` module breaks the `App ↔ TUI` import cycle so the TUI can call `processUserMessage` directly.

**Tech Stack:** Haskell (GHC 9.6.6, lts-22.39), `brick`/`vty`/`vty-crossplatform`, `conduit`/`resourcet`, `stm`, `async`, `sqlite-simple`, `hspec`/`QuickCheck`.

**Reference spec:** `docs/superpowers/specs/2026-06-02-m9-tui-streaming-design.md`

---

## File Structure

**Modified (library):**
- `src/OpenCode/Session.hs` — streaming fold, `buildTextOnlyMessage`, `OPENCODE_MOCK` dispatch.
- `src/OpenCode/App.hs` — slimmed: drop `runApp`/`launchTUI`/`newSession` and the `OpenCode.TUI.App` import.
- `src/OpenCode/TUI/Types.hs` — `AppState` gains `asPartialText`/`asEnv`/`asSessionId`, drops `asEventChan`.
- `src/OpenCode/TUI/App.hs` — `applyEvent`, `startRun`, Enter/Esc/`AppEvent` handlers, `customMain`, new `initialState` signature, `streamingAttr` in the attr map.
- `src/OpenCode/TUI/Render.hs` — render the in-flight partial; add `streamingAttr`.
- `src/OpenCode/LLM/Mock.hs` — `delayedStreamer`.

**Created (library):**
- `src/OpenCode/Run.hs` — top-level wiring (`runApp`); the only place that imports both the TUI and the session layer.

**Modified (executable / config):**
- `app/Main.hs` — call `OpenCode.Run.runApp`.
- `package.yaml` — add `OpenCode.Run` to `exposed-modules`; add `vty-crossplatform` dependency.
- `MILESTONES.md` — mark M9 done.

**Modified (tests):**
- `test/OpenCode/TestEnv.hs` — shared helpers `drainBChan`, `newDummyEnv`, `newDummyEnvNoKey`.
- `test/OpenCode/SessionSpec.hs` — streaming + new abort tests.
- `test/OpenCode/TUI/AppSpec.hs` — `applyEvent` reducer tests, `startRun` tests, adapt helpers to the new `AppState`.
- `test/OpenCode/TUI/RenderSpec.hs` — in-flight partial render tests, adapt helper.
- `test/OpenCode/LLM/MockSpec.hs` — `delayedStreamer` test.

No new spec modules are added, so `package.yaml`'s test `other-modules` list does **not** change.

**Build/test commands used throughout:**
- Full build: `stack build`
- Full suite: `stack test`
- One group: `stack test --ta '--match "<pattern>"'`

---

## Task 1: Session streaming fold + text-only abort

**Files:**
- Modify: `src/OpenCode/Session.hs`
- Test: `test/OpenCode/SessionSpec.hs`

This task is self-contained to the session layer (no TUI/cycle changes).

- [ ] **Step 1: Add shared test helpers to `test/OpenCode/TestEnv.hs`**

These are reused by later tasks. Add to the export list `drainBChan`, `newDummyEnv`, `newDummyEnvNoKey`, then add the imports and definitions.

Update the module header export list to:

```haskell
module OpenCode.TestEnv
  ( withTestEnv
  , drainBChan
  , newDummyEnv
  , newDummyEnvNoKey
  ) where
```

Add this import (`Brick.BChan` and `Control.Concurrent.STM` are already imported qualified in this file):

```haskell
import System.Timeout (timeout)
```

Add these definitions at the end of the file:

```haskell
-- | Drain every currently-buffered event from a 'BChan' without blocking
-- forever: read until a short timeout elapses with the channel empty. Callers
-- run the producer to completion *before* draining, so all events are already
-- present and the timeout only detects "empty".
drainBChan :: BChan.BChan a -> IO [a]
drainBChan chan = go []
  where
    go acc = do
      m <- timeout 100000 (BChan.readBChan chan)   -- 100ms
      case m of
        Just x  -> go (x : acc)
        Nothing -> pure (reverse acc)

-- | A non-bracketed in-memory 'AppEnv' for pure-state tests. The :memory:
-- connection is intentionally left open (reclaimed at process exit); the pure
-- functions under test never touch it. Pass the OpenAI key to include.
mkDummyEnv :: Maybe ApiKey -> IO AppEnv
mkDummyEnv mkey = do
  conn     <- openDb ":memory:"
  chan     <- BChan.newBChan 100
  abortVar <- STM.newTVarIO False
  let cfg = Config
        { providers    = ProviderConfig { openaiKey = mkey, anthropicKey = Nothing }
        , defaultModel = ModelId OpenAI "gpt-4o"
        }
  pure AppEnv
    { envConfig    = cfg
    , envDb        = conn
    , envRegistry  = defaultBuiltinRegistry
    , envEventChan = chan
    , envAbort     = abortVar
    }

-- | Dummy env with a (stub) OpenAI key present.
newDummyEnv :: IO AppEnv
newDummyEnv = mkDummyEnv (Just (ApiKey "sk-test-stub"))

-- | Dummy env with no provider keys (drives the "no API key" error path).
newDummyEnvNoKey :: IO AppEnv
newDummyEnvNoKey = mkDummyEnv Nothing
```

- [ ] **Step 2: Write the failing streaming + abort tests in `test/OpenCode/SessionSpec.hs`**

Add these imports to the existing import block:

```haskell
import qualified Conduit
import Control.Monad (when)
import Control.Monad.IO.Class (liftIO)
import System.Directory (doesFileExist, removeFile)
import OpenCode.LLM.Types (Streamer)
import OpenCode.Session.Events (SessionEvent (..))
import OpenCode.TestEnv (withTestEnv, drainBChan)
```

(Adjust the existing `import OpenCode.TestEnv (withTestEnv)` line to the form above rather than duplicating it.)

Add a new `describe` block (e.g. right after the existing `agentic (text-only, one round)` block):

```haskell
  describe "agentic (streaming)" $ do

    it "emits PartialText for each TextDelta during the stream" $
      withTestEnv $ \env session -> do
        let streamer = staticStreamer
              [ TextDelta "Hel", TextDelta "lo"
              , StreamDone (Usage 1 1 Nothing Nothing)
              ]
        _    <- runExceptT $ runReaderT (agentic streamer (sessionId session) []) env
        evts <- drainBChan (envEventChan env)
        [t | PartialText t <- evts] `shouldBe` ["Hel", "lo"]
```

Replace the entire existing `describe "agentic (abort)"` block with:

```haskell
  describe "agentic (abort)" $ do

    it "aborts mid-stream into a text-only message, skipping a fully-arrived tool call" $
      withTestEnv $ \env session -> do
        let path = "/tmp/m9-abort-skip.txt"
        removeIfExists path
        let streamer = abortingAfterToolCall (envAbort env) path
        result <- runExceptT $ runReaderT (agentic streamer (sessionId session) []) env
        case result of
          Right msgs -> do
            length msgs `shouldBe` 1
            NE.toList (msgParts (head msgs)) `shouldBe` [TextPart "after"]
          Left err -> expectationFailure (show err)
        -- the write_file tool must NOT have run
        exists <- doesFileExist path
        exists `shouldBe` False
        -- the text-only message was persisted
        stored <- DB.getMessages (envDb env) (sessionId session)
        length stored `shouldBe` 1

    it "abortSession sets the envAbort flag" $
      withTestEnv $ \env _session -> do
        before <- STM.readTVarIO (envAbort env)
        before `shouldBe` False
        _ <- runExceptT $ runReaderT abortSession env
        after <- STM.readTVarIO (envAbort env)
        after `shouldBe` True
```

Add these helpers in the file's `where` clause / bottom-level helpers section (next to `isToolCall`):

```haskell
-- | A streamer that fully emits a write_file tool call, THEN flips the abort
-- flag, THEN emits one text delta. The fold processes the text delta, observes
-- the abort, and stops — so the (complete) tool call sits in the aborted prefix
-- and must be skipped by the text-only finalize path.
abortingAfterToolCall :: STM.TVar Bool -> FilePath -> Streamer
abortingAfterToolCall abortVar path _req = do
  Conduit.yield (ToolCallStart "c1" "write_file")
  Conduit.yield (ToolCallArgDelta "c1"
    (Text.pack ("{\"path\":\"" <> path <> "\",\"content\":\"x\"}")))
  Conduit.yield (ToolCallEnd "c1")
  liftIO (STM.atomically (STM.writeTVar abortVar True))
  Conduit.yield (TextDelta "after")
  Conduit.yield (StreamDone (Usage 1 1 Nothing Nothing))

removeIfExists :: FilePath -> IO ()
removeIfExists p = do
  e <- doesFileExist p
  when e (removeFile p)
```

- [ ] **Step 3: Run the new tests — verify they FAIL**

Run:
```bash
stack test --ta '--match "agentic (streaming)"'
stack test --ta '--match "agentic (abort)"'
```
Expected: RED. `agentic (streaming)` fails because the current `sinkList` fold never emits `PartialText` (drained list has none). `agentic (abort)` fails because the current code executes the tool (file is created; message contains tool parts, not `[TextPart "after"]`).

- [ ] **Step 4: Implement the streaming fold in `src/OpenCode/Session.hs`**

Add `buildTextOnlyMessage` and `consumeStream`, and rewrite the body of `go`. First, replace the `go`'s stream-consume + result handling. The current block is:

```haskell
          events <- liftIO $ Conduit.runResourceT $ Conduit.runConduit $
            stream .| Conduit.sinkList
          mResult <- buildAssistantMessage events
          case mResult of
            Nothing -> do
              emitEvent (RunStateChanged Idle)
              pure (reverse appended)
            Just (m, ranTool) -> do
              conn <- asks envDb
              liftIO (DB.insertMessage conn sid m)
              emitEvent (MessageAppended m)
              emitEvent (RunStateChanged Idle)
              let nextHistory  = soFar ++ [m]
                  nextAppended = m : appended
              if ranTool
                then do
                  shouldAbort <- liftIO $ STM.readTVarIO (envAbort env)
                  if shouldAbort
                    then pure (reverse nextAppended)
                    else go (roundNum + 1) nextHistory nextAppended
                else pure (reverse nextAppended)
```

Replace it with:

```haskell
          (events, aborted) <- liftIO $ Conduit.runResourceT $ Conduit.runConduit $
            stream .| consumeStream (envEventChan env) (envAbort env)
          if aborted
            then do
              mMsg <- buildTextOnlyMessage events
              case mMsg of
                Nothing -> do
                  emitEvent (RunStateChanged Idle)
                  pure (reverse appended)
                Just m -> do
                  conn <- asks envDb
                  liftIO (DB.insertMessage conn sid m)
                  emitEvent (MessageAppended m)
                  emitEvent (RunStateChanged Idle)
                  pure (reverse (m : appended))
            else do
              mResult <- buildAssistantMessage events
              case mResult of
                Nothing -> do
                  emitEvent (RunStateChanged Idle)
                  pure (reverse appended)
                Just (m, ranTool) -> do
                  conn <- asks envDb
                  liftIO (DB.insertMessage conn sid m)
                  emitEvent (MessageAppended m)
                  emitEvent (RunStateChanged Idle)
                  let nextHistory  = soFar ++ [m]
                      nextAppended = m : appended
                  if ranTool
                    then do
                      shouldAbort <- liftIO $ STM.readTVarIO (envAbort env)
                      if shouldAbort
                        then pure (reverse nextAppended)
                        else go (roundNum + 1) nextHistory nextAppended
                    else pure (reverse nextAppended)
```

Add these two top-level definitions (e.g. right after `buildAssistantMessage`):

```haskell
-- | Stream sink: emit 'PartialText' for each 'TextDelta', accumulate every
-- event, and stop pulling as soon as 'envAbort' is observed (returning
-- @aborted = True@). Stopping lets 'runResourceT' finalize the HTTP conduit and
-- close the connection — cooperative abort. Runs in @ResourceT IO@, so it
-- writes the channel directly rather than via 'emitEvent' (which is 'AppM').
consumeStream
  :: BChan.BChan SessionEvent
  -> STM.TVar Bool
  -> Conduit.ConduitT StreamEvent o (Conduit.ResourceT IO) ([StreamEvent], Bool)
consumeStream chan abortVar = loop []
  where
    loop acc = do
      mEvt <- Conduit.await
      case mEvt of
        Nothing  -> pure (reverse acc, False)
        Just evt -> do
          case evt of
            TextDelta t -> liftIO (BChan.writeBChan chan (PartialText t))
            _           -> pure ()
          aborted <- liftIO (STM.readTVarIO abortVar)
          if aborted
            then pure (reverse (evt : acc), True)
            else loop (evt : acc)

-- | Build an assistant message from the text deltas only, ignoring any tool
-- calls. Used on the abort path so a cancelled run never executes a tool that
-- happened to fully stream in. 'Nothing' when no text was produced.
buildTextOnlyMessage :: [StreamEvent] -> AppM (Maybe Message)
buildTextOnlyMessage events =
  case NE.nonEmpty (collectText events) of
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
```

Add `await` to the `Conduit` imports (the file already has `import qualified Conduit` and `import Conduit ((.|))`; `Conduit.await`, `Conduit.ConduitT`, `Conduit.ResourceT` are all reachable via the qualified import, so no new import line is required). `liftIO`, `STM`, `BChan`, `NE`, `getCurrentTime`, and the `StreamEvent`/`Message` constructors are already imported.

- [ ] **Step 5: Run the tests — verify they PASS**

Run:
```bash
stack test --ta '--match "agentic"'
```
Expected: GREEN. All `agentic` groups pass (streaming, abort, text-only one round, multi-round tool, tool error handling). The pre-existing tests still pass because the non-abort branch is unchanged behavior plus harmless extra `PartialText` writes.

- [ ] **Step 6: Commit**

```bash
git add src/OpenCode/Session.hs test/OpenCode/SessionSpec.hs test/OpenCode/TestEnv.hs
git commit -m "$(cat <<'EOF'
M9: streaming fold + text-only abort in agentic

Replace sinkList with a per-event fold that emits PartialText deltas and
checks envAbort after each event; on abort, finalize a text-only message
and skip any fully-arrived tool call. Add shared test helpers
(drainBChan, newDummyEnv).

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Break the App ↔ TUI import cycle (new `OpenCode.Run`)

**Files:**
- Create: `src/OpenCode/Run.hs`
- Modify: `src/OpenCode/App.hs`
- Modify: `app/Main.hs`
- Modify: `package.yaml`

This is a no-behavior-change refactor that unblocks Task 5 (TUI importing `OpenCode.Session`).

- [ ] **Step 1: Create `src/OpenCode/Run.hs`**

```haskell
-- | Top-level application wiring. Sits above 'OpenCode.App', 'OpenCode.Session',
-- and the TUI so it can build the environment and launch the interface without
-- inducing an import cycle — which is why this logic no longer lives in
-- 'OpenCode.App'.
module OpenCode.Run
  ( runApp
  ) where

import qualified Brick.BChan as BChan
import qualified Control.Concurrent.STM as STM
import System.Environment (getArgs)

import OpenCode.App (AppEnv (..), runAppM)
import OpenCode.Config (Config (..), loadConfig)
import qualified OpenCode.DB as DB
import OpenCode.Session (createSession)
import qualified OpenCode.Tool.Types as Tool
import OpenCode.TUI.App (startTUI)

-- | Entry point. No CLI arguments → launch the TUI on a fresh session (M8/M9).
-- Full subcommand parsing arrives in M10.
runApp :: Tool.ToolRegistry -> IO ()
runApp registry = do
  args <- getArgs
  case args of
    [] -> launchTUI registry
    _  -> putStrLn
      "opencode-hs: CLI commands arrive in M10. Run with no arguments for the TUI."

launchTUI :: Tool.ToolRegistry -> IO ()
launchTUI registry = do
  cfgResult <- loadConfig
  case cfgResult of
    Left err  -> putStrLn ("opencode-hs: config error: " <> show err)
    Right cfg -> do
      dbPath   <- DB.defaultDbPath
      conn     <- DB.openDb dbPath
      chan     <- BChan.newBChan 100
      abortVar <- STM.newTVarIO False
      let env = AppEnv
            { envConfig    = cfg
            , envDb        = conn
            , envRegistry  = registry
            , envEventChan = chan
            , envAbort     = abortVar
            }
      sessionResult <- runAppM env (createSession (defaultModel cfg))
      case sessionResult of
        Left err      -> putStrLn ("opencode-hs: session error: " <> show err)
        Right session -> startTUI env session
```

- [ ] **Step 2: Slim down `src/OpenCode/App.hs`**

Delete the functions `runApp`, `launchTUI`, and `newSession`. Change the module export list to remove `runApp`:

```haskell
module OpenCode.App
  ( -- * Re-exports
    AppM
  , AppEnv (..)
  , AppError (..)
    -- * Running
  , runAppM
    -- * Helpers
  , liftIO'
  , throwAppError
  , askConfig
  , askExecuteTool
  ) where
```

Replace the import block with exactly these (the deleted functions' imports are removed):

```haskell
import Control.Exception (SomeException, try)
import Control.Monad.Except (runExceptT, throwError)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Reader (asks, runReaderT)
import qualified Data.Aeson as Aeson
import qualified Data.Text as Text

import OpenCode.App.Error (AppError (..))
import OpenCode.App.Types (AppEnv (..), AppM)
import OpenCode.Config (Config)
import qualified OpenCode.Tool.Types as Tool
```

The remaining definitions (`runAppM`, `liftIO'`, `throwAppError`, `askConfig`, `askExecuteTool`) are unchanged.

- [ ] **Step 3: Update `app/Main.hs`**

```haskell
module Main (main) where

import OpenCode.Run (runApp)
import OpenCode.Tool.Registry (defaultBuiltinRegistry)

main :: IO ()
main = runApp defaultBuiltinRegistry
```

- [ ] **Step 4: Register `OpenCode.Run` in `package.yaml`**

In the `library: exposed-modules:` list, add `OpenCode.Run` (e.g. right after `OpenCode.App`):

```yaml
    - OpenCode.App
    - OpenCode.Run
```

- [ ] **Step 5: Build and run the full suite — verify GREEN**

Run:
```bash
stack build && stack test
```
Expected: compiles with no errors; entire suite passes (behavior unchanged). If GHC reports an unused import in `OpenCode.App`, remove it.

- [ ] **Step 6: Commit**

```bash
git add src/OpenCode/Run.hs src/OpenCode/App.hs app/Main.hs package.yaml
git commit -m "$(cat <<'EOF'
M9: extract OpenCode.Run to break the App<->TUI import cycle

Move runApp/launchTUI wiring out of OpenCode.App into a new top-level
OpenCode.Run module so the TUI can import OpenCode.Session directly in a
later task. No behavior change.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Reshape `AppState` + switch `startTUI` to `customMain`

**Files:**
- Modify: `src/OpenCode/TUI/Types.hs`
- Modify: `src/OpenCode/TUI/App.hs` (`initialState`, `startTUI`)
- Modify: `package.yaml` (add `vty-crossplatform`)
- Modify: `test/OpenCode/TUI/AppSpec.hs` (helper + `initialState` test)
- Modify: `test/OpenCode/TUI/RenderSpec.hs` (helper)

Refactor: add the new fields, keep the suite green. `asPartialText`/`asEnv`/`asSessionId` are unused until later tasks (no warning — `package.yaml` sets `-Wno-unused-top-binds`).

- [ ] **Step 1: Reshape `AppState` in `src/OpenCode/TUI/Types.hs`**

Replace the `AppState` record and update imports. Remove `import Brick.BChan (BChan)`; add the env/session-id imports:

```haskell
import Brick.Widgets.Edit (Editor)
import Data.Sequence (Seq)
import Data.Text (Text)

import OpenCode.App.Types (AppEnv)
import OpenCode.Session.Events (RunState (..), SessionEvent (..))
import OpenCode.Types (Message, SessionId)
```

```haskell
-- | The full UI state. M9 adds 'asPartialText' (the in-flight streaming
-- buffer) and embeds 'asEnv'/'asSessionId' so the Enter/Esc handlers can fork
-- the session loop and flip the abort flag. The event channel is reached via
-- @envEventChan asEnv@.
data AppState = AppState
  { asMessages    :: Seq Message
  , asInput       :: Editor Text ResourceName
  , asRunState    :: RunState
  , asStatusLine  :: Text
  , asPartialText :: Text
  , asEnv         :: AppEnv
  , asSessionId   :: SessionId
  }
```

(`SessionEvent (..)` stays in the re-export list of this module's header — keep the existing export list as-is.)

- [ ] **Step 2: Update `initialState` and `startTUI` in `src/OpenCode/TUI/App.hs`**

Replace `initialState` (it now takes the whole `AppEnv` and seeds the new fields):

```haskell
-- | Build the initial UI state from the environment, session, and history.
initialState :: AppEnv -> Session -> [Message] -> AppState
initialState env session msgs = AppState
  { asMessages    = Seq.fromList msgs
  , asInput       = emptyEditor
  , asRunState    = Idle
  , asStatusLine  = modelLabel (sessionModel session)
  , asPartialText = ""
  , asEnv         = env
  , asSessionId   = sessionId session
  }
```

Replace `startTUI` to feed `envEventChan` through `customMain`:

```haskell
startTUI :: AppEnv -> Session -> IO ()
startTUI env session = do
  msgs <- DB.getMessages (envDb env) (sessionId session)
  let st0      = initialState env session msgs
      buildVty = mkVty V.defaultConfig
  initialVty <- buildVty
  _ <- M.customMain initialVty buildVty (Just (envEventChan env)) app st0
  pure ()
```

Update imports in `src/OpenCode/TUI/App.hs`:
- Remove `import Brick.BChan (BChan)`.
- Add `import Graphics.Vty.CrossPlatform (mkVty)`.
- The file already has `import qualified Brick.Main as M` (`M.customMain`) and `import qualified Graphics.Vty as V` (`V.defaultConfig`).

- [ ] **Step 3: Add the `vty-crossplatform` dependency to `package.yaml`**

In the top-level `dependencies:` list, under the `# TUI` group, add:

```yaml
  # TUI
  - brick >= 2.1
  - vty >= 6.1
  - vty-crossplatform >= 0.4
  - microlens >= 0.4
  - microlens-mtl >= 0.2
```

- [ ] **Step 4: Adapt the test helpers to the new `AppState`**

In `test/OpenCode/TUI/AppSpec.hs`: import the dummy env helper and rewrite `stateWithInput` so call sites stay unchanged. Add one import (`Seq` is already imported qualified; `sessionId` comes from the existing `Session (..)` import):

```haskell
import OpenCode.TestEnv (newDummyEnv)
```

Replace `stateWithInput`:

```haskell
stateWithInput :: Text -> IO AppState
stateWithInput t = do
  env <- newDummyEnv
  pure AppState
    { asMessages    = Seq.empty
    , asInput       = E.editorText InputEditor (Just 1) t
    , asRunState    = Idle
    , asStatusLine  = "openai:gpt-4o"
    , asPartialText = ""
    , asEnv         = env
    , asSessionId   = sessionId sampleSession
    }
```

(`stateWithInput'` and all `it`/`prop` call sites are unchanged — they still call `stateWithInput`/`stateWithInput'`.)

Replace the `initialState` test body (it no longer takes a `BChan`):

```haskell
  describe "initialState" $ do
    it "loads the given history and starts Idle with an empty input" $ do
      env <- newDummyEnv
      let st = initialState env sampleSession [userMsg, userMsg]
      Seq.length (asMessages st) `shouldBe` 2
      asRunState st `shouldBe` Idle
      currentInput st `shouldBe` ""
      asStatusLine st `shouldBe` "openai:gpt-4o"
```

Remove the now-unused `import qualified Brick.BChan as BChan` from `AppSpec.hs` if GHC flags it.

In `test/OpenCode/TUI/RenderSpec.hs`: rewrite `mkState` likewise (signature unchanged, so its call sites stay):

```haskell
mkState :: [Message] -> IO AppState
mkState msgs = do
  env <- newDummyEnv
  pure AppState
    { asMessages    = Seq.fromList msgs
    , asInput       = E.editorText InputEditor (Just 1) ""
    , asRunState    = Idle
    , asStatusLine  = "openai:gpt-4o"
    , asPartialText = ""
    , asEnv         = env
    , asSessionId   = sessionId sampleRenderSession
    }

sampleRenderSession :: Session
sampleRenderSession = Session
  { sessionId      = SessionId "s-render"
  , sessionTitle   = "untitled"
  , sessionModel   = ModelId OpenAI "gpt-4o"
  , sessionCreated = t0
  }
```

Add to `RenderSpec.hs` imports: `import OpenCode.TestEnv (newDummyEnv)`, and extend the `OpenCode.Types` import with `ModelId (..)`, `ProviderId (..)`, `Session (..)`, `SessionId (..)`. Remove the now-unused `import qualified Brick.BChan as BChan` if GHC flags it.

- [ ] **Step 5: Build and run the suite — verify GREEN**

Run:
```bash
stack build && stack test
```
Expected: compiles (a fresh `vty-crossplatform` may download/build once); full suite green. The `AppState` change is purely additive to construction sites.

- [ ] **Step 6: Commit**

```bash
git add src/OpenCode/TUI/Types.hs src/OpenCode/TUI/App.hs package.yaml \
        test/OpenCode/TUI/AppSpec.hs test/OpenCode/TUI/RenderSpec.hs
git commit -m "$(cat <<'EOF'
M9: reshape AppState for streaming + switch TUI to customMain

AppState gains asPartialText/asEnv/asSessionId and drops asEventChan;
startTUI now feeds envEventChan through customMain (no pump thread). Add
vty-crossplatform for mkVty. Test helpers adapted; suite unchanged.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: `applyEvent` reducer

**Files:**
- Modify: `src/OpenCode/TUI/App.hs`
- Test: `test/OpenCode/TUI/AppSpec.hs`

- [ ] **Step 1: Write the failing reducer tests in `test/OpenCode/TUI/AppSpec.hs`**

Add to imports:

```haskell
import OpenCode.Session.Events (RunState (..), SessionEvent (..))
import OpenCode.TUI.App (applyEvent)
import OpenCode.Types (MessagePart (TextPart, ErrorPart), msgParts)
```

(Replace the existing `import OpenCode.Session.Events (RunState (Idle))` with the `RunState (..)` form; merge `applyEvent` into the existing `OpenCode.TUI.App (...)` import list; merge the `MessagePart`/`msgParts` names into the existing `OpenCode.Types (...)` import.)

Add a new `describe` block:

```haskell
  describe "applyEvent (session-event reducer)" $ do

    it "PartialText accumulates into asPartialText" $ do
      st <- stateWithInput ""
      let st' = applyEvent (PartialText "cd") (applyEvent (PartialText "ab") st)
      asPartialText st' `shouldBe` "abcd"

    it "MessageAppended appends the message and clears the partial buffer" $ do
      st0 <- stateWithInput ""
      let st1 = applyEvent (PartialText "draft") st0
          st2 = applyEvent (MessageAppended userMsg) st1
      Seq.length (asMessages st2) `shouldBe` 1
      asPartialText st2 `shouldBe` ""

    it "ToolStarted sets RunningTool" $ do
      st <- stateWithInput ""
      asRunState (applyEvent (ToolStarted "bash") st) `shouldBe` RunningTool "bash"

    it "ToolFinished is a no-op" $ do
      st <- stateWithInput ""
      let st' = applyEvent (ToolFinished "bash" "out") st
      asRunState st' `shouldBe` asRunState st
      Seq.length (asMessages st') `shouldBe` Seq.length (asMessages st)

    it "RunStateChanged Idle clears the partial buffer" $ do
      st0 <- stateWithInput ""
      let st2 = applyEvent (RunStateChanged Idle) (applyEvent (PartialText "x") st0)
      asRunState st2 `shouldBe` Idle
      asPartialText st2 `shouldBe` ""

    it "RunStateChanged RunningLLM keeps the partial buffer" $ do
      st0 <- stateWithInput ""
      let st2 = applyEvent (RunStateChanged RunningLLM) (applyEvent (PartialText "x") st0)
      asPartialText st2 `shouldBe` "x"

    it "ErrorOccurred appends a synthetic error message" $ do
      st <- stateWithInput ""
      let st' = applyEvent (ErrorOccurred "boom") st
      Seq.length (asMessages st') `shouldBe` 1
      case Seq.lookup 0 (asMessages st') of
        Just m  -> NE.toList (msgParts m) `shouldBe` [ErrorPart "boom"]
        Nothing -> expectationFailure "expected one message"
```

- [ ] **Step 2: Run the tests — verify they FAIL**

Run:
```bash
stack test --ta '--match "applyEvent"'
```
Expected: RED — compile error "Variable not in scope: applyEvent".

- [ ] **Step 3: Implement `applyEvent` in `src/OpenCode/TUI/App.hs`**

Add `applyEvent` to the module export list (in the "State helpers" section):

```haskell
  , applyEnter
  , applyEvent
```

Adjust imports as follows:
- Replace `import Data.Time (getCurrentTime)` with `import Data.Time (UTCTime (..), fromGregorian, getCurrentTime)`.
- Replace `import OpenCode.Session.Events (RunState (Idle), SessionEvent)` with `import OpenCode.Session.Events (RunState (..), SessionEvent (..))` (the reducer needs `RunningTool` and the `SessionEvent` constructors).
- Extend the existing `OpenCode.Types (...)` import with `MessageId (MessageId)`, `ErrorPart` (i.e. `MessagePart (TextPart, ErrorPart)`), and `RoleAssistant` (i.e. `Role (RoleUser, RoleAssistant)`).

Add the reducer and a helper:

```haskell
-- | Pure reducer: fold a 'SessionEvent' from the session loop into the UI
-- state. Exported for testing. Never reads 'asEnv'/'asSessionId'.
applyEvent :: SessionEvent -> AppState -> AppState
applyEvent = \case
  MessageAppended m -> \st -> st { asMessages = asMessages st |> m, asPartialText = "" }
  PartialText t     -> \st -> st { asPartialText = asPartialText st <> t }
  ToolStarted n     -> \st -> st { asRunState = RunningTool n }
  ToolFinished _ _  -> id
  RunStateChanged s -> \st -> st
    { asRunState    = s
    , asPartialText = if s == Idle then "" else asPartialText st
    }
  ErrorOccurred e   -> \st -> st { asMessages = asMessages st |> errorMessage e }

-- | A transient, render-only assistant message carrying an error line. Not
-- persisted, so a fixed synthetic id/timestamp is fine.
errorMessage :: Text -> Message
errorMessage e = Message
  { msgId      = MessageId "error-synthetic"
  , msgRole    = RoleAssistant
  , msgParts   = ErrorPart e :| []
  , msgCreated = UTCTime (fromGregorian 1970 1 1) 0
  }
```

(`RunningTool` comes from the `RunState (..)`-style import; ensure the `OpenCode.Session.Events` import exposes the constructors — use `RunState (..)`.)

- [ ] **Step 4: Run the tests — verify they PASS**

Run:
```bash
stack test --ta '--match "applyEvent"'
```
Expected: GREEN — all seven reducer cases pass.

- [ ] **Step 5: Commit**

```bash
git add src/OpenCode/TUI/App.hs test/OpenCode/TUI/AppSpec.hs
git commit -m "$(cat <<'EOF'
M9: pure applyEvent reducer for session events

Fold MessageAppended/PartialText/ToolStarted/ToolFinished/
RunStateChanged/ErrorOccurred into AppState. Mutation-tested per case.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: Enter / Esc / AppEvent handlers + `startRun` fork

**Files:**
- Modify: `src/OpenCode/TUI/App.hs`
- Test: `test/OpenCode/TUI/AppSpec.hs`

- [ ] **Step 1: Write the failing `startRun` tests in `test/OpenCode/TUI/AppSpec.hs`**

Add to imports:

```haskell
import Control.Concurrent (threadDelay)
import Control.Concurrent.STM (atomically, readTVarIO, writeTVar)
import System.Environment (unsetEnv)
import OpenCode.App.Types (AppEnv (..))
import OpenCode.TUI.App (startRun)
import OpenCode.TestEnv (drainBChan, newDummyEnvNoKey)
import OpenCode.Types (SessionId (..))
```

(Merge `startRun` into the `OpenCode.TUI.App (...)` import; merge `drainBChan`/`newDummyEnvNoKey` into the `OpenCode.TestEnv (...)` import.)

Add a new `describe` block:

```haskell
  describe "startRun (forked agentic run)" $ do

    it "resets the abort flag synchronously before forking" $ do
      unsetEnv "OPENCODE_MOCK"
      env <- newDummyEnvNoKey
      atomically (writeTVar (envAbort env) True)
      startRun env (SessionId "s-1") "hi"
      threadDelay 100000              -- let the fork run and fail
      readTVarIO (envAbort env) `shouldReturn` False

    it "surfaces a missing-key error as ErrorOccurred then Idle" $ do
      unsetEnv "OPENCODE_MOCK"
      env <- newDummyEnvNoKey
      startRun env (SessionId "s-1") "hi"
      evts <- drainBChan (envEventChan env)
      any isErrorEvt evts `shouldBe` True
      lastMay evts `shouldBe` Just (RunStateChanged Idle)
```

Add bottom-level helpers:

```haskell
isErrorEvt :: SessionEvent -> Bool
isErrorEvt (ErrorOccurred _) = True
isErrorEvt _                 = False

lastMay :: [a] -> Maybe a
lastMay [] = Nothing
lastMay xs = Just (last xs)
```

- [ ] **Step 2: Run the tests — verify they FAIL**

Run:
```bash
stack test --ta '--match "startRun"'
```
Expected: RED — compile error "Variable not in scope: startRun".

- [ ] **Step 3: Implement `startRun` and wire the handlers in `src/OpenCode/TUI/App.hs`**

Add `startRun` to the module export list (Entry point section):

```haskell
    startTUI
  , startRun
```

Adjust imports as follows:
- Change the existing `import Brick (App (..), BrickEvent (VtyEvent), EventM)` to `import Brick (App (..), BrickEvent (VtyEvent, AppEvent), EventM)`.
- Add `import qualified Brick.BChan as BChan`.
- Add `import Control.Concurrent.Async (async)`.
- Add `import Control.Concurrent.STM (atomically, writeTVar)`.
- Add `import Control.Exception (SomeException, displayException, try)`.
- Add `import OpenCode.App (runAppM)`.
- Add `import OpenCode.Session (processUserMessage)`.
- Merge `SessionId` into the existing `OpenCode.Types (...)` import.

The `OpenCode.Session.Events` import was already widened to `RunState (..), SessionEvent (..)` in Task 4, so `Idle`, `ErrorOccurred`, and `RunStateChanged` are already in scope — do not re-import them.

Add `startRun`:

```haskell
-- | Reset the abort flag (synchronously) and fork the agentic run for a user
-- prompt. Any failure — typed 'AppError' or runtime exception — is surfaced as
-- an 'ErrorOccurred' event, and the run state is always returned to 'Idle' so
-- the input is re-enabled. The handle is discarded: abort is cooperative.
startRun :: AppEnv -> SessionId -> Text -> IO ()
startRun env sid prompt = do
  atomically (writeTVar (envAbort env) False)
  _ <- async $ do
    outcome <- try (runAppM env (processUserMessage sid prompt))
    case outcome of
      Right (Right ()) -> pure ()                  -- success: loop already emitted Idle
      Right (Left err) -> report (T.pack (show err))
      Left ex          -> report (T.pack (displayException (ex :: SomeException)))
  pure ()
  where
    report msg = do
      BChan.writeBChan (envEventChan env) (ErrorOccurred msg)
      BChan.writeBChan (envEventChan env) (RunStateChanged Idle)
```

Rewrite `handleEvent` to add the `Esc`, upgraded `Enter`, and `AppEvent` branches:

```haskell
handleEvent :: BrickEvent ResourceName SessionEvent -> EventM ResourceName AppState ()
handleEvent (VtyEvent (V.EvKey (V.KChar 'c') [V.MCtrl])) = M.halt
handleEvent (VtyEvent (V.EvKey V.KEsc [])) = do
  st <- get
  liftIO (atomically (writeTVar (envAbort (asEnv st)) True))
handleEvent (VtyEvent (V.EvKey V.KEnter [])) = do
  st <- get
  let body = currentInput st
  when (asRunState st == Idle && shouldSubmit body) $ do
    msg <- liftIO (mkUserMessage body)
    put (applyEnter msg st)
    liftIO (startRun (asEnv st) (asSessionId st) body)
handleEvent (VtyEvent (V.EvKey V.KPageUp   [])) = M.vScrollBy chatScroll (-pageStep)
handleEvent (VtyEvent (V.EvKey V.KPageDown [])) = M.vScrollBy chatScroll pageStep
handleEvent (VtyEvent ev) = zoom inputL (E.handleEditorEvent (VtyEvent ev))
handleEvent (AppEvent ev) = do
  st <- get
  put (applyEvent ev st)
handleEvent _ = pure ()
```

- [ ] **Step 4: Run the tests — verify they PASS**

Run:
```bash
stack test --ta '--match "startRun"'
```
Expected: GREEN. With no key and `OPENCODE_MOCK` unset, `processUserMessage` throws `LLMError`; `startRun` emits `ErrorOccurred` then `RunStateChanged Idle`, and the abort flag is reset to `False`.

- [ ] **Step 5: Build everything — verify no warnings/errors**

Run:
```bash
stack build && stack test
```
Expected: GREEN across the suite (the handler wiring compiles; `AppEvent`/`Esc`/`Enter` branches are exhaustive with the final catch-all).

- [ ] **Step 6: Commit**

```bash
git add src/OpenCode/TUI/App.hs test/OpenCode/TUI/AppSpec.hs
git commit -m "$(cat <<'EOF'
M9: wire Enter/Esc/AppEvent handlers + startRun fork

Enter (Idle only) forks processUserMessage via async, resetting envAbort
and reporting errors as ErrorOccurred + Idle; Esc flips envAbort; AppEvent
delegates to applyEvent. startRun error path is tested.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: Render the in-flight partial

**Files:**
- Modify: `src/OpenCode/TUI/Render.hs`
- Modify: `src/OpenCode/TUI/App.hs` (attr map)
- Test: `test/OpenCode/TUI/RenderSpec.hs`

- [ ] **Step 1: Write the failing render tests in `test/OpenCode/TUI/RenderSpec.hs`**

Change `import OpenCode.Session.Events (RunState (Idle))` to `import OpenCode.Session.Events (RunState (..))`. Add a new `describe` block:

```haskell
  describe "in-flight partial" $ do

    it "renders the partial text while a run is active" $ do
      st0 <- mkState []
      let st  = st0 { asRunState = RunningLLM, asPartialText = "streaming now" }
          pic = M.renderWidget Nothing (drawUI st) (80, 24)
      show pic `shouldContain` "streaming"

    it "hides the partial text when Idle" $ do
      st0 <- mkState []
      let st  = st0 { asRunState = Idle, asPartialText = "ghosttext" }
          pic = M.renderWidget Nothing (drawUI st) (80, 24)
      show pic `shouldNotContain` "ghosttext"
```

- [ ] **Step 2: Run the tests — verify they FAIL**

Run:
```bash
stack test --ta '--match "in-flight partial"'
```
Expected: RED — the first test fails because `drawUI` currently ignores `asPartialText` (so "streaming" is absent from the rendered picture).

- [ ] **Step 3: Implement the in-flight render in `src/OpenCode/TUI/Render.hs`**

Add `streamingAttr` to the export list:

```haskell
  , toolAttr
  , errorAttr
  , statusAttr
  , streamingAttr
```

Add the attribute name (next to the others):

```haskell
streamingAttr :: AttrName
streamingAttr = attrName "streaming"
```

Replace `drawUI` so the chat viewport appends a dim in-flight assistant message when running with a non-empty buffer:

```haskell
drawUI :: AppState -> [Widget ResourceName]
drawUI st = [chat <=> statusBar st <=> inputBox st]
  where
    chat =
      viewport ChatViewport Vertical $
        vBox (map renderMessage (toList (asMessages st)) <> inflight)
    inflight
      | asRunState st /= Idle && not (T.null (asPartialText st)) =
          [ withAttr assistantAttr (txt (rolePrefix RoleAssistant))
              <=> padLeft (Pad 2) (withAttr streamingAttr (safeWrap (asPartialText st)))
          ]
      | otherwise = []
```

(`RunState (..)` is already imported in `Render.hs` via `import OpenCode.Session.Events (RunState (..))`; `<>` on lists, `withAttr`, `txt`, `padLeft`, `Pad`, `rolePrefix`, `safeWrap`, `assistantAttr` are all already in scope.)

- [ ] **Step 4: Register `streamingAttr` in the attr map in `src/OpenCode/TUI/App.hs`**

Add `streamingAttr` to the `OpenCode.TUI.Render` import list, and add an entry to `theMap`:

```haskell
theMap :: AttrMap
theMap = attrMap V.defAttr
  [ (userAttr,      fg V.cyan)
  , (assistantAttr, fg V.green)
  , (toolAttr,      fg V.yellow)
  , (errorAttr,     fg V.red)
  , (statusAttr,    V.white `on` V.blue)
  , (streamingAttr, V.defAttr `V.withStyle` V.dim)
  ]
```

(`V.withStyle` and `V.dim` come from the existing `import qualified Graphics.Vty as V`.)

- [ ] **Step 5: Run the tests — verify they PASS**

Run:
```bash
stack test --ta '--match "in-flight partial"'
stack test --ta '--match "drawUI"'
```
Expected: GREEN — the partial renders while running, is hidden when Idle, and the existing `drawUI` smoke tests still pass.

- [ ] **Step 6: Commit**

```bash
git add src/OpenCode/TUI/Render.hs src/OpenCode/TUI/App.hs test/OpenCode/TUI/RenderSpec.hs
git commit -m "$(cat <<'EOF'
M9: render the in-flight streaming partial (dim, bottom of chat)

drawUI appends a dim synthetic assistant message built from asPartialText
while a run is active; hidden when Idle. Adds the streaming attr.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: `delayedStreamer` + `OPENCODE_MOCK` dispatch

**Files:**
- Modify: `src/OpenCode/LLM/Mock.hs`
- Modify: `src/OpenCode/Session.hs`
- Test: `test/OpenCode/LLM/MockSpec.hs`

- [ ] **Step 1: Write the failing `delayedStreamer` test in `test/OpenCode/LLM/MockSpec.hs`**

Add to imports:

```haskell
import OpenCode.LLM.Types (LLMRequest (..))
```

Add a new `describe` block (inside `spec`, after the existing one — note `spec` currently is a single `describe`; wrap both in a `do` or append a sibling `describe`):

```haskell
  describe "delayedStreamer" $
    it "yields all scripted events in order (zero delay)" $ do
      let scripted =
            [ TextDelta "a", TextDelta "b"
            , StreamDone (Usage 1 1 Nothing Nothing)
            ]
          req = LLMRequest
            { reqModel        = "gpt-4o"
            , reqMessages     = []
            , reqTools        = []
            , reqSystemPrompt = ""
            , reqMaxTokens    = Nothing
            }
      events <- Conduit.runResourceT $ Conduit.runConduit $
        delayedStreamer 0 scripted req .| Conduit.sinkList
      events `shouldBe` scripted
```

If the existing `spec = describe ...` is a single expression, change it to:

```haskell
spec :: Spec
spec = do
  describe "mockStreamCompletion" $ do
    ... (existing two its) ...

  describe "delayedStreamer" $
    it "yields all scripted events in order (zero delay)" $ do
      ... (as above) ...
```

- [ ] **Step 2: Run the test — verify it FAILS**

Run:
```bash
stack test --ta '--match "delayedStreamer"'
```
Expected: RED — compile error "Variable not in scope: delayedStreamer".

- [ ] **Step 3: Implement `delayedStreamer` in `src/OpenCode/LLM/Mock.hs`**

Add `delayedStreamer` to the export list. Add imports:

```haskell
import Conduit (ConduitT, yield, yieldMany)
import Control.Concurrent (threadDelay)
```

(Merge `yield` into the existing `import Conduit (ConduitT, yieldMany)`.)

Add the definition:

```haskell
-- | A 'Streamer' that yields each scripted event with @delayUs@ microseconds
-- between emissions. Used for manual TUI testing without API keys: the delay
-- makes streaming visible to a human. Tests pass @0@.
delayedStreamer :: Int -> [StreamEvent] -> Streamer
delayedStreamer delayUs evts _req = go evts
  where
    go []       = pure ()
    go (e:rest) = do
      yield e
      liftIO (threadDelay delayUs)
      go rest
```

- [ ] **Step 4: Run the test — verify it PASSES**

Run:
```bash
stack test --ta '--match "delayedStreamer"'
```
Expected: GREEN.

- [ ] **Step 5: Wire `OPENCODE_MOCK` dispatch in `src/OpenCode/Session.hs`**

Add imports:

```haskell
import System.Environment (lookupEnv)
import qualified OpenCode.LLM.Mock as Mock
```

Extend the `OpenCode.Types` import to include `Usage (..)` (used by `mockReply`).

Replace `processUserMessage` with the dispatching version, and add the mock constants:

```haskell
processUserMessage :: SessionId -> Text -> AppM ()
processUserMessage sid prompt = do
  mock <- liftIO (lookupEnv "OPENCODE_MOCK")
  case mock of
    Just "1" ->
      processUserMessageWith (Mock.delayedStreamer mockChunkDelayUs mockReply) sid prompt
    _ -> do
      cfg <- asks envConfig
      case Config.openaiKey (Config.providers cfg) of
        Nothing  -> throwError (LLMError "no OpenAI API key configured")
        Just key ->
          processUserMessageWith (OpenAI.streamOpenAI (OpenAI.defaultOpenAI key)) sid prompt

-- | Microseconds between mock chunks; tuned so the whole reply takes a few
-- seconds — long enough to watch streaming and test Esc by hand.
mockChunkDelayUs :: Int
mockChunkDelayUs = 700000

-- | The canned reply emitted under OPENCODE_MOCK=1.
mockReply :: [StreamEvent]
mockReply =
  [ TextDelta "This ", TextDelta "is ", TextDelta "a ", TextDelta "mock "
  , TextDelta "streamed ", TextDelta "reply ", TextDelta "for ", TextDelta "manual "
  , TextDelta "testing."
  , StreamDone (Usage 0 0 Nothing Nothing)
  ]
```

- [ ] **Step 6: Build and run the full suite — verify GREEN**

Run:
```bash
stack build && stack test
```
Expected: compiles; full suite green. (The `OPENCODE_MOCK` dispatch itself is verified manually in Task 8 — an automated test would block for several seconds on the deliberate delay.)

- [ ] **Step 7: Commit**

```bash
git add src/OpenCode/LLM/Mock.hs src/OpenCode/Session.hs test/OpenCode/LLM/MockSpec.hs
git commit -m "$(cat <<'EOF'
M9: delayedStreamer + OPENCODE_MOCK dispatch

Add a delay-paced mock streamer and route processUserMessage through it
when OPENCODE_MOCK=1, enabling keyless manual streaming/abort testing.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Task 8: Integration — full verify, manual acceptance, MILESTONES

**Files:**
- Modify: `MILESTONES.md`

- [ ] **Step 1: Full build + test + lint**

Run:
```bash
stack build 2>&1 | tail -20
stack test  2>&1 | tail -30
hlint src app test
```
Expected: build clean (warnings acceptable for M9; `-Werror` is an M12 task), entire suite green, `hlint` reports `No hints`. Fix any new hlint hints in the touched files before proceeding.

- [ ] **Step 2: Manual acceptance — keyless streaming + abort**

Run (the deliberate delay makes streaming visible):
```bash
OPENCODE_MOCK=1 stack run
```
Confirm by observation:
1. Type a prompt, press Enter → the reply appears word-by-word (dim, at the bottom of the chat) and the status bar shows `thinking…`.
2. Press `Esc` mid-stream → streaming stops; the partial text remains as a finalized assistant message; status returns to `idle`.
3. Send another prompt → it streams normally (proves `envAbort` was reset).
4. `Ctrl+C` → clean exit.

If an `OPENAI_API_KEY` is configured, optionally repeat without `OPENCODE_MOCK` to confirm the live path streams too.

- [ ] **Step 3: Mark M9 done in `MILESTONES.md`**

In the status-snapshot table, change the M9 row:

```markdown
| M9  | TUI: streaming + tool inline + abort   | done      | `see M9 PR`        |
```

Change the section heading and prepend an outcome paragraph (mirroring M8's done format):

```markdown
## M9 — TUI: streaming + tool inline + abort — DONE

Outcome: `agentic` now consumes the stream with a per-event fold
(`consumeStream`) that emits `PartialText` deltas onto `envEventChan` and
checks `envAbort` after each event; on abort it finalizes a text-only
message via `buildTextOnlyMessage`, skipping any fully-arrived tool call.
A new top-level `OpenCode.Run` module breaks the `App`↔`TUI` cycle so the
TUI calls `processUserMessage` directly. `AppState` gained
`asPartialText`/`asEnv`/`asSessionId`; a pure `applyEvent` reducer folds
each `SessionEvent`; `handleEvent` forks runs with `startRun` (Enter, Idle
only), aborts on `Esc`, and reduces `AppEvent`s; `startTUI` runs via
`customMain` fed `envEventChan` (no pump thread). The chat viewport renders
the in-flight partial as a dim trailing message. `delayedStreamer` +
`OPENCODE_MOCK=1` enable keyless manual testing.
```

(Leave the existing Tasks/Tests/Acceptance subsections in place below the new outcome paragraph, as M8 does.)

- [ ] **Step 4: Commit**

```bash
git add MILESTONES.md
git commit -m "$(cat <<'EOF'
M9: acceptance verification + mark milestone done

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Self-Review

**Spec coverage** (against `2026-06-02-m9-tui-streaming-design.md`):
- §1 streaming fold + text-only abort → Task 1.
- §2 AppState reshape → Task 3.
- §3 applyEvent reducer → Task 4.
- §4 Enter/Esc + fork robustness (reset abort, error→Idle) → Task 5.
- §5 startTUI customMain → Task 3.
- §6 in-flight render → Task 6.
- §7 delayedStreamer + OPENCODE_MOCK → Task 7.
- Testing section (reducer, abort, manual) → Tasks 1/4/6/8.
- Import-cycle constraint discovered during planning → Task 2 (refinement; does not change user-facing behavior).

**Type/name consistency:** `consumeStream`/`buildTextOnlyMessage` (Task 1) referenced only within `Session.hs`; `applyEvent` (Task 4) used by `handleEvent` (Task 5) and tests; `startRun` signature `AppEnv -> SessionId -> Text -> IO ()` consistent between impl (Task 5) and tests (Task 5); `delayedStreamer :: Int -> [StreamEvent] -> Streamer` consistent between Task 7 impl, test, and the `Session.hs` call site; `streamingAttr` defined in `Render.hs` (Task 6) and consumed in `App.hs` `theMap` (Task 6); `newDummyEnv`/`newDummyEnvNoKey`/`drainBChan` defined once in `TestEnv.hs` (Task 1) and imported elsewhere.

**Placeholder scan:** no TBD/TODO; every code step shows complete code; every run step shows the command + expected red/green.
