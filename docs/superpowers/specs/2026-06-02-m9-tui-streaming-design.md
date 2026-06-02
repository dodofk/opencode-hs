# M9 — TUI: streaming + inline tools + abort — Design

**Status:** Design approved 2026-06-02 (brainstorming). Branch `m9-tui-streaming`.
**Scope source:** Expands `MILESTONES.md` §M9 with the decisions resolved during brainstorming.

## Goal

Layer three things onto M8's static `brick` TUI:

1. **Live token streaming** — assistant text appears delta-by-delta as it arrives.
2. **Inline tool execution** — tool calls and their results render in the chat as the loop runs.
3. **Cooperative mid-stream abort** — `Esc` stops the in-flight response immediately.

## Current state (verified against code)

- `OpenCode.Session.Events` already defines the full `SessionEvent` vocabulary, **including `PartialText Text`**, and `RunState` (`Idle | RunningLLM | RunningTool Text | AwaitingInput`).
- `AppEnv` already carries `envEventChan :: BChan SessionEvent` and `envAbort :: TVar Bool`.
- `agentic` already emits `RunStateChanged`, `MessageAppended`, `ToolStarted`/`ToolFinished`, and already checks `envAbort` **between rounds**.
- The single real gap is `Session.hs:120-121` — `stream .| Conduit.sinkList` buffers the entire round before processing, so no `PartialText` flows during streaming and abort cannot interrupt mid-stream.
- `startTUI` uses `defaultMain`; `handleEvent` has no `AppEvent` (SessionEvent) branch and no `Esc` handler.
- `OpenCode.LLM.Mock` streamers emit instantly — no delayed variant exists.

## Decisions resolved in brainstorming

1. **Abort = stop now, text-only.** On abort the round finalizes a **text-only** assistant message from what streamed and executes **no** pending tool call — even one that fully arrived (`ToolCallStart…ToolCallEnd`) before the abort point. "Cancel means cancel"; no side-effecting `bash`/`write_file` fires after `Esc`.
2. **`envAbort` reset.** The flag is reset to `False` at the start of each run (in the Enter fork, before calling `processUserMessage`); otherwise the second prompt would abort instantly. *(Not in the original spec — gap filled here.)*
3. **Fork robustness.** The forked run always emits `RunStateChanged Idle` on completion **and on error/exception**, so a failure (e.g. missing API key) never leaves the UI stuck with Enter disabled.
4. **`AppState` embeds `asEnv :: AppEnv`** (per the original spec). The pure `applyEvent` reducer never reads it, so reducer unit tests stay clean.
5. **Mock streamer dispatch lives in `processUserMessage`**, gated on `OPENCODE_MOCK=1`, keeping the Enter handler dumb (it always calls `processUserMessage`).
6. **Rejected alternative:** storing the `Async` handle to hard-cancel on `Esc`. Cooperative abort via `envAbort` is simpler, lets `ResourceT` close the HTTP connection deterministically, and avoids killing a thread mid-DB-write.

## Components / changes

### 1. `Session.hs` — streaming fold (core change)

Replace `stream .| Conduit.sinkList` with an effectful sink that processes events as they arrive and returns the accumulated list plus an abort flag:

```haskell
-- Runs in ResourceT IO; chan + abortVar captured from env.
consume :: BChan SessionEvent -> TVar Bool
        -> ConduitT StreamEvent o (ResourceT IO) ([StreamEvent], Bool)
consume chan abortVar = loop []
  where
    loop acc = await >>= \case
      Nothing -> pure (reverse acc, False)              -- normal end
      Just ev -> do
        case ev of
          TextDelta t -> liftIO (writeBChan chan (PartialText t))
          _           -> pure ()
        aborted <- liftIO (readTVarIO abortVar)
        if aborted then pure (reverse (ev : acc), True)  -- keep this event, stop pulling
                   else loop (ev : acc)
```

Stopping `await` lets `runResourceT` run the HTTP conduit finalizers → connection closes (cooperative abort).

In the round loop (`go`):

```haskell
(events, aborted) <- liftIO $ runResourceT $ runConduit $ stream .| consume chan abortVar
if aborted
  then do
    mMsg <- buildTextOnlyMessage events     -- collectText only; no executeOne
    finalizeAbort mMsg                       -- persist iff Just; emit MessageAppended; emit RunStateChanged Idle
    pure (reverse appended <> toList mMsg)
  else <existing buildAssistantMessage path, unchanged>
```

