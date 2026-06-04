# opencode-hs — Milestone Plan

Each milestone is self-contained, testable, and merges as a single PR.
Milestones are sequenced; no parallelism is assumed for solo development.
Acceptance for each is one or more concrete shell commands plus expected outcome — not narrative.

## Status snapshot (as of 2026-06-04)

| #   | Title                                  | Status    | Commit / PR        |
| --- | -------------------------------------- | --------- | ------------------ |
| M0  | Project Scaffold                       | done      | `1591f0c`, `d5c9228` |
| M1  | Core Types + Config + AppEnv           | done      | `cd81bdb`          |
| M2  | SQLite Persistence                     | done      | `fb9c8a9..`        |
| M3  | CI                                     | done      | `8215987..`        |
| M4  | LLM Streaming — OpenAI only            | done      | `1d0277a..`        |
| M5  | Tool System: file I/O                  | done      | `5b9ddc9..`        |
| M6  | Session Loop                           | done      | `4d0d2ba..`        |
| M7  | Tool System: execution + search        | done      | `1e0425d..`        |
| M8  | TUI: static layout                     | done      | `4e2aeab..`        |
| M9  | TUI: streaming + tool inline + abort   | done      | `100700b..`        |
| M10 | CLI commands                           | done      | `51f9e0a..`        |
| M11 | Anthropic provider                     | done      | `3576aa3..`        |
| M12 | Hardening                              | pending   | —                  |

MCP support is **dropped from v1** and will be revisited post-v1. The original M3 was split: OpenAI ships first as M4, Anthropic deferred to M11. The original M4 (tools) and M7 (TUI) were each split into two milestones. Context-window summarization, auto-title, SIGINT handling, `--version`, and README polish were deferred from earlier milestones into M12.

**MiniMax** was added during M9 (`6312b63`) as a third provider served over the OpenAI-compatible endpoint — it reuses the M4 streaming layer and is configured from `MINIMAX_API_KEY`, so it gets no separate milestone number. Anthropic remains planned for M11 as the natively-supported (non-OpenAI-compatible) provider.

---

## M0 — Project Scaffold — DONE

Shipped: commits `1591f0c`, `d5c9228`.

Outcome: buildable `stack` project with hpack, hspec test runner, module skeletons for everything in the spec, `.gitignore`, Makefile.

---

## M1 — Core Types + Config + AppEnv — DONE

Shipped: commit `cd81bdb`.

Outcome: all ADTs from SPEC §3.2 in `OpenCode.Types`; YAML config loader with env-var override in `OpenCode.Config`; `AppM` / `AppEnv` / `AppError` skeleton in `OpenCode.App`. 36 hspec tests covering type round-trips and config-parsing matrix.

---

## M2 — SQLite Persistence

**Goal**: Round-trip sessions and messages through SQLite.

### Tasks

- Implement `OpenCode.DB`:
  - `openDb :: FilePath -> IO Connection` — opens the database, creates parent directory if missing, runs `createSchema` once on open.
  - `createSchema :: Connection -> IO ()` — idempotent; tracks applied migrations in a `migrations(version INTEGER PRIMARY KEY, applied_at TEXT)` table; defines `sessions` and `messages` tables per SPEC §3.6.
  - `insertSession :: Connection -> Session -> IO ()`
  - `getSession :: Connection -> SessionId -> IO (Maybe Session)`
  - `listSessions :: Connection -> IO [Session]` — ordered by `created_at DESC`.
  - `insertMessage :: Connection -> SessionId -> Message -> IO ()`
  - `getMessages :: Connection -> SessionId -> IO [Message]` — ordered by `created_at ASC`, then `id` as tiebreak.
  - Store `Message.msgParts` as JSON text via `aeson`.
  - Use `Data.UUID.V4.nextRandom` for new `SessionId` / `MessageId`; ids are caller-supplied in tests for determinism.
- `defaultDbPath :: IO FilePath` — returns the XDG data path `<XdgData>/opencode-hs/sessions.db`.
- Extend `AppEnv` with `envDb :: Connection`.
- Unit tests using `:memory:` or a temp-file SQLite connection:
  - `createSchema` is idempotent (calling twice does not error).
  - `insertSession s; getSession (sessionId s) == Just s` for arbitrary `Session`.
  - `insertMessage`s in order → `getMessages` returns them in the same order.
  - Round-trip for every `MessagePart` constructor (`TextPart`, `ToolCallPart`, `ToolResultPart`, `ErrorPart`).

### Acceptance

