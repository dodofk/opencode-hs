# opencode-hs — Milestone Plan

Each milestone is self-contained, testable, and merges as a PR.
Milestones build on each other but the first three can be developed in parallel.

---

## M0 — Project Scaffold (1–2 days)

**Goal**: Buildable Haskell project with CI, zero functionality.

### Tasks
- [ ] Initialize `stack.yaml` targeting LTS-22.x (GHC 9.6)
- [ ] Write `package.yaml` (hpack) with all dependency bounds
- [ ] Create `app/Main.hs` with stub `main :: IO ()`
- [ ] Create module skeletons (empty `module X where`) for all planned modules
- [ ] `stack build` passes with zero warnings (`-Wall -Werror`)
- [ ] Set up `stack test` with `hspec` runner
- [ ] Add `.gitignore` for `.stack-work`, `dist-newstyle`
- [ ] Add `Makefile` with `build`, `test`, `run`, `lint` targets
- [ ] Install GHCup + Stack if not present (document in README)

### Acceptance
`stack build && stack test` exits 0.

---

## M1 — Core Types + Config (2–3 days)

**Goal**: Define all ADTs and load config from YAML.

### Tasks
- [ ] Implement `OpenCode.Types` with all ADTs from spec §3.2
  - `Session`, `Message`, `MessagePart`, `Role`, `StreamEvent`, `Usage`
  - `ModelId`, `ProviderId`, `ToolCall`, `ToolResult`
  - Derive `Show`, `Eq`, `Generic`, `ToJSON`, `FromJSON` for all
  - Newtype wrappers: `SessionId`, `MessageId`, `ApiKey`
- [ ] Implement `OpenCode.Config`
  - `Config` record + `ProviderConfig`
  - `loadConfig :: IO (Either ConfigError Config)`
  - Parse `~/.config/opencode-hs/config.yaml`
  - Fall back to env vars `OPENAI_API_KEY`, `ANTHROPIC_API_KEY`
  - Error if no API key for requested provider
- [ ] Implement `OpenCode.App`
  - `AppEnv`, `AppError`, `AppM` type alias
  - `runAppM :: AppEnv -> AppM a -> IO (Either AppError a)`
  - `liftIO'` helper that wraps IO exceptions into `AppError`
- [ ] Unit tests for config parsing (valid YAML, missing keys, env override)

### Acceptance
All types compile; config test loads a fixture YAML and returns correct `Config`.

---

## M2 — SQLite Persistence (2–3 days)

**Goal**: Read/write sessions and messages to SQLite.

### Tasks
- [ ] Implement `OpenCode.DB`
  - `openDb :: FilePath -> IO Connection`
  - `createSchema :: Connection -> IO ()` — idempotent migrations
  - `insertSession`, `getSession`, `listSessions`
  - `insertMessage`, `getMessages :: Connection -> SessionId -> IO [Message]`
  - Store `parts` as JSON text using `aeson`
  - Generate `SessionId` / `MessageId` as UUIDs
- [ ] DB path resolution: `~/.local/share/opencode-hs/sessions.db`
- [ ] Schema migrations table to track applied migrations
- [ ] Unit tests: insert session → retrieve it; insert messages → retrieve in order

### Acceptance
Round-trip test: `insertMessage` then `getMessages` returns identical `Message`.

---

## M3 — LLM Streaming Client (5–7 days)

**Goal**: Stream completions from OpenAI and Anthropic.

### Tasks

#### M3a — Shared infrastructure
- [ ] `OpenCode.LLM.Types`: `ToolDefinition`, `LLMRequest`, `LLMConfig`
- [ ] SSE line parser: `parseSSELine :: ByteString -> Maybe ByteString` (extracts `data: ...` payload)
- [ ] `ConduitT ByteString StreamEvent IO ()` base conduit

