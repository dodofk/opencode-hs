# M12 — Hardening — Design Spec

> Status: approved-by-delegation. The user was away and explicitly delegated all
> design decisions for M12; there was no interactive approval gate. Every
> decision below is recorded so it can be audited after the fact.

**Goal:** Project-wide polish plus the items deliberately deferred from earlier
milestones, taking opencode-hs to a shippable v1.

M12 is a *collection of independent hardening items*, not a single feature. Each
task below is self-contained, independently testable, and committed on its own.
Partial completion is safe: any finished task is a clean, reviewed commit.

---

## Scope

Eleven workstreams, grouped:

**User-facing features**
1. Reasoning-content rendering (parser layer)
2. Reasoning-content rendering (session + TUI)
3. Run-progress visibility in the status bar
4. Session title auto-generation
5. Context-window summarization

**Robustness**
6. Stream-error persistence + graceful DB-error handling
7. Error-path integration tests
8. SIGINT handling

**Polish / hygiene**
9. `--version` flag
10. Partial-functions audit + remove dead code + `-Wall -Werror` + hlint clean
11. README

Execution order interleaves these so shared types settle before consumers, and
so `-Werror` (which turns *any* warning into a build failure) lands near the end
once all code is in place. Recommended order: 9 → 8 → 1 → 2 → 3 → 4 → 5 → 6 → 7
→ 10 → 11.

---

## Key design decisions

### Dead code removal (enables the audit + `-Werror`)

- **`OpenCode.MCP` is removed.** MCP is explicitly out of scope for v1
  (MILESTONES.md "Out of scope"). The module is a single
  `connectMcpStdio _ _ = error "...not yet implemented (M6)"` stub, imported
  nowhere. Delete `src/OpenCode/MCP.hs` and its `exposed-modules` entry.
- **The four `verify/` acceptance executables are removed**
  (`m2-verify-schema`, `m5-acceptance`, `m6-acceptance`, `m7-acceptance`). They
  are one-off manual acceptance harnesses from M2/M5/M6/M7, now fully superseded
  by the hspec suite, and they carry `undefined`/partial code (`envConfig =
  undefined`, etc.) plus `-Wmissing-export-lists` warnings that would fight both
  the audit and `-Werror`. Delete the `verify/` directory and the four
  executable stanzas from `package.yaml`. **Bonus:** with these gone, bare
  `stack run` becomes unambiguous (only the `opencode-hs` executable remains) —
  but the documented `stack run opencode-hs -- <cmd>` form keeps working and the
  docs are left as-is.

### Reasoning content (items 1–2)

- A new stream event **`StreamEvent` constructor `ReasoningDelta Text`** carries
  model "thinking" content.
- Two sources feed it on the OpenAI/MiniMax path:
  1. **`delta.reasoning_content`** — a structured field some providers
     (MiniMax-M3) emit. The `Delta` wire type gains `deltaReasoning :: Maybe
     Text`; `processChunk` emits `ReasoningDelta` for non-empty values.
  2. **Inline `<think>…</think>`** within `delta.content`. A small pure state
     machine splits text deltas into outside-think text (→ `TextDelta`) and
     inside-think text (→ `ReasoningDelta`), tolerating tags that straddle chunk
     boundaries by carrying a short partial-tag buffer. Implemented as a conduit
     stage `splitThink` applied *after* `processChunk` in `interpretOpenAIStream`.
     Anthropic is unaffected (it has native thinking blocks; not in scope here).
- **Reasoning is live-only, never persisted.** `consumeStream` emits a new
  `SessionEvent PartialReasoning Text` for each `ReasoningDelta`, but
  `collectText` (which builds the persisted message) ignores reasoning — so it
  never enters the message history sent back to the model. This is the whole
  point: a reasoning-only chunk shows as a thinking block, not as message text.