- `stack test --match "OpenCode.DB"` passes.
- Property test: for at least 100 generated `Message` values, `insertMessage m; getMessages` includes the original `m` byte-for-byte.
- `sqlite3 /tmp/test.db ".schema"` after `openDb` shows tables `migrations`, `sessions`, `messages` with the columns specified in SPEC §3.6.

---

## M3 — CI

**Goal**: Every push to GitHub runs build + test + hlint. Eliminates the gap where M0 promised CI but no workflow exists.

### Tasks

- Add `.github/workflows/ci.yml`:
  - Triggers: `push` to any branch and `pull_request` targeting `main`.
  - Matrix: `os: [ubuntu-latest, macos-latest]`, `ghc: ['9.6.6']`.
  - Steps: checkout → install GHCup → cache `~/.stack` and `.stack-work` keyed on `stack.yaml.lock` + `package.yaml` → `stack build --no-run-tests` → `stack test` → `hlint src app test`.
- Pin an `hlint` version (either via `stack install hlint` cached, or a separate setup action).
- Add a CI status badge to `README.md`.

### Acceptance

- Open a no-op PR; the workflow runs and goes green on both ubuntu and macos.
- A PR that introduces an `hlint` warning fails the `hlint` step.
- A PR that introduces a failing test fails the `stack test` step.

---

## M4 — LLM Streaming, OpenAI only

**Goal**: Given a list of messages and tool definitions, stream completions from OpenAI as a `ConduitT () StreamEvent (ResourceT IO) ()`. Anthropic is out of scope for this milestone (see M11).

### Tasks

- `OpenCode.LLM.Types`:
  - `data ToolDefinition = ToolDefinition { tdName :: Text, tdDescription :: Text, tdInputSchema :: Aeson.Value }`.
  - `data LLMRequest = LLMRequest { lrModel :: Text, lrMessages :: [Message], lrTools :: [ToolDefinition], lrSystem :: Maybe Text, lrMaxTokens :: Maybe Int }`.
- `OpenCode.LLM.Request`:
  - `parseSSELine :: ByteString -> Maybe ByteString` — extracts the `data: ...` payload; returns `Nothing` for comment lines, `event:` lines, and blanks.
  - Conduit helper that chunks an SSE-encoded response body into one `ByteString` payload per `data:` line.
- `OpenCode.LLM.OpenAI`:
  - `data OpenAIProvider = OpenAIProvider { apiKey :: ApiKey, baseUrl :: Text }`; default `baseUrl = "https://api.openai.com"`.
  - `streamOpenAI :: OpenAIProvider -> LLMRequest -> ConduitT () StreamEvent (ResourceT IO) ()`.
  - Build `POST /v1/chat/completions` body with `stream: true`. Convert `[Message]` to OpenAI's chat format.
  - SSE chunk parser decodes each payload as a `ChatCompletionChunk` JSON object and emits:
    - `delta.content` → `TextDelta`
    - first-seen `delta.tool_calls[i].id` → `ToolCallStart id name`
    - subsequent `delta.tool_calls[i].function.arguments` fragments → `ToolCallArgDelta id frag`
    - non-null `finish_reason` → `ToolCallEnd id` for each unfinished call, then `StreamDone usage`
    - `[DONE]` sentinel → end the stream (no event)
  - On HTTP 4xx / 5xx, drain the body and emit `StreamError "openai: <status> <body-snippet>"`.
- `OpenCode.LLM.Schema`: `toolToOpenAISchema :: ToolDefinition -> Aeson.Value` — wraps the input JSON Schema in OpenAI's tool envelope (`type: "function"`, `function: { name, description, parameters }`).
- `OpenCode.LLM.Mock` (test helper): `mockStreamCompletion :: [StreamEvent] -> ConduitT () StreamEvent (ResourceT IO) ()` — emits a scripted event list. Used by M6.

### Tests

- `parseSSELine` round-trip on hand-crafted fixtures: comment line, `data:` line, blank line, multi-line payload concatenation.
- `streamOpenAI` against fixture SSE bodies under `test/fixtures/openai/`:
  - Text-only response across 3 chunks reassembles to the expected string and ends with `StreamDone` carrying the usage from the last chunk.
  - Tool call with arguments fragmented across 5 chunks → exactly one `ToolCallStart`, the right `ToolCallArgDelta`s in order, one `ToolCallEnd`, one `StreamDone`.
  - 401 response → exactly one `StreamError` whose payload contains `"401"`.

### Acceptance

- `stack test --match "OpenCode.LLM"` passes.
- `stack test --match "parseSSELine"` includes at least one property test (`encode . decode = id` on the payload bytes).

### Notes

