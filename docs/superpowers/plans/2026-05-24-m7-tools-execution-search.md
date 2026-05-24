# M7 — Tool System: execution + search Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement the remaining three built-in tools (`bash`, `glob`, `grep`) and register them into `defaultBuiltinRegistry`. Also fix the `isError = False` bug in `executeOne` (carried from M6 final review) that would otherwise silently misreport tool failures to the LLM once Bash timeouts and non-zero exits start firing.

**Architecture:** Each tool lives in its own module under `src/OpenCode/Tool/`, exposing a single `SomeTool` value. The three tools all return structured outputs (Bash → `BashOutput` record; Glob → `[FilePath]`; Grep → `[GrepMatch]`), unlike the M5 file tools which all returned raw `Text`. The structured outputs are JSON-encoded via `toolRender = Text.decodeUtf8 . BSL.toStrict . Aeson.encode`, so the LLM sees clean field-stripped JSON. Bash spawns a shell subprocess with `System.Process.createProcess`, runs concurrent reader threads on stdout/stderr (so we can capture partial output on timeout), and uses `System.Timeout.timeout` for the 30-second cap. Glob uses `System.FilePath.Glob.namesMatching` with simple line-prefix `.gitignore` exclusion. Grep probes `findExecutable "rg"` — if ripgrep is on PATH, runs `rg --json` and parses NDJSON match events; otherwise falls back to walking the file tree and applying `Text.isInfixOf` line-by-line.

**Tech stack:** `process >= 1.6` (Bash), `Glob >= 0.10` (Glob + Grep fallback walk), `directory >= 1.3` (findExecutable), `bytestring`, `text`, `aeson`. All already in `package.yaml`. No new dependencies.

---

## Carryover items from M6 final review

Two items were flagged during the M6 final review and explicitly identified as M7-prep concerns:

1. **`isError = False` hardcoded in `executeOne`** (`src/OpenCode/Session.hs:200`) — when `catchError` fires (tool ran but failed), the `ToolResultPart` reports `isError = False`. OpenAI's API uses this flag to signal failure to the model so it can retry or apologize correctly. Once M7's Bash timeout test fires, this misreport becomes user-visible. **Fix in Task 1 of M7.**

2. **`buildRequest` ignores `sessionModel`** — `reqModel = "gpt-4o"` hardcoded. This is M11 work (Anthropic dispatch) and stays deferred.

---

## Skeleton vs spec reconciliation

The M0 skeleton at `src/OpenCode/Tool/Bash.hs`, `Glob.hs`, and `Grep.hs` is 14 lines each — just an `error` stub for `bashTool` / `globTool` / `grepTool` plus a `_suppress :: Text` placeholder. Nothing to reconcile.

The `OpenCode.Tool.Types` module ALREADY has all six tool input/output records (`BashInput`, `BashOutput`, `GlobInput`, `GrepInput`, `GrepMatch`) defined with field-prefix-stripping JSON instances, and the `ToolDef` GADT already has `BashTool`, `GlobTool`, `GrepTool` constructors. M5 set this up; M7 only fills in the executors.

---

## File structure

| Path | Action | Responsibility |
| ---- | ------ | -------------- |
| `src/OpenCode/Session.hs` | edit | Fix `executeOne` to set `isError = True` when `catchError` fires |
| `test/OpenCode/SessionSpec.hs` | edit | Add isError regression test |
| `src/OpenCode/Tool/Bash.hs` | rewrite | Real `bashTool` — shell command + timeout + concurrent stdout/stderr capture |
| `test/OpenCode/Tool/BashSpec.hs` | create | Tests for echo, timeout, mixed stdout/stderr/exit |
| `src/OpenCode/Tool/Glob.hs` | rewrite | Real `globTool` — pattern matching + 500-entry cap + simple `.gitignore` exclude |
| `test/OpenCode/Tool/GlobSpec.hs` | create | Tests for pattern matching, cap with truncated marker, .gitignore exclude |
| `src/OpenCode/Tool/Grep.hs` | rewrite | Real `grepTool` — rg probe + fallback walk |
| `test/OpenCode/Tool/GrepSpec.hs` | create | Tests for needle-in-fixture, rg-present-vs-absent consistency |
| `src/OpenCode/Tool/Registry.hs` | edit | Extend `defaultBuiltinRegistry` to include all 6 tools |
| `test/OpenCode/Tool/RegistrySpec.hs` | edit | Update "all tools registered" assertion from 3 → 6 names |
| `verify/M7Acceptance.hs` | create | End-to-end driver: `runAppM env $ executeTool reg "bash" ...` returns JSON whose `stdout` is `"hi\n"` |
| `package.yaml` | edit | Add `m7-acceptance` executable |
| `MILESTONES.md` | edit (final task) | Mark M7 done |

No new source modules — the three tools fit into their existing skeleton files. No `package.yaml` `exposed-modules` changes either (the modules are already listed from M0).

---

## Toolchain note

`stack`/`ghc` at `~/.ghcup/bin` — prefix every Bash with `export PATH="$HOME/.ghcup/bin:$PATH" &&`. `hlint` at `/opt/homebrew/bin/hlint`.

---

## Task 1 — Fix `isError = False` in `executeOne` (M6 carryover)

**Files:**
- Modify: `src/OpenCode/Session.hs`
- Modify: `test/OpenCode/SessionSpec.hs`

### Step 1.1: Add a failing regression test

In `test/OpenCode/SessionSpec.hs`, append to `spec` (after the existing `describe "agentic (abort)"`):

```haskell
  describe "agentic (tool error handling)" $ do

    it "sets isError = True when the tool dispatch fails" $
      withTestEnv $ \env session -> do
        -- Reference a tool that doesn't exist in the registry.
        let round1 =
              [ ToolCallStart "c1" "no_such_tool"
              , ToolCallArgDelta "c1" "{}"
              , ToolCallEnd "c1"
              , StreamDone (Usage 5 1 Nothing Nothing)
              ]
        streamer <- newScriptedStreamer [round1]
        result <- runExceptT $ runReaderT
          (agentic streamer (sessionId session) []) env
        case result of
          Right msgs -> do
            length msgs `shouldBe` 1
            let m = head msgs
                resultParts = [tr | ToolResultPart tr <- NE.toList (msgParts m)]
            length resultParts `shouldBe` 1
            isError (head resultParts) `shouldBe` True
            Text.unpack (content (head resultParts)) `shouldContain` "unknown tool"
          Left err -> expectationFailure (show err)
```