- **Empty-response suppression:** the agentic loop currently emits
  `emptyResponseMessage` when a first round yields no text/tool/error. With
  reasoning now visible, suppress that message when the round produced any
  `ReasoningDelta` — the thinking block already showed activity. (Accumulated
  events retain `ReasoningDelta`s so the loop can detect this.)
- **TUI:** `AppState` gains `asPartialReasoning :: Text`. `applyEvent` appends on
  `PartialReasoning` and clears it on `MessageAppended` and `RunStateChanged
  Idle` (same lifecycle as `asPartialText`). The renderer shows it, while a run
  is active and the buffer is non-empty, as a **dim `💭 thinking` block**
  rendered *above* the in-flight partial text. (A collapse/expand toggle is out
  of scope — the block is simply dim.)
- **Headless (`--no-tui`):** `PartialReasoning` is written to **stderr** so
  stdout stays the clean answer for piping.

### Run-progress visibility (item 3)

- New `SessionEvent` constructor **`RoundStarted Int Int`** (1-based current
  round, `maxToolRounds`). The agentic loop emits it at the top of each round,
  alongside `RunStateChanged RunningLLM`.
- `AppState` gains `asRound :: Maybe (Int, Int)`. `applyEvent` sets it on
  `RoundStarted` and clears it (`Nothing`) on `RunStateChanged Idle`.
- The status bar combines run-state and round, e.g. `running bash… · round 2/10`
  or `thinking… · round 1/10`. When `asRound` is `Nothing`, only the run-state
  label shows (current behaviour).
- Headless ignores `RoundStarted`.

### Session title auto-generation (item 4)

- New `OpenCode.DB.updateSessionTitle :: Connection -> SessionId -> Text -> IO
  ()` (a single `UPDATE sessions SET title = ? WHERE id = ?`), exported.
- New module **`OpenCode.Session.Title`**:
  - `titlePrompt :: Text -> Text` — wraps the first user message in a "Give a
    title of at most 5 words, no quotes, no punctuation" instruction.
  - `sanitizeTitle :: Text -> Text` — take the first line, strip surrounding
    quotes/backticks, collapse whitespace, trim, cap to 6 words / 60 chars; on
    empty input return `"untitled"`.
  - `generateTitle :: Streamer -> ModelId -> Text -> AppM (Maybe Text)` — issues
    a one-shot, tool-free `LLMRequest` (small `reqMaxTokens`), collects the text
    via the conduit, returns `Just (sanitizeTitle text)` or `Nothing` if the
    stream produced no text / errored.
- **Wiring:** in `processUserMessageWith`, *after* the agentic loop completes,
  detect "this was the session's first user message" (the loaded history had
  exactly one message — the just-inserted user message). If so, call
  `generateTitle`; on `Just t`, `updateSessionTitle` and emit a new
  `SessionEvent SessionTitleChanged Text`. Generating *after* the answer avoids
  delaying the first token; the brief post-answer title update is acceptable.
- **TUI:** `AppState` gains `asTitle :: Text` (initialised from the session).
  `applyEvent` sets it on `SessionTitleChanged`. The status bar renders
  `asTitle — asStatusLine` when the title is non-empty and not `"untitled"`,
  else just the model label.
- Title generation reuses the session's streamer (same provider/key). Errors are
  swallowed (a missing title is non-fatal): `generateTitle` returns `Nothing`
  and nothing is updated.

### Context-window summarization (item 5)