- **Reused for MiniMax (added in M9):** MiniMax is OpenAI-compatible, so it rides this same `streamOpenAI` path via `minimaxOpenAI` — only the base URL differs (`https://api.minimax.io`) — configured from `MINIMAX_API_KEY`. No new parser was needed.

---

## M5 — Tool System: file I/O

**Goal**: Type-safe tool registry plus three file-manipulation tools. Execution and search tools come in M7.

### Tasks

- `OpenCode.Tool.Types`:
  - GADT `data ToolDef i o where ReadFileTool :: ToolDef ReadFileInput Text; WriteFileTool :: ToolDef WriteFileInput Text; EditFileTool :: ToolDef EditFileInput Text` (Bash/Glob/Grep constructors added in M7).
  - `data SomeTool = forall i o. (FromJSON i, ToJSON o) => SomeTool { stDef :: ToolDef i o, stRun :: i -> AppM o }`.
  - `newtype ToolRegistry = ToolRegistry { unRegistry :: Map Text SomeTool }`.
  - `registerTool :: SomeTool -> ToolRegistry -> ToolRegistry` (name extracted from `toolName` field of `SomeTool`).
  - `executeTool :: ToolRegistry -> Text -> Aeson.Value -> AppM Text` — looks up by name, decodes arguments, runs the handler, encodes the output as JSON text; raises `ToolError name msg` on unknown tool or decode failure.
  - `toolDefinition :: Text -> SomeTool -> ToolDefinition` — derives the `ToolDefinition` (name, description, input JSON Schema) for the LLM.
- `OpenCode.Tool.ReadFile`:
  - Inputs: `path :: FilePath`, optional `offset :: Maybe Int` (1-based line), `limit :: Maybe Int` (number of lines).
  - Refuse files whose first 8 KB contains a NUL byte (binary detection); error with `"binary file refused"`.
  - Cap returned text at 100 KB; on truncation, suffix `"\n[truncated: N more bytes]"`.
- `OpenCode.Tool.WriteFile`:
  - Inputs: `path :: FilePath`, `content :: Text`.
  - `createDirectoryIfMissing True (takeDirectory path)`.
  - Atomic write: write to `path <> ".tmp"` then `renameFile`.
  - Output text: `"wrote N bytes to <path>"`.
- `OpenCode.Tool.EditFile`:
  - Inputs: `path :: FilePath`, `oldString :: Text`, `newString :: Text`.
  - Read file, count occurrences of `oldString`; error if 0 (`"not found"`) or > 1 (`"ambiguous: N matches"`).
  - Perform the replacement, write atomically.
  - Output text: a unified diff (e.g. via `Data.Algorithm.Diff`).
- Extend `AppEnv` with `envRegistry :: ToolRegistry`; provide `defaultBuiltinRegistry :: ToolRegistry` containing the three tools above.

### Tests

- `executeTool` with an unknown tool name raises `ToolError "<name>" "unknown tool"`.
- `executeTool` with malformed JSON arguments raises `ToolError "<name>" "<aeson msg>"`.
- ReadFile on a 50-line temp file with `offset=10, limit=5` returns exactly lines 10–14.
- ReadFile rejects a file whose contents begin with `"abc\NULdef"`.
- WriteFile creates a missing parent directory; after success, no `.tmp` file remains.
- EditFile: unique match → returns a non-empty unified-diff string and the file content is updated; ambiguous match → `ToolError`; zero matches → `ToolError`.

### Acceptance

- `stack test --match "OpenCode.Tool"` passes.
- `runAppM env $ executeTool reg "write_file" (object ["path" .= "/tmp/x", "content" .= "hi"])` returns `Right "wrote 2 bytes to /tmp/x"` and `/tmp/x` on disk contains exactly `"hi"`.

---

## M6 — Session Loop

**Goal**: An agentic loop that drives LLM streaming and tool execution to a terminal state. OpenAI is hard-wired; provider dispatch arrives in M11.

### Tasks

- `OpenCode.Session`:
  - `createSession :: ModelId -> AppM Session` — generates `SessionId`, default title `"untitled"`, persists via `insertSession`.
  - `loadSession :: SessionId -> AppM (Maybe Session)`.
  - `processUserMessage :: SessionId -> Text -> AppM ()` — builds a user `Message`, persists it, calls `agentic`.
  - `agentic :: SessionId -> [Message] -> AppM [Message]`:
    1. Build an `LLMRequest` (system prompt + history + registered tool definitions).
    2. Run `streamOpenAI`, accumulating `MessagePart`s into a `TVar (Seq MessagePart)`.
    3. On `ToolCallEnd id`: decode arguments, `executeTool`, append a `ToolResultPart`.
    4. Persist the assembled assistant `Message` via `insertMessage`.
    5. If any tool ran AND round count < `maxToolRounds = 10`, recurse with the updated history.
    6. Return the final message list.
  - `abortSession :: AppM ()` — sets `envAbort` `TVar` to `True`; the conduit checks it between events and short-circuits.