- `buildTextOnlyMessage :: [StreamEvent] -> AppM (Maybe Message)` — `collectText` only; `Nothing` when empty (skip persistence). Mints `msgId`/timestamp like `buildAssistantMessage`.
- The non-abort branch is the existing logic verbatim (text + tools, recurse if a tool ran). The conduit writes `PartialText` directly to the `BChan` via `liftIO` (same effect as `emitEvent`, which is unavailable inside `ResourceT IO`).

### 2. `TUI/Types.hs` — `AppState`

Add `asPartialText :: Text`, `asEnv :: AppEnv`, `asSessionId :: SessionId`; drop `asEventChan` (reach the chan via `asEnv`).

### 3. `TUI/App.hs` — `applyEvent` (pure, exported for testing)

```haskell
applyEvent :: SessionEvent -> AppState -> AppState
```

| Event | Effect |
|---|---|
| `MessageAppended m` | `asMessages |> m`, clear `asPartialText` |
| `PartialText t` | `asPartialText <> t` |
| `ToolStarted n` | `asRunState = RunningTool n` |
| `ToolFinished _ _` | no-op (parts arrive in next `MessageAppended`) |
| `RunStateChanged s` | `asRunState = s`; if `Idle`, clear `asPartialText` |
| `ErrorOccurred e` | append synthetic assistant `Message` with one `ErrorPart e` |

`handleEvent`'s `AppEvent ev` branch: `get >>= put . applyEvent ev`.

### 4. `TUI/App.hs` — Enter / Esc

- **Enter** (only when `asRunState == Idle`): append the user `Message` (existing `applyEnter`), `writeTVar envAbort False`, then `async` a forked run of `runAppM (asEnv st) (processUserMessage (asSessionId st) body)`. The fork's wrapper catches any `AppError`/exception and emits `ErrorOccurred e` **and** `RunStateChanged Idle`. Handle is fire-and-forget (abort is cooperative). Enter is ignored while a run is active.
- **Esc**: `writeTVar envAbort True`.

### 5. `TUI/App.hs` — `startTUI` → `customMain`

Drop `defaultMain`; build a `Vty` and feed `envEventChan` directly — no pump thread (`BChan SessionEvent` is exactly what `customMain` consumes; `SessionEvent` is already the app's event type):

```haskell
let buildVty = mkVty defaultConfig
initialVty <- buildVty
_ <- customMain initialVty buildVty (Just (envEventChan env)) app st0
```

### 6. `TUI/Render.hs` — in-flight partial

While `asRunState /= Idle` **and** `asPartialText` is non-empty, render a dim synthetic assistant message at the bottom of the viewport. `MessageAppended` clears the buffer and appends the committed `Message` in the same reducer step, so text hands off cleanly (no double-render).

```
▌ assistant
  The capital of France is Par▌      ← dim, while streaming
──────────────────────────────────
 openai:gpt-4o            thinking…
┌ input ─────────────────────────┐
│                                │
└────────────────────────────────┘
```

### 7. `LLM.Mock` + `Session.hs` — keyless manual testing

Add `delayedStreamer :: [StreamEvent] -> Streamer` that yields canned chunks with `threadDelay` between them (~10 s total). In `processUserMessage`: if `OPENCODE_MOCK=1`, use the delayed mock; otherwise the OpenAI path.

## Testing

- **`applyEvent` reducer:** feed a fixed `SessionEvent` sequence against a fixture state; assert final message list + empty `asPartialText`. Mutation-verify each case.
- **Abort reconciliation:** `PartialText "abc"` → `RunStateChanged Idle` ⇒ `asPartialText == ""`, `asRunState == Idle`.
- **`agentic` abort (new):** mock streamer + pre-set `envAbort` ⇒ round produces a **text-only** truncated message and executes **no** tool, even when the scripted prefix contains a complete tool call. Locks in decision #1.
- **Manual:** `OPENCODE_MOCK=1 stack run` — watch streaming; `Esc` mid-stream keeps the partial as a finalized, persisted message; `Ctrl+C` exits.

## Acceptance

`stack run` (with `OPENAI_API_KEY`) or `OPENCODE_MOCK=1 stack run` opens a TUI; pressing Enter streams the response live; pressing `Esc` aborts mid-stream and the partial text remains visible as a finalized, persisted message; `Ctrl+C` exits cleanly.

## Concurrency safety

Single active run at a time (Enter gated on `asRunState == Idle`) ⇒ exactly one writer touches SQLite; the brick thread only *reads* `envEventChan`. No concurrency hazard.

## Out of scope (deferred to M12)

Hard cancellation, context-window summarization, session-title auto-generation, SIGINT handling.