- New module **`OpenCode.Session.Summarize`**:
  - `estimateTokens :: [Message] -> Int` — `chars / 4` heuristic over all
    `TextPart`/`ToolResult`/`ToolCall`-args text in the messages.
  - `contextLimit :: ModelId -> Int` — per-provider default: OpenAI `128000`,
    Anthropic `200000`, MiniMax `1000000`. (Per-model refinement is YAGNI.)
  - `needsSummary :: Int -> [Message] -> Bool` — `estimateTokens msgs >= limit`
    where the caller passes `0.8 * contextLimit model` as `limit` (the 80%
    threshold). Taking the threshold as a plain `Int` makes it test-forceable
    with a tiny limit.
  - `summarizePrompt :: [Message] -> Text` — instruction to summarise the given
    older messages into a compact paragraph.
  - `maybeSummarize :: Streamer -> Int -> Int -> [Message] -> AppM [Message]` —
    args are `threshold` and `keepRecent`. If `needsSummary threshold msgs` and
    there are more than `keepRecent` messages, split into
    `(older, recent)` keeping the last `keepRecent`, summarise `older` via a
    one-shot tool-free LLM call, and return
    `[Message RoleUser [TextPart "[Summary of earlier conversation]: …"]] ++
    recent`. Otherwise return `msgs` unchanged. On a failed/empty summary call,
    return `msgs` unchanged (non-fatal).
- **The summary replaces a *prefix* and keeps a *suffix*.** Because tool
  `call`+`result` pairs are bundled inside a single assistant message (the
  OpenAI/Anthropic serialisers split them at message boundaries), cutting
  between whole messages never orphans a tool call from its result.
- **DB is never mutated.** Summarization compacts only the in-memory list used to
  build the request. The full history stays on disk, so `export`/`list` and
  reload are lossless.
- **Wiring:** in `processUserMessageWith`, after loading `history` and before
  `agentic`, run `history' <- maybeSummarize streamer (threshold) keepRecent
  history` and pass `history'` to `agentic`. `threshold = (contextLimit model *
  4) \`div\` 5`; `keepRecent = 6`.

### Stream-error persistence + graceful DB errors (item 6)

- **Persist stream errors.** Today a provider `StreamError` (HTTP 4xx/5xx, or a
  mid-stream drop) is surfaced only as a transient `ErrorOccurred` event and is
  *not* part of the persisted message. Change `buildAssistantMessage` to append
  one `ErrorPart e` per `StreamError e` in the accumulated events, so a partial
  reply persists *with* its error and survives reload/export. Correspondingly,
  the non-abort branch of the loop **stops** emitting the separate
  `mapM_ (emitEvent . ErrorOccurred)` for stream errors (the `MessageAppended`
  now carries them, avoiding a double red line). The truly-empty case (no text,
  no tool, no error) keeps `emptyResponseMessage`. The abort path
  (`buildTextOnlyMessage`) is unchanged (it intentionally ignores tools/errors).
  Existing `SessionSpec` assertions about `ErrorOccurred` are updated to assert
  the persisted `ErrorPart` instead.
- **Graceful DB errors.** SQLite failures (e.g. a locked DB) surface as
  `Database.SQLite.Simple.SQLError` exceptions. Add a top-level catch in
  `OpenCode.Run.runApp` around `dispatch` that catches `SQLError`, prints a clean
  `opencode-hs: database error: <detail>` to stderr, and exits non-zero — no
  Haskell backtrace, no crash. The mapping is factored as a pure
  `renderDbError :: SQLError -> Text` for unit testing.
- **DB decode `error`s become a typed exception.** The `error "…decode failed"`
  calls in `getSession`/`listSessions`/`getMessages` are replaced with
  `throwIO (DBCorruption Text)` — a new exception type exported from
  `OpenCode.DB`, deriving `Exception`. They remain runtime failures (DB
  corruption is genuinely exceptional) but are now catchable values, not pure
  bottoms, and are caught by the same top-level handler.

### Error-path integration tests (item 7)

Four deterministic tests (no real network, no real 30 s sleeps):

a. **Bad API key.** Drive `processUserMessageWith` with a mock streamer scripted
   `[StreamError "openai: 401 …", StreamDone …]` against a temp DB. Assert: the
   call returns `Right ()` (no exception); the persisted assistant message
   contains an `ErrorPart` mentioning `401`; the user message is intact.

b. **Tool failure mid-loop, loop continues.** Register a tool that throws a
   `ToolError`. Mock streamer: round 1 calls that tool (start/arg/end +
   `StreamDone`), round 2 returns text. Assert: round-1 assistant message has a
   `ToolResultPart` with `isError = True`; a round-2 message exists (the loop did
   not abort on tool failure). (This captures the "next round still runs"
   invariant without a literal 30 s timeout.)