- `OpenCode.Session.Prompt`:
  - `systemPrompt :: ToolRegistry -> Text` — static agent instructions plus a per-tool description block.
- `OpenCode.Session.Events`:
  - `data SessionEvent = MessageAppended Message | PartialText Text | ToolStarted Text | ToolFinished Text Text | RunStateChanged RunState | ErrorOccurred Text`.
  - Conduit drains `StreamEvent` and emits `SessionEvent`s into `envEventChan :: BChan SessionEvent`.
- Extend `AppEnv` with `envEventChan :: BChan SessionEvent` and `envAbort :: TVar Bool`.

### Tests (against `OpenCode.LLM.Mock`)

- One-round text test: a scripted text-only stream → the final assistant message has exactly one `TextPart` equal to the concatenated deltas.
- Two-round tool-call test: round 1 emits `ToolCallStart "write_file" ...` + arg deltas + `ToolCallEnd` + `StreamDone`; the loop executes the tool; round 2 emits text only. Final message history: user msg → assistant (round 1 with `ToolCallPart` + `ToolResultPart`) → assistant (round 2 with `TextPart`).
- Abort test: after the first `TextDelta`, set `envAbort = True`; the loop exits with a single partial assistant message and does not start a second round.

### Acceptance

- `stack test --match "OpenCode.Session"` passes.
- End-to-end mock test: `processUserMessage sid "hello"` against a `MockLLM` scripted to call `write_file` results in `getMessages sid` containing user → assistant-with-tool-call-and-result, and the referenced file exists on disk.

---

## M7 — Tool System: execution + search

**Goal**: Add the remaining three built-in tools (Bash, Glob, Grep) to the registry.

### Tasks

- Extend `ToolDef` GADT with `BashTool :: ToolDef BashInput BashOutput`, `GlobTool :: ToolDef GlobInput [FilePath]`, `GrepTool :: ToolDef GrepInput [GrepMatch]`.
- `OpenCode.Tool.Bash`:
  - Inputs: `command :: Text`, optional `cwd :: Maybe FilePath`.
  - `System.Process.createProcess` with shell command; stdin closed; stdout + stderr captured.
  - `System.Timeout.timeout (30 * 1_000_000) waitForProcess`; on timeout, terminate the process and return `BashOutput { exitCode = -1, stdout = capturedSoFar, stderr = "timeout after 30s" }`.
  - JSON output shape: `{ exitCode :: Int, stdout :: Text, stderr :: Text }`.
- `OpenCode.Tool.Glob`:
  - Inputs: `pattern :: Text`, optional `cwd :: Maybe FilePath`.
  - Use `System.FilePath.Glob`; return matches sorted and capped at 500 entries (suffix `"…truncated"` marker if hit).
  - `.gitignore` handling in v1: simple line-prefix exclude; full gitignore semantics deferred.
- `OpenCode.Tool.Grep`:
  - Inputs: `pattern :: Text`, `path :: FilePath`.
  - Probe `findExecutable "rg"`; if present, run `rg --json pattern path` and parse the JSON match events.
  - Fallback: walk files under `path`, match each line with `Text.isInfixOf`.
  - Output: `[{ file :: FilePath, line :: Int, text :: Text }]` capped at 500 matches.
- Register all three in `defaultBuiltinRegistry`.

### Tests

- Bash:
  - `echo hi` → `stdout = "hi\n"`, `exitCode = 0`.
  - `sleep 60` → `exitCode = -1`, `stderr` contains `"timeout"`.
  - `sh -c 'echo a; echo b >&2; exit 7'` → `stdout = "a\n"`, `stderr = "b\n"`, `exitCode = 7`.
- Glob: a temp tree containing `foo.hs`, `bar.txt`, `sub/baz.hs` with pattern `**/*.hs` returns `["foo.hs", "sub/baz.hs"]` (sorted); `bar.txt` is absent.
- Glob: 600 matching files → returns 500 entries plus a truncated marker.
- Grep: a fixture file containing `"needle"` on line 3 → exactly one result `{file, line = 3, text}`.
- Grep: same fixture with `rg` present and absent returns identical match lists.

### Acceptance

