# M10 — CLI commands — Design

**Status:** Design approved 2026-06-04 (brainstorming). Branch: `main`.
**Scope source:** Expands `MILESTONES.md` §M10 with the decisions resolved during brainstorming.

## Goal

Replace the temporary "no args → TUI, anything else → a stub message" entry point
with a real `optparse-applicative` driver exposing four subcommands:

- **`run`** — interactive TUI (default) or headless single-prompt.
- **`list`** — tabular listing of stored sessions.
- **`export <id>`** — dump one session as Markdown to stdout.
- **`config check`** — verify each configured provider's key actually works.

## Current state (verified against code)

- `optparse-applicative >= 0.18` is **already** a dependency (`package.yaml`).
- `OpenCode.Run.runApp :: ToolRegistry -> IO ()` is a stub: `[] → launchTUI`,
  any other args → `putStrLn "...CLI commands arrive in M10..."`.
- `launchTUI` already does the full env build: `loadConfig` → `DB.openDb` →
  `newBChan` → `newTVarIO False` → `AppEnv{..}` → `createSession` → `startTUI`.
- DB query layer is complete: `listSessions :: Connection -> IO [Session]`,
  `getSession :: Connection -> SessionId -> IO (Maybe Session)`,
  `getMessages :: Connection -> SessionId -> IO [Message]`, `defaultDbPath`.
- Session entry points exist: `createSession :: ModelId -> AppM Session`,
  `loadSession :: SessionId -> AppM (Maybe Session)`,
  `processUserMessage :: SessionId -> Text -> AppM ()`, `processUserMessageWith`.
- `runAppM :: AppEnv -> AppM a -> IO (Either AppError a)`;
  `displayAppError :: AppError -> Text`.
- `Config` carries `defaultModel :: ModelId` and
  `providers :: ProviderConfig { openaiKey, anthropicKey, minimaxKey :: Maybe ApiKey }`.