c. **DB locked.** Open two connections to one temp-file DB. On conn A,
   `PRAGMA busy_timeout = 0` then hold a write lock (`BEGIN IMMEDIATE` + a
   write). On conn B (also `busy_timeout = 0`), attempt an `insertSession` and
   assert it throws `SQLError` with `sqlError == ErrorBusy`. Then assert
   `renderDbError` on that error produces a clean message (proving the
   top-level handler would exit gracefully).

d. **Streaming drop mid-response.** Mock streamer scripted
   `[TextDelta "partial answer", StreamError "connection reset by peer"]`.
   Assert: the persisted assistant message contains both a `TextPart "partial
   answer"` and an `ErrorPart` mentioning `connection reset`.

### SIGINT handling (item 8)

- New dependency `unix` (a boot library in lts-22.39; v1 targets macOS/Linux per
  SPEC).
- In `withAppEnv`, after building the env, install a SIGINT handler via
  `System.Posix.Signals.installHandler sigINT (Catch (onSigInt env armed))
  Nothing`, where `armed :: TVar Bool` guards one-time arming.
- `onSigInt env armed`: atomically set `envAbort env := True` (cooperative abort,
  same mechanism as Esc/headless). On the *first* SIGINT only, fork a timer:
  `threadDelay 5_000_000 >> exitImmediately (ExitFailure 130)` — i.e. give
  in-flight work 5 s to wind down, then hard-exit. A second SIGINT just re-sets
  abort (the timer is already armed).
- The arming decision is factored as a pure-ish testable helper
  `armOnce :: TVar Bool -> STM Bool` (returns `True` exactly once); a unit test
  asserts `onSigInt` flips `envAbort` and that `armOnce` returns `True` then
  `False`. The signal wiring + 5 s hard-exit are covered by manual acceptance.

### `--version` flag (item 9)

- Add `Version` to `Command`. The top-level parser becomes
  `versionFlag <|> commandSubparser`, where
  `versionFlag = flag' Version (long "version" <> help "Print version and
  exit")`. `parseArgs []` still short-circuits to the default `Run`.
- Dispatch prints `showVersion version` (from `Paths_opencode_hs` +
  `Data.Version`) to stdout and exits 0. hpack auto-adds `Paths_opencode_hs` to
  the library's `autogen-modules`, so `OpenCode.Run` can import it.
- Test: `parseArgs ["--version"] == Just Version`.

### Partial-functions audit + `-Werror` + hlint (item 10)

Runs after all code tasks so it cleans the final tree.

- Remove dead code (MCP + verify) per above (if not already done by then).
- Replace remaining partials in `src`/`app`:
  - `OpenCode.LLM.Request`: `init`/`last`/`BS.init`/`BS.last` → a local total
    `unsnoc`-style helper (base 4.18 has no `Data.List.unsnoc`).
  - `OpenCode.Tool.Glob`: `head line`, `last s`, `init s` → pattern matches /
    the same total helper.
  - `OpenCode.CLI`: `maximum (T.length h : …)` → `foldl' max (T.length h) …`
    (total; the `maximum` is safe-by-construction today but the audit removes the
    partial name).
  - DB decode `error`s → `throwIO (DBCorruption …)` (done in item 6; verify).
- Add `-Werror` to the shared `ghc-options` in `package.yaml`; fix every warning
  it surfaces until `stack build --ghc-options="-Wall -Werror"` is clean. Keep
  the existing `-Wno-unused-top-binds`.
- `hlint src app test` exits 0 (drop `verify/` from the CI hlint path).
- CI inherits `-Werror` from `package.yaml`; no separate CI flag needed, but
  confirm `ci.yml`'s hlint `path` no longer lists `verify/`.

### README (item 11)