- `stack test --match "OpenCode.Tool"` passes (now covers all 6 tools).
- `runAppM env $ executeTool reg "bash" (object ["command" .= "echo hi"])` returns JSON whose `stdout` field equals `"hi\n"`.

---

## M8 — TUI: static layout — DONE

**Goal**: A `brick`-based UI that can render a fixed message history and accept user input. No live streaming yet — that arrives in M9.

Outcome: `OpenCode.TUI.Types` (`ResourceName`, `AppState`), `OpenCode.TUI.Render` (`drawUI`: chat viewport with role-prefixed messages and inline `⚙ tool(args)` blocks, status bar, bordered input editor), and `OpenCode.TUI.App` (`handleEvent` for Ctrl+C/Enter/PgUp/PgDn/editor keys, `startTUI`). `runApp` now launches the TUI on a fresh session when invoked with no CLI arguments (the registry is threaded in from `app/Main.hs` to avoid an import cycle). New hspec coverage: `drawUI` smoke render over generated histories and an Enter-appends-message property.

### Tasks

- `OpenCode.TUI.Types`:
  - `data ResourceName = ChatViewport | InputEditor | StatusBar`.
  - `data AppState = AppState { asMessages :: Seq Message, asInput :: Editor Text ResourceName, asRunState :: RunState, asStatusText :: Text }`.
- `OpenCode.TUI.Render`:
  - `drawUI :: AppState -> [Widget ResourceName]` lays out: chat viewport (each `Message` rendered with role prefix and each `MessagePart`), status bar (model + run state), input editor.
  - Tool calls render inline as `⚙ <name>(<args>)` followed by an indented output block.
  - Text wraps via `txtWrap`.
  - The viewport reflects `asMessages` only; no streaming hook yet.
- `OpenCode.TUI.App`:
  - `handleEvent`:
    - `Ctrl+C` → `halt`.
    - `Enter` on non-empty input → append a placeholder user `Message`, clear input. (No LLM call wired here — M9.)
    - `PgUp` / `PgDn` → `vScrollBy` the chat viewport.
    - Other keys → forward to the editor.
  - `startTUI :: AppEnv -> Session -> IO ()` constructs initial `AppState` from `getMessages`, then runs `defaultMain app`.
- Wire `runApp` in `OpenCode.App` to call `startTUI` when no CLI arguments are given. This is a temporary entry point until M10 replaces it with the full CLI.

### Tests

- `drawUI` smoke test: an `AppState` built from a QuickCheck-generated short history renders without exception.
- Property: pressing `Enter` on non-empty input increments `Seq.length asMessages` by 1 and clears the editor buffer.

### Acceptance

- `stack run` opens a TUI showing a pre-loaded session; the user can scroll with PgUp / PgDn, type into the input box, see Enter append a placeholder message, and exit with Ctrl+C.

---

## M9 — TUI: streaming + tool inline + abort — DONE

Outcome: `agentic` now consumes the stream with a per-event fold
(`consumeStream`) that emits `PartialText` deltas onto `envEventChan` and
checks `envAbort` after each event; on abort it finalizes a text-only message
via `buildTextOnlyMessage`, skipping any fully-arrived tool call. A new
top-level `OpenCode.Run` module breaks the `App`↔`TUI` import cycle so the TUI
calls `processUserMessage` directly. `AppState` gained
`asPartialText`/`asEnv`/`asSessionId`; a pure `applyEvent` reducer folds each
`SessionEvent`; `handleEvent` forks runs with `startRun` (Enter, Idle only),
aborts on `Esc`, and reduces `AppEvent`s; `startTUI` runs via `customMain` fed
`envEventChan` (no pump thread). The chat viewport renders the in-flight
partial as a dim trailing message and auto-scrolls to follow new output as it
streams (`vScrollToEnd` on each `AppEvent`); ↑/↓ scroll a line and PgUp/PgDn a
page for manual review. `delayedStreamer` + `OPENCODE_MOCK=1` enable
keyless manual testing. Errors always surface as a red line: typed failures via
`displayAppError`, provider `StreamError`s (HTTP 4xx/5xx) and empty/reasoning-only
responses via `ErrorOccurred` from the agentic loop — so a non-response is never
silent.

Real end-to-end testing against MiniMax during this milestone also surfaced and
fixed a latent M6 tool-round serialization bug (`7d277e5`): an assistant
`tool_calls` message must be followed on the wire by matching `role:"tool"`
result messages. The mock streamer never validated history, so only a live
provider caught it.

**Goal**: Layer live streaming, inline tool execution rendering, and mid-stream abort on top of M8's static TUI.

### Tasks