#### M3b — OpenAI provider
- [ ] `OpenCode.LLM.OpenAI`
  - Build `POST /v1/chat/completions` with `stream: true`
  - Parse `ChatCompletionChunk` SSE events
  - Extract `delta.content` → `TextDelta`
  - Extract `delta.tool_calls` → `ToolCallStart`, `ToolCallArgDelta`, `ToolCallEnd`
  - Parse final `[DONE]` sentinel → `StreamDone`
  - Handle HTTP 401/429/500 → `StreamError`
  - `streamOpenAI :: OpenAIProvider -> LLMRequest -> ConduitT () StreamEvent IO ()`

#### M3c — Anthropic provider
- [ ] `OpenCode.LLM.Anthropic`
  - Build `POST /v1/messages` with `stream: true`
  - Parse Anthropic SSE events: `content_block_start`, `content_block_delta`, `content_block_stop`
  - `input_json_delta` fragments → accumulate in `TVar (Map Text Text)` → emit on stop
  - `message_delta` with `stop_reason` → `StreamDone`
  - `OpenCode.LLM.Anthropic.toMessages` — convert `[Message]` to Anthropic API format
  - Add `cache_control: {"type": "ephemeral"}` for system prompt (prompt caching)

#### M3d — Tool definition serialization
- [ ] `toolToOpenAISchema :: SomeTool -> Aeson.Value` — JSON Schema for OpenAI
- [ ] `toolToAnthropicSchema :: SomeTool -> Aeson.Value` — JSON Schema for Anthropic
- [ ] Derive schemas from `ToolDef` type parameters using `aeson-schemas` or manual instances

### Testing
- [ ] Mock HTTP server (or fixture JSON files) for SSE parsing tests
- [ ] Test: multi-chunk text reassembly
- [ ] Test: tool call with fragmented JSON arguments

### Acceptance
`stack test` passes all LLM streaming tests against recorded fixtures.

---

## M4 — Tool System (4–5 days)

**Goal**: All 6 built-in tools implemented and tested.

### Tasks
- [ ] `OpenCode.Tool.Types`
  - GADT `ToolDef i o`
  - `SomeTool` existential
  - `ToolRegistry` (Map Text SomeTool)
  - `executeTool :: ToolRegistry -> Text -> Aeson.Value -> AppM Text`
  - JSON Schema generation per tool
- [ ] `OpenCode.Tool.ReadFile`
  - Read file, optional `offset`/`limit` lines
  - Detect binary files (refuse gracefully)
  - Cap output at 100KB
- [ ] `OpenCode.Tool.WriteFile`
  - Create parent directories
  - Atomic write via temp file + rename
  - Return summary: "wrote N bytes"
- [ ] `OpenCode.Tool.EditFile`
  - Find unique `oldString` in file
  - Replace with `newString`
  - Return unified diff (via `Diff` package or manual)
  - Error if `oldString` not found or ambiguous
- [ ] `OpenCode.Tool.Bash`
  - `System.Process.createProcess` with stdin closed
  - 30-second timeout via `System.Timeout.timeout`
  - Capture stdout + stderr
  - Return exit code + output
  - Sanitize working directory
- [ ] `OpenCode.Tool.Glob`
  - Use `Glob` package for pattern matching
  - Respect `.gitignore` if present
  - Return sorted list capped at 500 entries
- [ ] `OpenCode.Tool.Grep`
  - Try `ripgrep` subprocess first
  - Fall back to `Data.Text` line-by-line search
  - Return matches with file + line number

### Testing
- [ ] Each tool has unit tests using temp directories (`Tmp.withTempDir`)
- [ ] Bash: timeout test, exit-code capture
- [ ] EditFile: ambiguous match returns `Left`

### Acceptance
All tool tests pass; `executeTool registry "bash" '{"command":"echo hi"}'` returns `"hi\n"`.

---

## M5 — Session Loop (4–5 days)

**Goal**: Agentic conversation loop that drives LLM + tool calls.