`README.md` with: CI badge (already referenced in M3), one-line description,
install (`stack install` / `stack build`), quickstart (the
`stack run opencode-hs -- …` invocations: bare TUI, `run --prompt --no-tui`,
`list`, `export`, `config check`, `--version`), configuration reference
(env vars `OPENAI_API_KEY`/`ANTHROPIC_API_KEY`/`MINIMAX_API_KEY` and the
`~/.config/opencode-hs/config.yaml` shape), supported providers/models, the six
built-in tools, and a short troubleshooting section (no key → config error;
`OPENCODE_MOCK=1` for keyless manual testing).

---

## Architecture / module impact

| Module | Change |
| --- | --- |
| `OpenCode.Types` | `StreamEvent` += `ReasoningDelta Text` |
| `OpenCode.Session.Events` | `SessionEvent` += `PartialReasoning`, `RoundStarted`, `SessionTitleChanged` |
| `OpenCode.LLM.OpenAI` | `Delta` += `deltaReasoning`; `processChunk` emits reasoning; `splitThink` conduit stage; `interpretOpenAIStream` wires it |
| `OpenCode.Session` | `consumeStream` emits reasoning; `buildAssistantMessage` persists `ErrorPart`; `agentic` emits `RoundStarted` + suppresses empty-response on reasoning; `processUserMessageWith` does summarize-before + title-after |
| `OpenCode.Session.Title` | **new** |
| `OpenCode.Session.Summarize` | **new** |
| `OpenCode.DB` | `updateSessionTitle`; `DBCorruption` exception; decode `error` → `throwIO` |
| `OpenCode.TUI.Types` | `AppState` += `asPartialReasoning`, `asRound`, `asTitle` |
| `OpenCode.TUI.App` | `applyEvent` handles new events; `initialState` sets `asTitle` |
| `OpenCode.TUI.Render` | dim reasoning block; round in status bar; title in status bar |
| `OpenCode.CLI` | `Version` command + `versionFlag` |
| `OpenCode.Run` | `--version` dispatch; SIGINT install; top-level `SQLError` catch; headless reasoning→stderr |
| `OpenCode.App.Error` | (if needed) DB error rendering hook |
| `OpenCode.MCP` | **deleted** |
| `verify/*`, `package.yaml`, `ci.yml` | verify execs deleted; `-Werror`; hlint path |
| `README.md` | **new** |

## Testing strategy

- **Pure first.** Every new pure function (`splitThink` state stepper,
  `sanitizeTitle`, `titlePrompt`, `estimateTokens`, `contextLimit`,
  `needsSummary`, `renderDbError`, `armOnce`) gets direct unit tests.
- **Fixture replay** for the OpenAI reasoning parser: new fixtures under
  `test/fixtures/openai/` for `reasoning_content` and inline `<think>`.
- **Mock-streamer integration** for session-level behaviour (reasoning event
  emission, error persistence, title generation, summarization, tool-failure
  continuation) against a temp DB — reusing the existing `OpenCode.TestEnv` and
  `OpenCode.LLM.Mock` helpers.
- **Reducer tests** for every new `applyEvent` branch (mutation-verified).
- New `*Spec.hs` modules are added to `package.yaml` test `other-modules`
  (hspec-discover finds them, but the cabal list must include them).

## Acceptance (from MILESTONES.md M12)

- `stack build --ghc-options="-Wall -Werror"` is clean.
- `hlint src app test` exits 0.
- No `head`/`tail`/`read`/`fromJust`/`undefined`/`error` outside `test/`.
- All four error-path integration tests pass.
- `stack run opencode-hs -- --version` prints the cabal version.
- A conversation over an artificially-low context limit triggers summarization
  (test-verifiable).
- README takes a fresh user from install to first prompt.
- A fixture stream carrying `reasoning_content` / `<think>` renders as a dim
  thinking block, not an empty/error line.
- During a scripted multi-round mock run, the status bar reflects the active
  round number and the running tool.