- Provider dispatch currently lives **inline** in `Session` as `selectStreamer ::
  Config -> Either AppError Streamer` (picks by the default model's provider).
  `streamOpenAI`, `defaultOpenAI`, `minimaxOpenAI` are exported from
  `OpenCode.LLM.OpenAI`.
- Session events flow over `envEventChan :: BChan SessionEvent`; the agentic loop
  reliably emits `RunStateChanged Idle` at the end of a run.

The single gap is the parser + the four command runners. No persistence, session,
or streaming code needs to change — M10 is wiring over existing primitives.

## Decisions resolved in brainstorming

1. **Architecture: library module + pure renderers (chosen option ①).** A new
   library module `OpenCode.CLI` holds the parser and the *pure* rendering cores;
   `OpenCode.Run` keeps all IO orchestration. The milestone's own unit tests
   (`parseModelId`, list/export rendering) require the code on the **library**
   path — the test suite depends on the library, not the executable — so the
   pure cores cannot live in `app/Main.hs` as the milestone text literally says.
   *Rejected:* everything in `app/Main.hs` (untestable); one module doing parsing
   **and** orchestration (muddies pure/IO boundary, duplicates env-building).
2. **Headless `--no-tui` streams to stdout.** The runner consumes `envEventChan`
   and prints `PartialText` deltas to stdout as they arrive (tool activity to
   stderr), terminating on `RunStateChanged Idle`. Naturally yields the complete
   response while preserving the project's streaming character.
3. **`config check` makes a real probe.** For each *configured* provider it issues
   a minimal `max_tokens` request and inspects the first stream event: a
   `StreamError` → FAIL (with snippet); any other first event → OK. This is the
   command's whole value — it would have caught the `2013` tool/key 400s. A
   configured-but-unimplemented Anthropic key reports `FAIL: not implemented
   until M11` without a network call.
4. **Single provider-dispatch point.** Refactor `selectStreamer` into an exported
   `streamerForProvider :: Config -> ProviderId -> Either AppError Streamer`
   (`selectStreamer cfg = streamerForProvider cfg (provider (defaultModel cfg))`),
   so the agentic loop, headless run, and `config check` share one source of
   truth and `config check` can probe a provider other than the default.
5. **Bare invocation preserves today's behavior.** No subcommand → `run` with
   defaults → interactive TUI on a fresh session. `--help` comes from optparse
   for free; a real `--version` flag stays deferred to M12.
6. **`--prompt` is meaningful only with `--no-tui`.** Headless mode requires
   `--prompt` (error if absent). In TUI mode `--prompt` is ignored (pre-filling
   the editor is out of scope).

## Components / changes

### 1. `OpenCode.CLI` (new library module)

Pure parsing + rendering. No IO beyond optparse's own.

```haskell
data Command
  = Run RunOpts
  | List
  | Export SessionId
  | ConfigCheck

data RunOpts = RunOpts
  { roSession :: Maybe SessionId   -- --session
  , roModel   :: Maybe ModelId     -- --model openai:gpt-4o
  , roPrompt  :: Maybe Text        -- --prompt TEXT
  , roNoTui   :: Bool              -- --no-tui
  }

parseModelId      :: Text -> Either Text ModelId
commandParserInfo :: ParserInfo Command            -- top-level, with prog desc
renderSessionList :: [Session] -> Text             -- pure
renderExportMarkdown :: Session -> [Message] -> Text  -- pure
```

- `parseModelId` splits on the first `:`; maps `openai`/`anthropic`/`minimax`
  (case-sensitive, matching the JSON encoding) to `ProviderId`; non-empty model
  required. `Left` on unknown provider, missing colon, or empty model. Anthropic
  parses fine (it just fails at run time until M11).
- `commandParserInfo`: `subparser` for `run`/`list`/`export`/`config check`
  combined with `<|> pure (Run defaultRunOpts)` so no subcommand → TUI defaults.
  `--model` uses a `ReadM ModelId` built from `parseModelId`.
- `renderSessionList`: header `ID  TITLE  MODEL  CREATED`, one row per session,
  columns padded to their max width; model shown as `provider:model`; created via
  `formatTime` `"%Y-%m-%d %H:%M"`. Full IDs (export needs them). Empty list → a
  single `"(no sessions)"` line.
- `renderExportMarkdown`: `# <title>`, a metadata list (**ID/Model/Created**),
  then per message a `## User` / `## Assistant` / `## Tool` section. Within a
  message, parts render in order: `TextPart` as prose; `ToolCallPart` as a fenced
  block ```` ```<toolName> ```` containing the arguments JSON; `ToolResultPart` as
  a fenced ```` ```result ```` block; `ErrorPart` as a `> ⚠ <error>` blockquote.

### 2. `OpenCode.Run` (orchestration)

- Extract `withAppEnv :: ToolRegistry -> (Config -> AppEnv -> IO a) -> IO a`
  from the head of `launchTUI` (config load + DB open + chan + abort + `AppEnv`).
  On config error it prints `displayAppError`/`show` and exits non-zero. Every
  command runs inside it, so DB/env construction lives in exactly one place.
- `runApp registry = execParser commandParserInfo >>= dispatch registry`
  (replaces the `getArgs` stub). Every branch runs inside `withAppEnv registry`,
  so DB/env construction happens in exactly one place:
  - `Run ro`      → `withAppEnv registry (\cfg env -> runRun cfg env ro)`
  - `List`        → `withAppEnv registry (\_   env -> runList env)`
  - `Export i`    → `withAppEnv registry (\_   env -> runExport i env)`
  - `ConfigCheck` → `withAppEnv registry (\cfg env -> runConfigCheck cfg env)`
- `runRun :: Config -> AppEnv -> RunOpts -> IO ()`: resolve the session
  (`--session` → `loadSession`, else
  `createSession` with `--model` or `defaultModel cfg`). If `roNoTui`, require
  `--prompt` and call `runHeadless`; otherwise `startTUI`.
- `runHeadless env sid prompt`: `async (runAppM env (processUserMessage sid
  prompt))`, then read `envEventChan` in a loop — `PartialText t` → `hPutStr
  stdout`, `ToolStarted n` → `hPutStrLn stderr ("⚙ "<>n)`, `ErrorOccurred e` →
  `hPutStrLn stderr e`, `RunStateChanged Idle` → stop; `wait` the async, map a
  `Left AppError` to `displayAppError` on stderr + `exitFailure`; emit a trailing
  newline. (`OPENCODE_MOCK` continues to work since `processUserMessage` already
  branches on it internally.)
- `runList env` = `listSessions (envDb env) >>= putStr . unpack . renderSessionList`.
- `runExport i env` = `getSession`+`getMessages`; `Nothing` → stderr error +
  `exitFailure`; else `putStr . unpack $ renderExportMarkdown session msgs`.
- `runConfigCheck cfg env`: for each provider in `[OpenAI, MiniMax, Anthropic]`,
  report `not configured` (no key), else probe via `streamerForProvider`: build a
  minimal `LLMRequest` (one user `"ping"`, `reqMaxTokens = Just 1`, no tools),
  `runResourceT` the streamer, take the first event — `StreamError e` → `FAIL`
  with snippet, anything else → `OK`. Anthropic-with-key short-circuits to
  `FAIL: not implemented until M11`. Print one line per provider.

### 3. `OpenCode.Session`

Rename/export `streamerForProvider :: Config -> ProviderId -> Either AppError
Streamer`; redefine the existing `selectStreamer` in terms of it. No behavior
change for the agentic loop.

### 4. `package.yaml`

Add `OpenCode.CLI` to `exposed-modules`. `app/Main.hs` is unchanged
(`main = runApp defaultBuiltinRegistry`).

## Testing (TDD)

Pure cores are the unit-test surface; IO runners are covered by the shell
acceptance commands.

- **`parseModelId`**: `"openai:gpt-4o"` → `Right (ModelId OpenAI "gpt-4o")`;
  `"minimax:MiniMax-M3"` → `Right (ModelId MiniMax …)`; `"anthropic:x"` →
  `Right …`; `"garbage"`, `"openai:"`, `":gpt"`, `"weird:m"` → `Left`.
- **`renderSessionList`**: two seeded sessions → output contains both ids,
  titles, and `provider:model`s, one row each; empty → `"(no sessions)"`.
- **`renderExportMarkdown`**: a fixture session (user msg + assistant msg with a
  `ToolCallPart`+`ToolResultPart`) → expected Markdown with the metadata block,
  role headings in order, a fenced tool block, and a fenced result block.
- **`commandParserInfo`** (via `execParserPure`): `["list"]` → `List`;
  `["export","abc"]` → `Export (SessionId "abc")`; `[]` → `Run` with defaults;
  `["run","--no-tui","--prompt","hi","--model","openai:gpt-4o"]` → populated
  `RunOpts`; a bad `--model` value fails to parse.

## Acceptance

- `stack test --match "OpenCode.CLI"` passes.
- `stack run -- list` shows existing sessions (tabular).
- `stack run -- run --prompt "hello" --no-tui` (with a provider key set) streams a
  complete response to stdout and persists the session; `stack run -- list` then
  shows the new row.
- `stack run -- export <id>` produces valid Markdown; unknown id exits non-zero
  with a stderr message.
- `stack run -- config check` prints one line per provider (OK / FAIL / not
  configured); a configured Anthropic key reports the M11 deferral.
- Bare `stack run` still opens the TUI on a fresh session.

## Out of scope (deferred to M12)

`--version` flag, SIGINT handling, session-title auto-generation,
context-window summarization. Anthropic connectivity in `config check` is
reported as deferred (the provider itself lands in M11).