### Tasks
- [ ] `OpenCode.Session`
  - `createSession :: ModelId -> AppM Session`
  - `loadSession :: SessionId -> AppM Session`
  - `processUserMessage :: SessionId -> Text -> AppM ()`
  - `agentic :: [Message] -> AppM [Message]` — LLM + tool round loop
    - Stream events → accumulate `MessagePart`s
    - On `ToolCallEnd`: decode args, call `executeTool`, append result
    - Recurse if tool calls occurred (max 10 rounds)
    - On `StreamDone`: persist assistant message, return
  - `abortSession :: SessionId -> AppM ()` — set abort `TVar`, drain conduit
- [ ] STM `TVar RunState` for current state
- [ ] `BChan SessionEvent` for TUI updates
  - Emit `PartialText`, `ToolStarted`, `ToolFinished`, `RunStateChanged`, `MessageAppended`
- [ ] Context window management: if total tokens > 80% of model limit, summarize oldest messages (call LLM to summarize, replace with `TextPart "[Summary: ...]"`)
- [ ] System prompt builder: static agent instructions + available tool descriptions

### Testing
- [ ] Integration test with mock LLM conduit: fake stream that emits a tool call → verify tool executed and second round started
- [ ] Abort test: set abort TVar mid-stream → verify loop exits cleanly

### Acceptance
`processUserMessage` drives a full round-trip (user → LLM → tool → LLM → result) in tests.

---

## M6 — MCP Client (2–3 days)

**Goal**: Connect to MCP servers and merge their tools into the registry.

### Tasks
- [ ] `OpenCode.MCP`
  - `McpClient` record type
  - `connectMcpStdio :: FilePath -> [Text] -> IO McpClient`
    - Spawn subprocess, wire stdin/stdout to `mcp-server` transport
    - Call `initialize`, `tools/list`
  - `mcpToolToSomeTool :: McpToolDefinition -> SomeTool`
    - Wrap MCP `callTool` response as a `SomeTool` with passthrough executor
  - `loadMcpTools :: Config -> IO [SomeTool]`
- [ ] Config extension: `mcpServers :: [McpServerConfig]` in `config.yaml`
  - `McpServerConfig { command :: Text, args :: [Text], env :: Map Text Text }`
- [ ] Graceful degradation: if MCP server fails to start, log warning and continue

### Testing
- [ ] Test with a simple stdio MCP echo server (write a minimal one in `test/`)
- [ ] Test tool round-trip: list → call → result

### Acceptance
MCP tools appear in registry; calling them proxies to the subprocess.

---

## M7 — TUI (5–7 days)

**Goal**: Full `brick`-based terminal UI replacing the plain REPL.

### Tasks
- [ ] `OpenCode.TUI.Types`: `AppState`, `ResourceName`, `SessionEvent`
- [ ] `OpenCode.TUI.Render`
  - `drawUI :: AppState -> [Widget ResourceName]`
  - Chat viewport: render each message with role label + formatted content
  - Inline tool call rendering: `⚙ bash: echo hi` / `> output`
  - Streaming text: live-update the last assistant message
  - Status bar: model name, run state, token count
  - Input editor: single-line with prompt character
- [ ] `OpenCode.TUI.App`
  - `app :: App AppState SessionEvent ResourceName`
  - `handleEvent :: BrickEvent ResourceName SessionEvent -> EventM ResourceName AppState ()`
    - `Enter` → `processUserMessage` in background `async`
    - `Esc` → set abort TVar
    - `PgUp/PgDn` → `viewportScroll`
    - `Ctrl+C` → `halt`
  - `startTUI :: AppEnv -> Session -> IO ()`
    - Fork session loop thread
    - Run `customMain` with `BChan`

### UI Details
- User messages: bold prefix `> `, left-aligned
- Assistant messages: plain, with word wrap
- Tool calls: dim cyan `⚙ toolname(args...)` + indented output block
- Errors: red text
- Status bar: `[model] [Idle|Running|Tool: bash] [↑↓ scroll] [Ctrl+C quit]`