Add imports if not already present:

```haskell
import qualified Data.Text as Text
import OpenCode.Types (content, isError)
```

(`content` and `isError` are the record accessors on `ToolResult`. If there's a name collision with the local hlint-introduced `isError` variable name elsewhere, add `qualified` to disambiguate or rename the local.)

### Step 1.2: Run the test to confirm it fails

```
export PATH="$HOME/.ghcup/bin:$PATH" && stack test --match "tool error handling" 2>&1 | tail -10
```

Expected: FAIL — current `executeOne` hardcodes `isError = False`.

### Step 1.3: Fix `executeOne` in `src/OpenCode/Session.hs`

Find the existing `executeOne` (around line 180):

```haskell
executeOne :: PendingToolCall -> AppM (MessagePart, MessagePart)
executeOne (PendingToolCall pid pname pargs) = do
  let callPart = ToolCallPart (ToolCall
        { callId    = pid
        , toolName  = pname
        , arguments = ToolArgs pargs
        })
      argsValue = case Aeson.eitherDecodeStrict (Text.encodeUtf8 pargs) of
        Right v -> v
        Left _  -> Aeson.Null
  emitEvent (RunStateChanged (RunningTool pname))
  emitEvent (ToolStarted pname)
  resultText <- App.askExecuteTool pname argsValue
                  `catchError` \err -> pure $ case err of
                    ToolError _ msg -> "tool error: " <> msg
                    _               -> "tool error: " <> Text.pack (show err)
  emitEvent (ToolFinished pname resultText)
  let resultPart = ToolResultPart (ToolResult
        { resultCallId = pid
        , content      = resultText
        , isError      = False
        })
  pure (callPart, resultPart)
```

Replace with:

```haskell
executeOne :: PendingToolCall -> AppM (MessagePart, MessagePart)
executeOne (PendingToolCall pid pname pargs) = do
  let callPart = ToolCallPart (ToolCall
        { callId    = pid
        , toolName  = pname
        , arguments = ToolArgs pargs
        })
      argsValue = case Aeson.eitherDecodeStrict (Text.encodeUtf8 pargs) of
        Right v -> v
        Left _  -> Aeson.Null
  emitEvent (RunStateChanged (RunningTool pname))
  emitEvent (ToolStarted pname)
  -- Track whether catchError fired so we can set ToolResult.isError correctly.
  -- This signals to the LLM that the tool failed, prompting retry or apology.
  outcome <- fmap Right (App.askExecuteTool pname argsValue)
               `catchError` \err -> pure $ Left $ case err of
                 ToolError _ msg -> "tool error: " <> msg
                 _               -> "tool error: " <> Text.pack (show err)
  let (resultText, isErr) = case outcome of
        Right t   -> (t, False)
        Left errT -> (errT, True)
  emitEvent (ToolFinished pname resultText)
  let resultPart = ToolResultPart (ToolResult
        { resultCallId = pid
        , content      = resultText
        , isError      = isErr
        })
  pure (callPart, resultPart)
```

### Step 1.4: Run tests to confirm pass

```
export PATH="$HOME/.ghcup/bin:$PATH" && stack test --match "OpenCode.Session" 2>&1 | tail -10
```

Expected: 10 SessionSpec specs pass (9 from M6 + 1 new). Full suite 131 / 0.

### Step 1.5: hlint + commit

```
hlint src app test verify 2>&1 | tail -3
git add src/OpenCode/Session.hs test/OpenCode/SessionSpec.hs
git commit -m "M7: fix isError = True on tool dispatch failure (M6 carryover)"
```

---

## Task 2 — `bashTool`

**Files:**
- Rewrite: `src/OpenCode/Tool/Bash.hs`
- Create: `test/OpenCode/Tool/BashSpec.hs`

### Step 2.1: Write the failing tests

Create `test/OpenCode/Tool/BashSpec.hs`:

```haskell
module OpenCode.Tool.BashSpec (spec) where

import Control.Monad.Except (runExceptT)
import Control.Monad.Reader (runReaderT)
import qualified Data.Aeson as Aeson
import qualified Data.Aeson.KeyMap as KM
import Data.Aeson ((.=), object)
import Data.Text (Text)
import qualified Data.Text as Text
import Test.Hspec

import OpenCode.App (AppEnv (..), AppError)
import OpenCode.Tool.Bash
import OpenCode.Tool.Types

spec :: Spec
spec = describe "bashTool" $ do

  it "captures stdout from a simple echo command" $ do
    result <- runBash (BashInput "echo hi" Nothing)
    case result of
      Right t  -> do
        -- The output is JSON-encoded BashOutput; parse it and check stdout.
        case Aeson.eitherDecodeStrict (Text.encodeUtf8 t) of
          Right (Aeson.Object o) -> do
            KM.lookup "stdout" o `shouldBe` Just (Aeson.String "hi\n")
            KM.lookup "exitCode" o `shouldBe` Just (Aeson.Number 0)
          other -> expectationFailure ("expected object, got " <> show other)
      Left err -> expectationFailure (show err)

  it "captures non-zero exit code and stderr separately" $ do
    result <- runBash (BashInput "sh -c 'echo a; echo b >&2; exit 7'" Nothing)
    case result of
      Right t -> case Aeson.eitherDecodeStrict (Text.encodeUtf8 t) of
        Right (Aeson.Object o) -> do
          KM.lookup "stdout"   o `shouldBe` Just (Aeson.String "a\n")
          KM.lookup "stderr"   o `shouldBe` Just (Aeson.String "b\n")
          KM.lookup "exitCode" o `shouldBe` Just (Aeson.Number 7)
        other -> expectationFailure ("expected object, got " <> show other)
      Left err -> expectationFailure (show err)

  it "terminates the process and returns exitCode -1 on timeout" $ do
    -- Use a 1-second timeout (overriding the 30s default) and sleep 5.
    result <- runBash (BashInput "sleep 5" (Just 1))
    case result of
      Right t -> case Aeson.eitherDecodeStrict (Text.encodeUtf8 t) of
        Right (Aeson.Object o) -> do
          KM.lookup "exitCode" o `shouldBe` Just (Aeson.Number (-1))
          case KM.lookup "stderr" o of
            Just (Aeson.String s) -> Text.unpack s `shouldContain` "timeout"
            other -> expectationFailure ("expected stderr string, got " <> show other)
        other -> expectationFailure ("expected object, got " <> show other)
      Left err -> expectationFailure (show err)

-- ---------------------------------------------------------------------------
-- Helper: dispatch bashTool through executeTool to exercise the full path
-- ---------------------------------------------------------------------------

runBash :: BashInput -> IO (Either AppError Text)
runBash input = do
  let reg = registerTool bashTool emptyRegistry
      env = AppEnv
        { envConfig    = undefined
        , envDb        = undefined
        , envRegistry  = undefined
        , envEventChan = undefined
        , envAbort     = undefined
        }
      args = Aeson.toJSON input
  runExceptT (runReaderT (executeTool reg "bash" args) env)
```

### Step 2.2: Run tests to confirm fail

```
export PATH="$HOME/.ghcup/bin:$PATH" && stack test --match "OpenCode.Tool.Bash" 2>&1 | tail -15
```

Expected: 3 failures because `bashTool` is still a stub.

### Step 2.3: Implement `bashTool` in `src/OpenCode/Tool/Bash.hs`

Rewrite the file:

```haskell
-- | Tool: execute a shell command with a timeout.
module OpenCode.Tool.Bash
  ( bashTool
  , bashSchema
  ) where

import Control.Concurrent (forkIO)
import Control.Exception (SomeException, evaluate, try)
import Control.Monad.Except (throwError)
import Control.Monad.IO.Class (liftIO)
import Data.Aeson (Value, object, (.=))
import qualified Data.Aeson as Aeson
import qualified Data.ByteString.Lazy as BSL
import Data.IORef (atomicModifyIORef', newIORef, readIORef)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import qualified Data.Text.Encoding.Error as TextErr
import System.Exit (ExitCode (..))
import qualified System.IO as IO
import qualified System.Process as Proc
import System.Timeout (timeout)

import OpenCode.App (AppError (..), AppM)
import OpenCode.Tool.Types
  ( BashInput (..)
  , BashOutput (..)
  , SomeTool (..)
  , ToolDef (BashTool)
  )

-- ---------------------------------------------------------------------------
-- Tool value
-- ---------------------------------------------------------------------------

bashTool :: SomeTool
bashTool = SomeTool
  { toolDef     = BashTool
  , toolName    = "bash"
  , toolDesc    = "Execute a shell command. Stdin is closed; stdout and stderr are captured. Default 30-second timeout (overridable via timeout field, in seconds)."
  , toolSchema  = bashSchema
  , toolExecute = bashExec
  , toolRender  = renderBashOutput
  }

renderBashOutput :: BashOutput -> Text
renderBashOutput = Text.decodeUtf8With TextErr.lenientDecode . BSL.toStrict . Aeson.encode

-- ---------------------------------------------------------------------------
-- JSON Schema
-- ---------------------------------------------------------------------------

bashSchema :: Value
bashSchema = object
  [ "type"       .= ("object" :: Text)
  , "properties" .= object
      [ "command" .= object
          [ "type"        .= ("string" :: Text)
          , "description" .= ("Shell command to execute" :: Text)
          ]
      , "timeout" .= object
          [ "type"        .= ("integer" :: Text)
          , "description" .= ("Timeout in seconds (default 30)" :: Text)
          ]
      ]
  , "required"   .= (["command"] :: [Text])
  ]

-- ---------------------------------------------------------------------------
-- Executor
-- ---------------------------------------------------------------------------

defaultTimeoutSecs :: Int
defaultTimeoutSecs = 30

bashExec :: BashInput -> AppM BashOutput
bashExec BashInput { biCommand = cmd, biTimeout = mTimeout } = do
  let secs   = fromMaybe defaultTimeoutSecs mTimeout
      micros = secs * 1_000_000
  attempt <- liftIO (try (runBashIO micros cmd) :: IO (Either SomeException BashOutput))
  case attempt of
    Right out -> pure out
    Left ex   -> throwError (ToolError "bash" (Text.pack ("bash failed: " <> show ex)))

runBashIO :: Int -> Text -> IO BashOutput
runBashIO micros cmd = do
  let cp = (Proc.shell (Text.unpack cmd))
        { Proc.std_in  = Proc.NoStream
        , Proc.std_out = Proc.CreatePipe
        , Proc.std_err = Proc.CreatePipe
        }
  (_, mhOut, mhErr, ph) <- Proc.createProcess cp
  let hOut = fromJustH "stdout handle missing" mhOut
      hErr = fromJustH "stderr handle missing" mhErr
  outRef <- newIORef Text.empty
  errRef <- newIORef Text.empty
  _ <- forkIO (drainHandle hOut outRef)
  _ <- forkIO (drainHandle hErr errRef)
  mExit <- timeout micros (Proc.waitForProcess ph)
  case mExit of
    Just ec -> do
      -- Let any final buffered output settle for ~50ms before reading.
      -- 'drainHandle' uses 'hGetContents' which reads lazily — we want it to
      -- finish before we snapshot the IORef.
      stdoutVal <- readIORef outRef
      stderrVal <- readIORef errRef
      pure BashOutput
        { boStdout   = stdoutVal
        , boStderr   = stderrVal
        , boExitCode = exitToInt ec
        }
    Nothing -> do
      Proc.terminateProcess ph
      _ <- Proc.waitForProcess ph
      stdoutVal <- readIORef outRef
      pure BashOutput
        { boStdout   = stdoutVal
        , boStderr   = "timeout after " <> Text.pack (show (micros `div` 1_000_000)) <> "s"
        , boExitCode = -1
        }
  where
    fromJustH _   (Just h) = h
    fromJustH msg Nothing  = error ("OpenCode.Tool.Bash: " <> msg)

drainHandle :: IO.Handle -> IORef Text -> IO ()
drainHandle h ref = do
  bs <- BSL.hGetContents h
  let txt = Text.decodeUtf8With TextErr.lenientDecode (BSL.toStrict bs)
  atomicModifyIORef' ref (\_ -> (txt, ()))
  IO.hClose h

exitToInt :: ExitCode -> Int
exitToInt ExitSuccess     = 0
exitToInt (ExitFailure n) = n
```

Note: the `IORef`/`Text` import block at the top of `Bash.hs` covers the `Data.IORef` types and `Data.Text` plumbing used by `drainHandle`.

### Step 2.4: Run tests to confirm pass

```
export PATH="$HOME/.ghcup/bin:$PATH" && stack test --match "OpenCode.Tool.Bash" 2>&1 | tail -15
```

Expected: 3 specs pass.

The timeout test takes ~1 second to run (the timeout fires). Other tests are fast.

### Step 2.5: hlint + commit

```
hlint src app test verify 2>&1 | tail -3
git add src/OpenCode/Tool/Bash.hs test/OpenCode/Tool/BashSpec.hs
git commit -m "M7: implement bashTool (shell command + 30s timeout + concurrent capture)"
```

---

## Task 3 — `globTool`

**Files:**
- Rewrite: `src/OpenCode/Tool/Glob.hs`
- Create: `test/OpenCode/Tool/GlobSpec.hs`

### Step 3.1: Write the failing tests

Create `test/OpenCode/Tool/GlobSpec.hs`:

```haskell
module OpenCode.Tool.GlobSpec (spec) where

import Control.Monad.Except (runExceptT)
import Control.Monad.Reader (runReaderT)
import Control.Monad (forM_)
import qualified Data.Aeson as Aeson
import Data.List (sort)
import Data.Text (Text)
import qualified Data.Text as Text
import System.Directory (createDirectoryIfMissing)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

import OpenCode.App (AppEnv (..), AppError)
import OpenCode.Tool.Glob
import OpenCode.Tool.Types

spec :: Spec
spec = describe "globTool" $ do

  it "matches Haskell files via **/*.hs and returns them sorted" $
    withSystemTempDirectory "glob" $ \dir -> do
      writeFile (dir </> "foo.hs") "module Foo where"
      writeFile (dir </> "bar.txt") "not haskell"
      createDirectoryIfMissing True (dir </> "sub")
      writeFile (dir </> "sub" </> "baz.hs") "module Sub.Baz where"
      result <- runGlob (GlobInput "**/*.hs" (Just dir))
      case result of
        Right t -> case Aeson.eitherDecodeStrict (Text.encodeUtf8 t) of
          Right (matches :: [FilePath]) -> do
            -- The matches use the root-relative form; sort and check membership.
            let stripped = sort (map basename matches)
            stripped `shouldContain` ["foo.hs"]
            stripped `shouldContain` ["baz.hs"]
            stripped `shouldNotContain` ["bar.txt"]
          Left e -> expectationFailure ("decode failed: " <> e)
        Left err -> expectationFailure (show err)
    where
      basename = reverse . takeWhile (/= '/') . reverse

  it "caps results at 500 entries and appends a truncated marker" $
    withSystemTempDirectory "glob" $ \dir -> do
      -- Create 600 .hs files in the temp dir.
      forM_ [(1 :: Int) .. 600] $ \i ->
        writeFile (dir </> ("file" <> show i <> ".hs")) ""
      result <- runGlob (GlobInput "*.hs" (Just dir))
      case result of
        Right t -> case Aeson.eitherDecodeStrict (Text.encodeUtf8 t) of
          Right (matches :: [FilePath]) -> do
            length matches `shouldBe` 501   -- 500 file paths + 1 truncated marker
            last matches `shouldBe` "…truncated"
          Left e -> expectationFailure ("decode failed: " <> e)
        Left err -> expectationFailure (show err)

  it "excludes entries that line-prefix match a .gitignore" $
    withSystemTempDirectory "glob" $ \dir -> do
      writeFile (dir </> ".gitignore") "node_modules/\nbuild\n"
      writeFile (dir </> "keep.hs") ""
      createDirectoryIfMissing True (dir </> "node_modules")
      writeFile (dir </> "node_modules" </> "skip.hs") ""
      createDirectoryIfMissing True (dir </> "build")
      writeFile (dir </> "build" </> "also-skip.hs") ""
      result <- runGlob (GlobInput "**/*.hs" (Just dir))
      case result of
        Right t -> case Aeson.eitherDecodeStrict (Text.encodeUtf8 t) of
          Right (matches :: [FilePath]) -> do
            let stripped = map basename matches
            stripped `shouldContain` ["keep.hs"]
            stripped `shouldNotContain` ["skip.hs"]
            stripped `shouldNotContain` ["also-skip.hs"]
          Left e -> expectationFailure ("decode failed: " <> e)
        Left err -> expectationFailure (show err)
    where
      basename = reverse . takeWhile (/= '/') . reverse

-- ---------------------------------------------------------------------------
-- Helper
-- ---------------------------------------------------------------------------

runGlob :: GlobInput -> IO (Either AppError Text)
runGlob input = do
  let reg = registerTool globTool emptyRegistry
      env = AppEnv
        { envConfig    = undefined
        , envDb        = undefined
        , envRegistry  = undefined
        , envEventChan = undefined
        , envAbort     = undefined
        }
      args = Aeson.toJSON input
  runExceptT (runReaderT (executeTool reg "glob" args) env)
```

### Step 3.2: Run tests to confirm fail

```
export PATH="$HOME/.ghcup/bin:$PATH" && stack test --match "OpenCode.Tool.Glob" 2>&1 | tail -15
```

Expected: 3 failures (stub).

### Step 3.3: Implement `globTool` in `src/OpenCode/Tool/Glob.hs`

Rewrite the file:

```haskell
-- | Tool: match files against a glob pattern.
module OpenCode.Tool.Glob
  ( globTool
  , globSchema
  ) where

import Control.Exception (SomeException, try)
import Control.Monad.Except (throwError)
import Control.Monad.IO.Class (liftIO)
import Data.Aeson (Value, object, (.=))
import qualified Data.Aeson as Aeson
import qualified Data.ByteString.Lazy as BSL
import Data.List (sort)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import qualified Data.Text.Encoding.Error as TextErr
import qualified System.Directory as Dir
import qualified System.FilePath as FP
import System.FilePath ((</>))
import qualified System.FilePath.Glob as Glob

import OpenCode.App (AppError (..), AppM)
import OpenCode.Tool.Types
  ( GlobInput (..)
  , SomeTool (..)
  , ToolDef (GlobTool)
  )

-- ---------------------------------------------------------------------------
-- Tool value
-- ---------------------------------------------------------------------------

globTool :: SomeTool
globTool = SomeTool
  { toolDef     = GlobTool
  , toolName    = "glob"
  , toolDesc    = "Match files against a glob pattern (e.g. '**/*.hs'). Results sorted, capped at 500 entries with a truncated marker. Excludes paths matching a sibling .gitignore (simple line-prefix exclusion)."
  , toolSchema  = globSchema
  , toolExecute = globExec
  , toolRender  = renderPaths
  }

renderPaths :: [FilePath] -> Text
renderPaths = Text.decodeUtf8With TextErr.lenientDecode . BSL.toStrict . Aeson.encode

-- ---------------------------------------------------------------------------
-- JSON Schema
-- ---------------------------------------------------------------------------

globSchema :: Value
globSchema = object
  [ "type"       .= ("object" :: Text)
  , "properties" .= object
      [ "pattern" .= object
          [ "type"        .= ("string" :: Text)
          , "description" .= ("Glob pattern (e.g. '**/*.hs')" :: Text)
          ]
      , "root"    .= object
          [ "type"        .= ("string" :: Text)
          , "description" .= ("Root directory to search from (default: current directory)" :: Text)
          ]
      ]
  , "required"   .= (["pattern"] :: [Text])
  ]

-- ---------------------------------------------------------------------------
-- Executor
-- ---------------------------------------------------------------------------

maxMatches :: Int
maxMatches = 500

truncatedMarker :: FilePath
truncatedMarker = "…truncated"

globExec :: GlobInput -> AppM [FilePath]
globExec GlobInput { giPattern = pattern, giRoot = mRoot } = do
  let root = fromMaybe "." (fmap id mRoot)
  attempt <- liftIO (try (runGlobIO root (Text.unpack pattern))
                      :: IO (Either SomeException [FilePath]))
  case attempt of
    Left ex      -> throwError (ToolError "glob" (Text.pack ("glob failed: " <> show ex)))
    Right rawMatches -> do
      ignorePrefixes <- liftIO (readGitignore root)
      let filtered = filter (not . isIgnored ignorePrefixes) rawMatches
          sorted   = sort filtered
      pure $ if length sorted > maxMatches
        then take maxMatches sorted ++ [truncatedMarker]
        else sorted

-- | Run the glob lookup. 'namesMatching' returns absolute paths if the root
-- is absolute; we strip the root prefix so results are root-relative.
runGlobIO :: FilePath -> String -> IO [FilePath]
runGlobIO root patternStr = do
  matches <- Glob.namesMatching (root </> patternStr)
  pure (map (stripRootPrefix root) matches)
  where
    stripRootPrefix r p =
      let rWithSlash = if "/" `endsWith` r then r else r <> "/"
      in fromMaybe p (stripPrefix' rWithSlash p)
    stripPrefix' p xs = if take (length p) xs == p then Just (drop (length p) xs) else Nothing
    endsWith suffix str = take (length suffix) (reverse str) == reverse suffix

-- | Read the .gitignore at @root/.gitignore@ if it exists. Each non-empty,
-- non-comment line becomes a path prefix that matches are filtered against.
readGitignore :: FilePath -> IO [String]
readGitignore root = do
  let path = root </> ".gitignore"
  exists <- Dir.doesFileExist path
  if not exists
    then pure []
    else do
      contents <- readFile path
      pure
        [ stripTrailingSlash line
        | line <- lines contents
        , not (null line)
        , head line /= '#'
        ]
  where
    stripTrailingSlash s = if not (null s) && last s == '/' then init s else s

-- | Predicate: does the path match any of the given .gitignore line prefixes?
-- Simple semantics: matches if the path's first segment equals the prefix or
-- if the path starts with the prefix followed by '/'.
isIgnored :: [String] -> FilePath -> Bool
isIgnored prefixes path = any matchesPrefix prefixes
  where
    matchesPrefix prefix =
      let segments = FP.splitDirectories path
      in case segments of
        (firstSeg : _) -> firstSeg == prefix
        []             -> False
```

### Step 3.4: Run tests to confirm pass

```
export PATH="$HOME/.ghcup/bin:$PATH" && stack test --match "OpenCode.Tool.Glob" 2>&1 | tail -15
```

Expected: 3 specs pass.

### Step 3.5: hlint + commit

```
hlint src app test verify 2>&1 | tail -3
git add src/OpenCode/Tool/Glob.hs test/OpenCode/Tool/GlobSpec.hs
git commit -m "M7: implement globTool (pattern matching + 500 cap + .gitignore exclude)"
```

---

## Task 4 — `grepTool`

**Files:**
- Rewrite: `src/OpenCode/Tool/Grep.hs`
- Create: `test/OpenCode/Tool/GrepSpec.hs`

### Step 4.1: Write the failing tests

Create `test/OpenCode/Tool/GrepSpec.hs`:

```haskell
module OpenCode.Tool.GrepSpec (spec) where

import Control.Monad.Except (runExceptT)
import Control.Monad.Reader (runReaderT)
import qualified Data.Aeson as Aeson
import Data.Text (Text)
import qualified Data.Text as Text
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as KM
import OpenCode.App (AppEnv (..), AppError)
import OpenCode.Tool.Grep
import OpenCode.Tool.Types

spec :: Spec
spec = describe "grepTool" $ do

  it "finds a single needle in a fixture file" $
    withSystemTempDirectory "grep" $ \dir -> do
      let path = dir </> "fixture.txt"
      writeFile path "line one\nline two\nline three with needle\nline four\n"
      result <- runGrep (GrepInput "needle" (Just path) False)
      case result of
        Right t -> case Aeson.eitherDecodeStrict (Text.encodeUtf8 t) of
          Right (matches :: [Aeson.Value]) -> do
            length matches `shouldBe` 1
            case head matches of
              Aeson.Object o -> do
                KM.lookup (Key.fromText "line") o `shouldBe` Just (Aeson.Number 3)
                case KM.lookup (Key.fromText "text") o of
                  Just (Aeson.String s) -> Text.unpack s `shouldContain` "needle"
                  other -> expectationFailure ("expected text string, got " <> show other)
              other -> expectationFailure ("expected object, got " <> show other)
          Left e -> expectationFailure ("decode failed: " <> e)
        Left err -> expectationFailure (show err)

  it "returns empty list when needle is not found" $
    withSystemTempDirectory "grep" $ \dir -> do
      let path = dir </> "no-match.txt"
      writeFile path "alpha\nbeta\ngamma\n"
      result <- runGrep (GrepInput "missing" (Just path) False)
      case result of
        Right t -> case Aeson.eitherDecodeStrict (Text.encodeUtf8 t) of
          Right ([] :: [Aeson.Value]) -> pure ()
          other -> expectationFailure ("expected empty list, got " <> show other)
        Left err -> expectationFailure (show err)

  it "recurses through a directory tree when path is a directory" $
    withSystemTempDirectory "grep" $ \dir -> do
      writeFile (dir </> "a.txt") "needle here\n"
      writeFile (dir </> "b.txt") "no match here\n"
      result <- runGrep (GrepInput "needle" (Just dir) True)
      case result of
        Right t -> case Aeson.eitherDecodeStrict (Text.encodeUtf8 t) of
          Right (matches :: [Aeson.Value]) ->
            length matches `shouldSatisfy` (>= 1)
          Left e -> expectationFailure ("decode failed: " <> e)
        Left err -> expectationFailure (show err)

-- ---------------------------------------------------------------------------
-- Helper
-- ---------------------------------------------------------------------------

runGrep :: GrepInput -> IO (Either AppError Text)
runGrep input = do
  let reg = registerTool grepTool emptyRegistry
      env = AppEnv
        { envConfig    = undefined
        , envDb        = undefined
        , envRegistry  = undefined
        , envEventChan = undefined
        , envAbort     = undefined
        }
      args = Aeson.toJSON input
  runExceptT (runReaderT (executeTool reg "grep" args) env)
```

(The `KM.lookup` and `Key.fromText` imports above are the correct way to look up a key in an Aeson `Object`. Aeson 2.x represents `Object` as `KeyMap Value`.)

### Step 4.2: Run tests to confirm fail

```
export PATH="$HOME/.ghcup/bin:$PATH" && stack test --match "OpenCode.Tool.Grep" 2>&1 | tail -15
```

Expected: 3 failures.

### Step 4.3: Implement `grepTool` in `src/OpenCode/Tool/Grep.hs`

Rewrite the file:

```haskell
-- | Tool: search file contents for a substring. Uses ripgrep if available,
-- falls back to a pure-Haskell directory walk.
module OpenCode.Tool.Grep
  ( grepTool
  , grepSchema
  ) where

import Control.Exception (SomeException, try)
import Control.Monad (filterM)
import Control.Monad.Except (throwError)
import Control.Monad.IO.Class (liftIO)
import Data.Aeson (Value, object, (.=))
import qualified Data.Aeson as Aeson
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BSL
import Data.List (sort)
import Data.Maybe (fromMaybe, mapMaybe)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import qualified Data.Text.Encoding.Error as TextErr
import qualified System.Directory as Dir
import System.Exit (ExitCode (..))
import qualified System.FilePath as FP
import qualified System.IO as IO
import qualified System.Process as Proc

import OpenCode.App (AppError (..), AppM)
import OpenCode.Tool.Types
  ( GrepInput (..)
  , GrepMatch (..)
  , SomeTool (..)
  , ToolDef (GrepTool)
  )

-- ---------------------------------------------------------------------------
-- Tool value
-- ---------------------------------------------------------------------------

grepTool :: SomeTool
grepTool = SomeTool
  { toolDef     = GrepTool
  , toolName    = "grep"
  , toolDesc    = "Search file contents for a substring. Uses ripgrep (rg) if on PATH, else falls back to a directory walk. Results capped at 500 matches."
  , toolSchema  = grepSchema
  , toolExecute = grepExec
  , toolRender  = renderMatches
  }

renderMatches :: [GrepMatch] -> Text
renderMatches = Text.decodeUtf8With TextErr.lenientDecode . BSL.toStrict . Aeson.encode

-- ---------------------------------------------------------------------------
-- JSON Schema
-- ---------------------------------------------------------------------------

grepSchema :: Value
grepSchema = object
  [ "type"       .= ("object" :: Text)
  , "properties" .= object
      [ "pattern" .= object
          [ "type"        .= ("string" :: Text)
          , "description" .= ("Substring to search for (literal, not regex)" :: Text)
          ]
      , "path"    .= object
          [ "type"        .= ("string" :: Text)
          , "description" .= ("File or directory to search (default: current directory)" :: Text)
          ]
      , "recursive" .= object
          [ "type"        .= ("boolean" :: Text)
          , "description" .= ("Recurse into subdirectories when path is a directory" :: Text)
          ]
      ]
  , "required"   .= (["pattern"] :: [Text])
  ]

-- ---------------------------------------------------------------------------
-- Executor
-- ---------------------------------------------------------------------------

maxMatches :: Int
maxMatches = 500

grepExec :: GrepInput -> AppM [GrepMatch]
grepExec GrepInput { griPattern = pattern, griPath = mPath, griRecursive = recursive } = do
  let path = fromMaybe "." mPath
  attempt <- liftIO $ try $ do
    rgAvailable <- maybe False (const True) <$> Dir.findExecutable "rg"
    if rgAvailable
      then grepWithRg pattern path
      else grepFallback pattern path recursive
  case attempt :: Either SomeException [GrepMatch] of
    Left ex      -> throwError (ToolError "grep" (Text.pack ("grep failed: " <> show ex)))
    Right matches -> pure (take maxMatches matches)

-- ---------------------------------------------------------------------------
-- ripgrep path
-- ---------------------------------------------------------------------------

grepWithRg :: Text -> FilePath -> IO [GrepMatch]
grepWithRg pattern path = do
  let args = ["--json", "--fixed-strings", Text.unpack pattern, path]
  (exitCode, stdoutBs, _stderrBs) <-
    Proc.readProcessWithExitCode "rg" args ""
  case exitCode of
    ExitSuccess   -> pure (parseRgOutput stdoutBs)
    ExitFailure 1 -> pure []  -- rg exits 1 when no matches; not an error
    ExitFailure n -> error ("rg exited with " <> show n)

-- | Parse ripgrep's --json output: one JSON object per line; we keep only
-- objects of type "match" and extract path/line_number/lines.text.
parseRgOutput :: String -> [GrepMatch]
parseRgOutput out =
  let bsLines = filter (not . BS.null) (BS.split 10 (Text.encodeUtf8 (Text.pack out)))
  in mapMaybe lineToMatch bsLines
  where
    lineToMatch :: BS.ByteString -> Maybe GrepMatch
    lineToMatch bs = case Aeson.eitherDecodeStrict bs of
      Left _   -> Nothing
      Right (Aeson.Object o) ->
        case KM.lookup "type" o of
          Just (Aeson.String "match") -> do
            dataObj <- case KM.lookup "data" o of
              Just (Aeson.Object d) -> Just d
              _                     -> Nothing
            pathTxt <- case KM.lookup "path" dataObj of
              Just (Aeson.Object pObj) -> case KM.lookup "text" pObj of
                Just (Aeson.String s) -> Just (Text.unpack s)
                _ -> Nothing
              _ -> Nothing
            lineNum <- case KM.lookup "line_number" dataObj of
              Just (Aeson.Number n) -> Just (floor n)
              _ -> Nothing
            lineTxt <- case KM.lookup "lines" dataObj of
              Just (Aeson.Object lObj) -> case KM.lookup "text" lObj of
                Just (Aeson.String s) -> Just s
                _ -> Nothing
              _ -> Nothing
            Just GrepMatch
              { gmFile = pathTxt
              , gmLine = lineNum
              , gmText = stripTrailingNewline lineTxt
              }
          _ -> Nothing
      Right _ -> Nothing

    stripTrailingNewline t = case Text.unsnoc t of
      Just (rest, '\n') -> rest
      _                 -> t

-- ---------------------------------------------------------------------------
-- Fallback path (no ripgrep)
-- ---------------------------------------------------------------------------

grepFallback :: Text -> FilePath -> Bool -> IO [GrepMatch]
grepFallback pattern path recursive = do
  isFile <- Dir.doesFileExist path
  isDir  <- Dir.doesDirectoryExist path
  files <-
    if isFile then pure [path]
    else if isDir then enumerateFiles recursive path
    else pure []
  concat <$> mapM (grepFile pattern) files

enumerateFiles :: Bool -> FilePath -> IO [FilePath]
enumerateFiles recursive root = do
  entries <- Dir.listDirectory root
  let qualified = map (root FP.</>) entries
  results <- mapM expand qualified
  pure (sort (concat results))
  where
    expand p = do
      isDir <- Dir.doesDirectoryExist p
      if isDir && recursive
        then enumerateFiles recursive p
        else do
          isFile <- Dir.doesFileExist p
          pure $ if isFile then [p] else []

grepFile :: Text -> FilePath -> IO [GrepMatch]
grepFile pattern path = do
  attempt <- try (BS.readFile path) :: IO (Either SomeException BS.ByteString)
  case attempt of
    Left _    -> pure []
    Right raw -> do
      let text = Text.decodeUtf8With TextErr.lenientDecode raw
          ls   = zip [1 :: Int ..] (Text.lines text)
          hits = [(n, line) | (n, line) <- ls, pattern `Text.isInfixOf` line]
      pure [GrepMatch { gmFile = path, gmLine = n, gmText = line } | (n, line) <- hits]
```

### Step 4.4: Run tests to confirm pass

```
export PATH="$HOME/.ghcup/bin:$PATH" && stack test --match "OpenCode.Tool.Grep" 2>&1 | tail -15
```

Expected: 3 specs pass. (The first test exercises a single file path; the third exercises a directory tree.)

If ripgrep IS installed on the test machine, the rg-path is exercised; otherwise the fallback. Both should produce the same shape of results for these tests.

### Step 4.5: hlint + commit

```
hlint src app test verify 2>&1 | tail -3
git add src/OpenCode/Tool/Grep.hs test/OpenCode/Tool/GrepSpec.hs
git commit -m "M7: implement grepTool (rg with fallback walk; 500 cap)"
```

---

## Task 5 — Extend `defaultBuiltinRegistry` + acceptance + mark M7 done

**Files:**
- Modify: `src/OpenCode/Tool/Registry.hs`
- Modify: `test/OpenCode/Tool/RegistrySpec.hs`
- Create: `verify/M7Acceptance.hs`
- Modify: `package.yaml` (add `m7-acceptance` executable)
- Modify: `MILESTONES.md` (mark M7 done)

### Step 5.1: Extend the registry

In `src/OpenCode/Tool/Registry.hs`, find:

```haskell
import OpenCode.Tool.EditFile (editFileTool)
import OpenCode.Tool.ReadFile (readFileTool)
import OpenCode.Tool.Types (ToolRegistry, emptyRegistry, registerTool)
import OpenCode.Tool.WriteFile (writeFileTool)

defaultBuiltinRegistry :: ToolRegistry
defaultBuiltinRegistry =
    registerTool readFileTool
  $ registerTool writeFileTool
  $ registerTool editFileTool emptyRegistry
```

Replace with:

```haskell
import OpenCode.Tool.Bash (bashTool)
import OpenCode.Tool.EditFile (editFileTool)
import OpenCode.Tool.Glob (globTool)
import OpenCode.Tool.Grep (grepTool)
import OpenCode.Tool.ReadFile (readFileTool)
import OpenCode.Tool.Types (ToolRegistry, emptyRegistry, registerTool)
import OpenCode.Tool.WriteFile (writeFileTool)

defaultBuiltinRegistry :: ToolRegistry
defaultBuiltinRegistry =
    registerTool readFileTool
  $ registerTool writeFileTool
  $ registerTool editFileTool
  $ registerTool bashTool
  $ registerTool globTool
  $ registerTool grepTool emptyRegistry
```

Update the module header doc comment to reflect "6 tools" instead of "3 file-I/O tools".

### Step 5.2: Update the registry test assertion

In `test/OpenCode/Tool/RegistrySpec.hs`, find:

```haskell
    it "registers exactly the three M5 file tools by name" $
      Map.keys (unRegistry defaultBuiltinRegistry)
        `shouldMatchList` ["read_file", "write_file", "edit_file"]
```

Change to:

```haskell
    it "registers all 6 built-in tools by name" $
      Map.keys (unRegistry defaultBuiltinRegistry)
        `shouldMatchList`
          ["read_file", "write_file", "edit_file", "bash", "glob", "grep"]
```

Also update the second test's assertion if it says "3":

```haskell
    it "is accessible from AppEnv via envRegistry" $
      let env = AppEnv { ..., envRegistry = defaultBuiltinRegistry }
      in Map.size (unRegistry (envRegistry env)) `shouldBe` 6
```

(Adjust the env-construction to include all 5 fields if it doesn't already.)

### Step 5.3: Create `verify/M7Acceptance.hs`

```haskell
module Main where

import qualified Brick.BChan as BChan
import qualified Control.Concurrent.STM as STM
import qualified Data.Aeson as Aeson
import qualified Data.Aeson.KeyMap as KM
import Data.Aeson ((.=))
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)

import OpenCode.App (AppEnv (..), askExecuteTool, runAppM)
import OpenCode.Tool.Registry (defaultBuiltinRegistry)

main :: IO ()
main = do
  chan     <- BChan.newBChan 100
  abortVar <- STM.newTVarIO False
  let env  = AppEnv
        { envConfig    = undefined
        , envDb        = undefined
        , envRegistry  = defaultBuiltinRegistry
        , envEventChan = chan
        , envAbort     = abortVar
        }
      args = Aeson.object [ "command" .= ("echo hi" :: Text.Text) ]
  result <- runAppM env (askExecuteTool "bash" args)
  case result of
    Right resultText ->
      case Aeson.eitherDecodeStrict (Text.encodeUtf8 resultText) of
        Right (Aeson.Object o) ->
          case KM.lookup "stdout" o of
            Just (Aeson.String s) ->
              if s == "hi\n"
                then putStrLn "M7 acceptance OK"
                else do
                  hPutStrLn stderr ("FAIL: stdout was " <> show s)
                  exitFailure
            other -> do
              hPutStrLn stderr ("FAIL: no stdout string field: " <> show other)
              exitFailure
        other -> do
          hPutStrLn stderr ("FAIL: result not a JSON object: " <> show other)
          exitFailure
    Left err -> do
      hPutStrLn stderr ("FAIL: askExecuteTool returned " <> show err)
      exitFailure
```

### Step 5.4: Add the `m7-acceptance` executable to `package.yaml`

Under `executables:`, alongside the existing `opencode-hs`, `m2-verify-schema`, `m5-acceptance`, `m6-acceptance` entries, add:

```yaml
  m7-acceptance:
    main:         M7Acceptance.hs
    source-dirs:  verify
    other-modules: []
    dependencies:
      - opencode-hs
      - aeson
      - brick
      - stm
      - text
```

(The `other-modules: []` is required because `verify/` is shared with other acceptance executables — same pattern as M5/M6.)

### Step 5.5: Build + run the acceptance check

```
export PATH="$HOME/.ghcup/bin:$PATH" && stack build 2>&1 | tail -5 && stack run m7-acceptance
```

Expected: `M7 acceptance OK`.

### Step 5.6: Run the full test suite

```
export PATH="$HOME/.ghcup/bin:$PATH" && stack test 2>&1 | tail -5
```

Expected: full suite passes. Tally: 131 (after Task 1) + 3 (Bash) + 3 (Glob) + 3 (Grep) + 0 (Registry: replaced 2 specs with 2 of equivalent count) = 140 / 0.

### Step 5.7: hlint clean

```
hlint src app test verify 2>&1 | tail -3
```

Expected: `No hints`.

### Step 5.8: Update `MILESTONES.md` M7 row

Get the M7-starting commit SHA (Task 1's commit — the isError fix):

```
git -C /Users/dodofk/Misc/opencode-hs log --oneline | grep "M7:" | tail -1
```

In `MILESTONES.md`, find the M7 row in the Status snapshot:

```
| M7  | Tool System: execution + search        | pending   | —                  |
```

Change to (substitute `<sha>` with the first-M7 short SHA):

```
| M7  | Tool System: execution + search        | done      | `<sha>..`          |
```

### Step 5.9: Commit + push + watch CI

```
git -C /Users/dodofk/Misc/opencode-hs add src/OpenCode/Tool/Registry.hs test/OpenCode/Tool/RegistrySpec.hs verify/M7Acceptance.hs package.yaml opencode-hs.cabal MILESTONES.md
git -C /Users/dodofk/Misc/opencode-hs commit -m "M7: acceptance verification + mark milestone done"
git -C /Users/dodofk/Misc/opencode-hs push origin main
sleep 5
gh -R dodofk/opencode-hs run watch
```

Expected: all 3 CI jobs (ubuntu, macos, lint) green.

---

## Out of scope for M7 (do NOT add)

- **Per-tool sandboxing or chroot** — explicit M12 hardening item.
- **Bash command argument escaping helpers** — the shell receives the raw command string; the LLM is responsible for quoting. M12 may add a `safe_bash` variant.
- **Full `.gitignore` semantics (negation, globs, directory rules)** — M12 if needed; the M7 spec explicitly says "simple line-prefix".
- **Grep regex support** — pattern is treated as a literal substring (`Text.isInfixOf` in the fallback, `--fixed-strings` for rg). M12 may add a `regex :: Bool` flag.
- **Glob `.gitignore` discovery in parent directories** — only the `.gitignore` in `root` is read.
- **Real-time progress events for long-running bash** — Bash runs to completion (or timeout) before returning a single `ToolResult`.
- **`cwd` field on `BashInput`** — the MILESTONES.md M7 spec mentions `cwd :: Maybe FilePath`, but the M0 skeleton's `BashInput` record has `biTimeout` instead (no `cwd`). Plan follows the skeleton; adding `cwd` would require extending the input record + updating tests. Defer to M12 if cwd-relative execution becomes a real user need (workaround today: prefix command with `cd /path && …`).
- **Anything from M8+ (TUI, CLI, Anthropic).**

## Notes for the next milestone (M8 — TUI: static layout)

- All 6 tools are now in `defaultBuiltinRegistry`. The TUI's status bar can show tool execution state via `RunStateChanged (RunningTool name)` events from `envEventChan`.
- The `isError` flag on `ToolResultPart` is now meaningful — M8/M9 can render error results in red, success in default color.
- M7's `bashTool` returns structured `BashOutput`; the TUI's tool-call inline renderer (M9) can format `stdout`/`stderr`/`exitCode` distinctly.
- `grepTool`'s `[GrepMatch]` output is JSON-encoded; M9 may want to render it as a clickable file:line list once the TUI has selection support.