- **`Session.hs` (core change)**: replace `agentic`'s `stream .| Conduit.sinkList` with a fold that, per `StreamEvent`, emits `PartialText δ` onto `envEventChan` (for `TextDelta`s), accumulates the event, and reads `envAbort` — stopping early when set. `buildAssistantMessage` then runs on the accumulated list (a prefix on abort → truncated message). On abort: emit `MessageAppended` (finalize the partial) + `RunStateChanged Idle`, then stop; an empty partial skips persistence. The loop already emits `RunStateChanged`/`MessageAppended`/`ToolStarted`/`ToolFinished`; only `PartialText` + the per-delta abort check are new.
- Extend `AppState` with `asPartialText :: Text` (in-flight buffer), plus `asEnv :: AppEnv` + `asSessionId :: SessionId` (Enter/Esc fork the loop / flip `envAbort`); drop the now-redundant `asEventChan` (reach it via `asEnv`).
- Extract `applyEvent :: SessionEvent -> AppState -> AppState` (pure; exported for testing — mirrors M8's `applyEnter`); `handleEvent`'s `AppEvent SessionEvent` branch delegates to it:
  - `MessageAppended m` → append to `asMessages`, clear `asPartialText`.
  - `PartialText t` → append to `asPartialText`.
  - `ToolStarted n` → `asRunState = RunningTool n`.
  - `ToolFinished _ _` → no-op (the tool's call/result parts arrive in the next `MessageAppended`).
  - `RunStateChanged s` → `asRunState = s`; if `Idle`, also clear `asPartialText`.
  - `ErrorOccurred e` → append a synthetic assistant `Message` with a single `ErrorPart e` (red).
- `handleEvent` for `Esc`: write `True` to `envAbort` `TVar`.
- `handleEvent` for `Enter` (upgraded): only while `asRunState == Idle`; append the user `Message`, then fork an `async` running `processUserMessage[With]` against `asEnv`, catching errors → `ErrorOccurred`. Ignore Enter while a run is active.
- `render` (upgraded): while `asRunState /= Idle` and `asPartialText` is non-empty, render it as a dim synthetic in-flight assistant message at the bottom of the viewport.
- `startTUI` (upgraded): run with `customMain` fed `envEventChan` directly — **no pump thread** (`envEventChan :: BChan SessionEvent` is exactly what `customMain` consumes).
- Mock streamer (testing-only): a naive `Streamer` yielding a canned reply in chunks with `threadDelay` (~10 s total), wired via `processUserMessageWith` when `OPENCODE_MOCK=1`, so streaming + abort can be exercised without API keys.

### Tests

- Mock event drive: feed a fixed `SessionEvent` sequence into `applyEvent` against a fixture `AppState`; assert the final message list and empty `asPartialText`. Mutation-verify each reducer test.
- Abort test: `PartialText "abc"` → `RunStateChanged Idle` → `asPartialText == ""` and `asRunState == Idle`.
- Manual: `OPENCODE_MOCK=1 stack run` — watch the reply stream live; Esc mid-stream keeps the partial as a finalized message.

### Acceptance

- `stack run` (with `OPENAI_API_KEY`) or `OPENCODE_MOCK=1 stack run` opens a TUI; pressing Enter streams the response live; pressing Esc aborts mid-stream and the partial text remains visible as a finalized, persisted message; Ctrl+C exits cleanly.

### Notes

- **Cooperative abort** (not async cancellation): the stream-consuming fold checks `envAbort` per `StreamEvent` and stops pulling; `ResourceT` then closes the HTTP connection.
- **Abort reconciliation**: `applyEvent` clears `asPartialText` on both `MessageAppended` and `RunStateChanged Idle`; the abort path emits `MessageAppended(partial) + RunStateChanged Idle`, so the partial both persists as a message and clears the buffer.

---

## M10 — CLI commands — DONE

Outcome: a new pure `OpenCode.CLI` module holds the `optparse-applicative`
grammar (`run`/`list`/`export`/`config check`), `parseModelId`
(`provider:model` over openai/anthropic/minimax), a testable `parseArgs`, and
the pure renderers `renderSessionList` (fixed-width table) and
`renderExportMarkdown` (session → Markdown). `OpenCode.Run` builds config + DB +
env once via `withAppEnv` and dispatches to
`runRun`/`runList`/`runExport`/`runConfigCheck`; `runHeadless` streams
`PartialText` to stdout under `--no-tui` (draining until the worker completes,
since the agentic loop emits `Idle` between tool rounds), and `config check`
probes each configured provider through the newly-exported
`OpenCode.Session.streamerForProvider`. Bare `stack run` still opens the TUI.
Anthropic parses but reports the M11 deferral; `--version`, SIGINT, and
title auto-generation remain in M12. **Invocation note:** the project ships five
executables, so the CLI is run as `stack run opencode-hs -- <cmd>` (or the
installed `opencode-hs <cmd>`). Verified end-to-end: `--help`, `list`,
`export <id>` and `export <bad-id>` (exit 1), `run --prompt … --no-tui` (mock
stream), and `config check` (live `minimax: OK`).

**Goal**: `optparse-applicative` driver for the documented subcommands.

### Tasks

- `app/Main.hs`:
  - `data Command = Run RunOpts | List | Export SessionId | ConfigCheck`.
  - `Run RunOpts`: flags `--session ID`, `--model openai:gpt-4o`, `--prompt TEXT`, `--no-tui`. Default action: interactive TUI on a new session.
  - `List`: prints a table `id | title | model | created` via `listSessions`.
  - `Export SESSION_ID`: dumps the session as Markdown to stdout (role-prefixed sections; tool calls as fenced code blocks).
  - `ConfigCheck`: loads config, attempts a 1-token completion against each configured provider, prints OK / FAIL per provider.
- `parseModelId :: Text -> Either Text ModelId` accepts `openai:gpt-4o`, `anthropic:claude-opus-4-7`, etc. (Anthropic models only work after M11.)

### Tests

- `parseModelId "openai:gpt-4o"` → `Right (ModelId OpenAI "gpt-4o")`.
- `parseModelId "garbage"` → `Left ...`.
- Against a mock provider in a temp DB: `runWithArgs ["list"]` with two seeded sessions prints both rows.
- Against a fixture session: `runWithArgs ["export", "<id>"]` prints the expected Markdown.

### Acceptance

- `stack run -- list` shows existing sessions.
- `stack run -- run --prompt "hello" --no-tui` (with an `OPENAI_API_KEY` set) prints a complete response to stdout and persists the session.
- `stack run -- export <id>` produces a valid Markdown file.
- `stack run -- config check` reports key presence and provider connectivity.

---

## M11 — Anthropic provider — DONE

Outcome: `OpenCode.LLM.Anthropic` implements the Messages API over SSE — an
`AnthropicEvent` ADT decoded by dispatching on the payload `type`, a
`processAnthropicEvent` accumulator (block-index→callId map + carried input
tokens, clearing a tool block on `content_block_stop`), `interpretAnthropicStream`
reusing `chunkSSELines`/`sseDataLine`, and `streamAnthropic` (`POST /v1/messages`,
`x-api-key` + `anthropic-version`, non-2xx → `StreamError`). Request shaping lives
in `OpenCode.LLM.Schema` (`buildAnthropicRequestBody` with required `max_tokens` +
hoisted `system` + ephemeral cache_control, `messagesToAnthropic` putting tool
results in a user turn with `is_error` on failures and decoding `ToolArgs` to an
object, `toolToAnthropicSchema`). `streamerForProvider`'s `withKey` was
generalized to an `ApiKey -> Streamer` builder so the `Anthropic` arm returns a
real streamer; `config check` probes Anthropic for real; `Config.defaultAnthropicModel`
backs the fallback model and the probe. Verified by fixture-replay tests mirroring
`OpenAISpec` (text reassembly, fragmented tool call, error event) plus Schema unit
tests; a live run needs `ANTHROPIC_API_KEY` (run as `stack run opencode-hs --
run --model anthropic:claude-opus-4-5 --no-tui --prompt …`).

**Goal**: Add the second provider, reusing the M4 streaming infrastructure.

### Tasks

- `OpenCode.LLM.Anthropic`:
  - `data AnthropicProvider = AnthropicProvider { apiKey :: ApiKey, baseUrl :: Text }`; default `baseUrl = "https://api.anthropic.com"`.
  - `streamAnthropic :: AnthropicProvider -> LLMRequest -> ConduitT () StreamEvent (ResourceT IO) ()`.
  - `POST /v1/messages` with `stream: true`. Headers: `anthropic-version: 2023-06-01`, `x-api-key: <key>`.
  - Convert `[Message]` to Anthropic's `messages` format; hoist the system prompt to the top-level `system` field.
  - SSE event parser handles: `message_start`, `content_block_start`, `content_block_delta` (text or `input_json_delta`), `content_block_stop`, `message_delta`, `message_stop`, `ping`, `error`.
  - `input_json_delta` fragments accumulated in `TVar (Map Int Text)` keyed by content-block index → emit `ToolCallArgDelta` per fragment, `ToolCallEnd` on `content_block_stop`.
  - `message_delta.stop_reason` → `StreamDone` with usage extracted from the same payload.
  - Add `cache_control: { type: "ephemeral" }` to the system block (prompt caching).
- `toolToAnthropicSchema :: ToolDefinition -> Aeson.Value` — wraps in `{ name, description, input_schema }`.
- `OpenCode.Session`: dispatch on `sessionModel.provider`; introduce the small abstraction needed to call either `streamOpenAI` or `streamAnthropic`.

### Tests

- Fixture SSE replay under `test/fixtures/anthropic/`:
  - Text-only response: deltas reassemble correctly and end with `StreamDone`.
  - Tool call with fragmented `input_json_delta` across 4 events → exactly one `ToolCallStart`, ordered `ToolCallArgDelta`s, one `ToolCallEnd`, one `StreamDone`.
  - `error` event mid-stream → exactly one `StreamError`.

### Acceptance

- `stack test --match "OpenCode.LLM.Anthropic"` passes.
- `stack run -- run --prompt "hello" --model anthropic:claude-opus-4-7 --no-tui` (with `ANTHROPIC_API_KEY` set) returns a real response.

---

## M12 — Hardening

**Goal**: Project-wide polish plus the items deliberately deferred from earlier milestones.

### Tasks

- **Context-window summarization** (deferred from M6): when total token estimate > 80% of model limit, call the LLM to summarize the oldest N messages and replace them with a single `TextPart "[Summary: …]"`.
- **Session title auto-generation** (deferred from M10): after the first user message in a session, call the LLM with a 5-word-title prompt and update the session row.
- **SIGINT handling** (deferred from M10): `installHandler sigINT` sets `envAbort`; main waits up to 5 s for in-flight work, then exits cleanly.
- **`--version` flag** (deferred from M10): read from cabal's `Paths_opencode_hs.version`.
- **README polish** (deferred from M10): install, quickstart, config reference, supported models, troubleshooting.
- **`hlint` clean** across `src`, `app`, `test`.
- **Partial-functions audit**: replace any `undefined`, `error "..."`, `head`, `tail`, `fromJust`, `read` outside test code with safe alternatives (`headMay`, exhaustive pattern matches, etc.).
- **Error-path integration tests**:
  - Bad API key → `AuthError` surfaces in the TUI as a red error line; session does not crash.
  - Tool timeout → `ToolResultPart { isError = True }` persisted; the next round still runs.
  - DB locked (opened in another process) → graceful `DatabaseError` exit, no crash.
  - Streaming connection drop mid-response → `StreamError` emitted; partial message persisted with an `ErrorPart`.
- **CI tightening**: add `-Wall -Werror` to the CI build flags.
- **Reasoning-content rendering** (surfaced in M9 against MiniMax-M3): extend the OpenAI/MiniMax SSE parser to emit reasoning deltas — `delta.reasoning_content`, plus inline `<think>…</think>` content — as a distinct event, and render them in the TUI as a dim, collapsible "thinking" block instead of discarding them, so a reasoning-only chunk no longer looks like an empty response. (M9 already made the empty case non-silent; this adds the actual rendering.)
- **Run progress visibility** (surfaced in M9): show round/tool progress in the TUI status bar (e.g. `round 2/10 · running bash…`) so a long multi-round tool run reads as in-progress rather than hung.

### Acceptance

- `stack build --ghc-options="-Wall -Werror"` is clean.
- `hlint src app test` exits 0.
- `hlint src app --hint=Use-headDef --hint=Use-readMaybe` (or equivalent rule set covering `head`, `tail`, `read`, `fromJust`, `undefined`, `error`) reports zero warnings outside `test/`.
- All four error-path integration tests pass.
- `stack run -- --version` prints the cabal version.
- A conversation seeded to exceed an artificially-low context limit triggers summarization (verifiable in a test).
- A fresh user can follow the README from install through first prompt successfully.
- A fixture stream carrying `reasoning_content` renders as a dim thinking block in the TUI, not an empty/error line.
- During a scripted multi-round mock run, the status bar reflects the active round number and the running tool.

---

## Dependency notes

- Stack resolver: `lts-22.39` (GHC 9.6.6).
- Key version pins: `brick >= 2.3`, `http-conduit >= 2.3.8`, `sqlite-simple >= 0.4.18`, `aeson >= 2.2`, `conduit >= 1.3.5`.

## Out of scope for v1

- **MCP client** — postponed; the 6 built-in tools cover v1.
- **LSP integration**, **GitHub / web search tools**, **multi-tenant remote sessions**, **plugin / skill system** — per SPEC §1.