### Testing
- [ ] Smoke test: `drawUI` with a fixture `AppState` doesn't crash (property test with `QuickCheck`)
- [ ] Event test: `Enter` on non-empty input emits correct `processUserMessage` call
- Manual interactive testing

### Acceptance
`stack run -- run` opens the TUI; user can type a prompt, see streaming response, see tool execution inline.

---

## M8 — CLI Commands + Polish (3–4 days)

**Goal**: Complete CLI with all subcommands; release-ready.

### Tasks
- [ ] `app/Main.hs` — full `optparse-applicative` CLI
  - `run [--session ID] [--model MODEL]` — start/resume interactive TUI session
  - `run --prompt TEXT [--no-tui]` — non-interactive single prompt
  - `list` — print table of recent sessions
  - `export SESSION_ID` — dump session as Markdown to stdout
  - `config check` — validate config + test API connectivity
- [ ] Session title auto-generation: call LLM with first message, generate 5-word title
- [ ] `--model` flag: `openai:gpt-4o`, `anthropic:claude-opus-4-7`
- [ ] `~/.config/opencode-hs/config.yaml` documented template written on first run
- [ ] Graceful shutdown: `installHandler sigINT` → set abort TVar → wait for in-flight calls
- [ ] `README.md` with installation, quickstart, config reference
- [ ] Version string from cabal metadata: `--version` flag

### Acceptance
`stack run -- list` shows sessions; `stack run -- run --prompt "hello"` returns AI response non-interactively.

---

## M9 — Testing + Hardening (3–4 days)

**Goal**: Comprehensive test suite; no known crashes.

### Tasks
- [ ] `hspec` test suite covering all modules
- [ ] Property tests with `QuickCheck`:
  - SSE line parser: round-trip
  - Tool registry: any valid `Aeson.Value` input either parses or returns typed error
  - Message serialization: `decode . encode = id` for all `MessagePart` constructors
- [ ] Integration tests (with `IORef` mock LLM):
  - Full session: user message → tool call → final response → persisted to DB
  - Abort mid-stream: no partial messages left in DB
- [ ] Error scenario tests:
  - Bad API key → `AuthError` displayed in TUI
  - Tool timeout → `ToolResultPart { isError = True }`
  - DB locked → graceful error, not crash
- [ ] `hlint` clean
- [ ] No `undefined`, `error`, or `head`/`tail` on lists outside Safe module

### Acceptance
`stack test` passes all tests; `stack build -Wall -Werror` clean.

---

## Dependency Notes

### `stack.yaml` resolver
```yaml
resolver: lts-22.39  # GHC 9.6.6
extra-deps:
  - mcp-server-0.1.0.19
```

### Key package versions to pin
- `brick >= 2.3`
- `http-conduit >= 2.3.8`
- `sqlite-simple >= 0.4.18`
- `aeson >= 2.2`
- `conduit >= 1.3.5`

---

## Milestone Timeline (rough)

| Milestone | Days | Cumulative |
|-----------|------|------------|
| M0 Scaffold | 2 | 2 |
| M1 Types + Config | 3 | 5 |
| M2 DB | 3 | 8 |
| M3 LLM Streaming | 7 | 15 |
| M4 Tools | 5 | 20 |
| M5 Session Loop | 5 | 25 |
| M6 MCP | 3 | 28 |
| M7 TUI | 7 | 35 |
| M8 CLI Polish | 4 | 39 |
| M9 Testing | 4 | 43 |

Estimated total: **~6–8 weeks** of side-project effort at 1–2 hours/day.

---

## Parallel Work Opportunities

M1, M2, and M4 (partial) can all be developed independently once M0 is done.
M3 and M4 can proceed in parallel once M1 types are locked.
M5 requires M3 + M4. M7 requires M5. M8 requires M7.
