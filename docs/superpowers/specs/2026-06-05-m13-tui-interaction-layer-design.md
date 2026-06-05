# M13 — TUI Interaction Layer — Design Spec

> Status: approved interactively. Brainstormed via superpowers:brainstorming.
> Three clarifying decisions, the interaction approach, and design Sections 1–2
> were approved live; Sections 3–4 (actions/persistence, run-path change, edge
> cases, testing) are folded in here for the spec review gate.

**Goal:** Add an in-TUI interaction layer so a running session can be steered
without restarting the process: **slash commands**, a **session switcher**, and
**model switching** — all through a single reusable **modal overlay** primitive.

This is sub-project **A** of the post-v1 roadmap (A → B → C). It deliberately
builds substrate the later milestones reuse: the overlay primitive and slash
dispatcher are reused by M15 (skill system), and nothing here depends on M14
(MCP).

---

## Scope

**In scope**

1. Slash-command parsing and dispatch in the TUI Enter handler.
2. A reusable centered **modal overlay** primitive (brick has no built-in modal).
3. `/sessions` — switch to another stored session.
4. `/new` — create a fresh session and switch to it.
5. `/model` — switch the current session's model (persisted to the session).
6. `/help` — list keys and commands.
7. `/quit` — halt (alias for Ctrl-C).
8. **Run-path change:** make the agentic run honor the *session's* model instead
   of the config default (required for #5 to take effect; also fixes a latent
   resume bug — see below).

**Out of scope (future)**

- A **command queue** for commands issued mid-run (M13 blocks them until idle;
  the dispatcher this milestone introduces is the natural place to add a queue
  later).
- A live-filtering command **palette** (we chose discrete commands + modal
  pickers; the palette can layer on later over the same dispatcher).
- Inline arguments to `/model` (e.g. `/model openai:gpt-4o`) — `/model` always
  opens the picker in M13.
- Expanding the model catalog beyond a curated seed (trivially extensible later).
- MCP (M14) and skills (M15).

---

## Decisions captured from brainstorming

| Question | Decision |
|---|---|
| Interaction style | **Command + modal picker** — type a full command + Enter; choices that need a list open a centered modal. |
| `/model` reach | **Persist to the current session** (`sessionModel` in the DB). Reload/resume keeps it. New sessions still use the config default. |
| Command issued mid-run | **Block context-changing commands until idle**, with a status notice. `/help` and `/quit` work anytime. Queue is deferred. |
| Overlay implementation | **Custom minimal picker + `UIMode` sum + pure reducers** (matches the codebase's pure-reducer testing discipline; brick 2.1 exposes no pure `EventM` runner). |

---

## Architecture

### State changes (`OpenCode/TUI/Types.hs`)

Two fields added to `AppState`, plus three new plain-data types:

```haskell
data UIMode
  = ModeNormal
  | ModeOverlay Overlay

data Overlay = Overlay
  { ovTitle :: Text
  , ovSel   :: Int            -- selected row, always clamped to [0, count-1]
  , ovKind  :: OverlayKind
  }

data OverlayKind
  = OverlaySessions SessionId [Session]  -- current id (for the * marker) + rows indexed by ovSel
  | OverlayModels   ModelId   [ModelId]  -- current model (* marker + preselect) + rows
  | OverlayHelp     [Text]               -- /help (non-actionable lines; Enter/Esc closes)

-- AppState gains:
--   asMode   :: UIMode        -- ModeNormal by default
--   asNotice :: Maybe Text    -- transient one-line status feedback
```

`ovKind` carries the *typed* payload; the row labels are derived from the kind at
render time, so there is no parallel label/payload list to keep in sync.

`asNotice` carries transient one-line feedback shown in the status bar:
- the block hint (`"press Esc to abort the run first"`),
- the model-switch confirmation (`"model set to anthropic:claude-opus-4-5"`),
- `"new session created"`, and `"unknown command: /foo"`.

`asNotice` is cleared at the start of the next command dispatch and whenever a
run starts, so it never lingers.

### Module layout

| Module | Responsibility | Depends on |
|---|---|---|
| `TUI/Types.hs` *(edit)* | `UIMode`, `Overlay`, `OverlayKind`, `asMode`, `asNotice` | — |
| `TUI/Command.hs` *(new)* | `Command` type + pure `parseCommand :: Text -> Maybe Command` | — (no brick) |
| `TUI/Overlay.hs` *(new)* | Pure reducers, smart constructors, label helpers (no brick) | Types, Catalog |
| `Model/Catalog.hs` *(new)* | `knownModels`, `availableModels`, and `modelLabel`/`providerLabel` (moved here from `App.hs`) | Config, Types |
| `TUI/Render.hs` *(edit)* | `renderOverlay` (the floating picker) + the notice line | Overlay, Types |
| `TUI/App.hs` *(edit)* | Event routing on `asMode`; thin IO actions (switch/new/model-set) | all above |
| `Session.hs` *(edit)* | Thread the session model through the run path | — |
| `DB.hs` *(edit)* | `updateSessionModel :: Connection -> SessionId -> ModelId -> IO ()` | — |

`App.hs` is already ~294 lines; pushing parsing, overlay reducers, the catalog,
and overlay rendering into their own modules keeps it focused.

**Module-boundary note (avoids import cycles):** rendering stays entirely in
`Render.hs` (`drawUI` *and* `renderOverlay`, which needs `Render.hs`'s attrs), so
`Overlay.hs` is pure with no brick dependency. `modelLabel`/`providerLabel` move
from `App.hs` to `Model/Catalog.hs` so both `App.hs` and `Overlay.hs` (for model
row labels) can use them without an `App ↔ Overlay` cycle. Resulting layering:
`Types → Catalog → Overlay → Render → App`.

### Rendering

`drawUI` currently returns a single top widget. In `ModeOverlay` it returns
`[renderOverlay ov, baseWidget]` — brick draws the list head as the top layer, so
the centered bordered picker floats over the chat. `renderOverlay` uses
`centerLayer` + `borderWithLabel ovTitle` + a vertical list of rows, with the
`ovSel` row highlighted (reusing an existing attr, e.g. `statusAttr`). No new
brick primitive is introduced.

---

## Commands & parsing

| Command | Action | Allowed while a run streams? |
|---|---|---|
| `/new` | Create a fresh session (config default model), switch to it | No — blocked until idle |
| `/sessions` | Open the session picker overlay | No — blocked until idle |
| `/model` | Open the model picker overlay | No — blocked until idle |
| `/help` | Open the help overlay | Yes |
| `/quit` | Halt the app | Yes |
| `/<other>` | Set `asNotice = "unknown command: …"` | Yes |

```haskell
data Command = CmdNew | CmdSessions | CmdModel | CmdHelp | CmdQuit | CmdUnknown Text

parseCommand :: Text -> Maybe Command
--   Nothing            => not slash-prefixed → treat as an LLM prompt (existing path)
--   Just CmdNew …      => recognized command
--   Just (CmdUnknown t)=> slash-prefixed but unrecognized
```

`parseCommand` strips surrounding whitespace, matches case-insensitively on the
first word, and ignores any trailing arguments in M13. Pure and unit-tested.

---

## Event routing (`handleEvent`)

`handleEvent` branches on `asMode` **first**.

**`ModeOverlay`** (a picker/help is open):
- `↑` / `↓` → `overlayMove` (pure, clamped).
- `Enter` → commit the selected row (perform its IO action), then close the
  overlay (`asMode = ModeNormal`). For `OverlayHelp`, Enter just closes.
- `Esc` → close the overlay (cancel). Does **not** abort a run.
- `Ctrl-C` → halt (unchanged).
- any other key → ignored (no typing leaks into the chat behind the overlay).

**`ModeNormal`** — the `Enter` handler gains a pre-check. First clear `asNotice`,
then:
1. `parseCommand body == Nothing` → existing LLM-submit path (submits only when
   `Idle`, exactly as today).
2. `Just cmd` → dispatch:
   - `/help`, `/quit` → run regardless of run-state (`/help` opens the overlay;
     `/quit` halts).
   - `/new`, `/sessions`, `/model` → only when `asRunState == Idle`; otherwise set
     `asNotice = "press Esc to abort the run first"` and do nothing else.
   - Input is always cleared after a command is recognized.

Scroll keys, Esc-when-normal (abort), and editor typing keep their current
behavior. **Esc disambiguation:** overlay open → Esc closes the overlay; overlay
closed → Esc requests run abort (today's meaning). The two states are mutually
exclusive, so the key is never ambiguous.

Because context-changing commands are blocked unless `Idle`, an actionable
overlay (`/sessions`, `/model`) only ever opens when no run is in flight — so
there are no in-flight partials or events to reconcile on switch.

---

## Overlay component (`TUI/Overlay.hs`)

Pure (no `IO`, no `EventM`, no brick), so unit-testable like the existing
`applyEnter` / `applyEvent`:

```haskell
overlayCount    :: OverlayKind -> Int
overlayMove     :: Int -> Overlay -> Overlay       -- delta; clamps to [0,count-1]; no-op if empty
overlayLabels   :: OverlayKind -> [Text]           -- render labels, in payload order

sessionsOverlay :: SessionId -> [Session] -> Overlay -- title "sessions"; current marked; sel 0
modelsOverlay   :: ModelId -> [ModelId] -> Overlay   -- title "model"; sel = index of current model (else 0)
helpOverlay     :: Overlay                            -- title "help"; static lines
```

`renderOverlay :: Overlay -> Widget ResourceName` lives in `Render.hs` (it needs
that module's attrs); it consumes `overlayLabels` and `ovSel` to draw the rows.

Label formats (via `overlayLabels`):
- sessions: `"<title>   <relative-time>"`, with the current session marked (`*`).
- models: `modelLabel m` (i.e. `provider:model`), current model marked (`*`).
- help: fixed lines listing the key bindings and the command set.

---

## Actions & persistence (`TUI/App.hs`)

Each action does its `IO` in `EventM`, then applies a **pure** state transition
(the testable seam, mirroring `applyEnter`). All `IO` is wrapped in `try`; on
failure the action sets `asNotice = "error: …"` and leaves state otherwise
untouched, so a DB hiccup never crashes the TUI (consistent with M12's graceful
DB-error handling).

**`/new`** — `createSession (Config.defaultModel cfg)` → then switch to it (its
message list is empty). `asNotice = "new session created"`.

**Switch session** (from the `/sessions` picker, and reused by `/new`):
```haskell
-- IO: load messages for the chosen session
applySwitch :: Session -> [Message] -> AppState -> AppState
-- sets asSessionId, asTitle, asStatusLine (model label),
-- asMessages; resets asPartialText/asPartialReasoning="",
-- asRound=Nothing, asRunState=Idle, asMode=ModeNormal.
```
After the pure update the handler scrolls the chat to the end.

**`/model` set** (from the `/model` picker):
```haskell
-- IO: DB.updateSessionModel conn sid newModel
applyModelSet :: ModelId -> AppState -> AppState
-- sets asStatusLine = modelLabel newModel, asMode = ModeNormal,
-- asNotice = "model set to <provider:model>".
```
The next run reads the model from the session (see run-path change), so the
DB write is what makes the switch take effect.

### Model catalog (`Model/Catalog.hs`)

```haskell
knownModels    :: [ModelId]                       -- curated seed
availableModels :: ProviderConfig -> [ModelId]    -- keep only providers with a key
```

`knownModels` is seeded with the documented one-per-provider set
(`openai:gpt-4o`, `anthropic:claude-opus-4-5`, `minimax:MiniMax-M3`) and is
extended by editing the list. `availableModels` filters to providers whose key is
present (`isJust`), since you can't run a model whose provider has no key. The
`/model` overlay shows `availableModels (providers cfg)`; if it is somehow empty
(can't happen once the app has started, which requires a key), the dispatcher
sets a notice instead of opening an empty overlay.

---

## Run-path change — make the run honor `sessionModel` (`Session.hs`)

Today the run path is model-blind to the session:
- `buildRequest` uses `model (Config.defaultModel (envConfig env))`,
- `selectStreamer` picks the provider from `Config.defaultModel cfg`,
- `processUserMessageWith` reads `Config.defaultModel . envConfig` for the
  context-limit threshold, summarization, and title generation.

`sessionModel` is written at creation but never read for a run. So `/model`
persistence alone would be cosmetic. The fix threads the session's model through
the run:

- `buildRequest :: AppEnv -> ModelId -> [Message] -> LLMRequest` — `reqModel = model mdl`.
- `agentic :: Streamer -> ModelId -> SessionId -> [Message] -> AppM [Message]` —
  passes `mdl` to `buildRequest`.
- `processUserMessageWith :: Streamer -> ModelId -> SessionId -> Text -> AppM ()`
  — uses the passed `mdl` for threshold/summarize/title and for `agentic`.
- `processUserMessage sid prompt` — `loadSession sid` to get `sessionModel`;
  select the streamer via `streamerForProvider cfg (provider mdl)`; pass `mdl`
  down. If the session is missing, fail with the existing error path. The
  `OPENCODE_MOCK` branch passes the session model through unchanged.
- `selectStreamer` (default-model-only helper) is replaced by the inline
  `streamerForProvider cfg (provider mdl)` call; `streamerForProvider` itself is
  unchanged (still used by `config check`).

**Side benefit (latent bug fix):** `run --session <ID>` currently resumes a
session using the *current* config default model rather than the session's stored
model. After this change, resume honors the stored model.

**Test updates (mechanical):** add the `ModelId` argument to the 8 `agentic` call
sites in `SessionSpec` and the 3 `processUserMessageWith` call sites in
`ErrorPathSpec`. The model passed is the session's model (`ModelId OpenAI
"gpt-4o"` in those fixtures), so behavior is unchanged.

---

## Error handling & edge cases

- **DB errors during an action** — wrapped in `try`; surfaced as `asNotice`, no
  crash.
- **Switching to the current session** — harmless reload (no-op in effect).
- **Empty model list** — dispatcher sets a notice instead of opening an empty
  overlay (defensive; unreachable once started).
- **Out-of-range selection** — `overlayMove` clamps; smart constructors clamp the
  initial `ovSel`.
- **Blocked command mid-run** — notice only; run continues untouched.
- **`/quit` during a run** — halts immediately, same as Ctrl-C (the forked run is
  abandoned with the process, matching today's Ctrl-C behavior).

---

## Testing strategy

Following the codebase's pure-reducer discipline (logic in pure functions a thin
`EventM`/`IO` shell calls):

- **`CommandSpec`** (new): `parseCommand` — non-slash → `Nothing`; each known
  command; unknown → `CmdUnknown`; case-insensitivity; whitespace; trailing args
  ignored.
- **`OverlaySpec`** (new): `overlayMove` clamping (top/bottom bounds, empty list,
  multi-step); `modelsOverlay` preselects the current model; `availableModels`
  filters by configured providers.
- **`RenderSpec`** (extend): each `OverlayKind` renders without throwing and shows
  its title (reuse the existing `renderWidget`/`renderHeight` harness); the notice
  line renders; the base chat still renders behind the overlay.
- **Pure state helpers**: `applySwitch` and `applyModelSet` unit-tested directly.
- **Run-path**: a unit test that `buildRequest env mdl history` sets
  `reqModel == model mdl` (proves the run uses the threaded model, not the config
  default). Existing `SessionSpec`/`ErrorPathSpec` continue to pass after the
  mechanical signature updates.

The live-`EventM` wiring (key → action) is covered indirectly: the pure pieces it
calls are all unit-tested, matching how `handleEvent` is treated today.

---

## Acceptance criteria

1. Typing `/help` opens an overlay listing keys and commands; Esc or Enter closes
   it; the chat is untouched.
2. `/sessions` opens a picker of stored sessions (current marked); `↑/↓` moves the
   selection; Enter switches — the chat reloads that session's history, the title
   and model label update, and input is ready. Esc cancels with no change.
3. `/new` creates a session and switches to it with an empty chat.
4. `/model` opens a picker of models for configured providers (current marked);
   Enter persists the choice to the session (`sessionModel` in the DB), updates
   the status bar, and shows a confirmation notice. A subsequent prompt is served
   by the chosen model/provider; reloading the session keeps the choice.
5. While a run is streaming, `/new` / `/sessions` / `/model` are no-ops with a
   "press Esc to abort first" notice; `/help` and `/quit` still work.
6. Esc closes an open overlay; with no overlay open, Esc still requests run abort.
7. An unrecognized `/foo` shows an "unknown command" notice and is not sent to the
   LLM. A non-slash line is sent to the LLM exactly as before.
8. `stack build` is clean under `-Wall -Werror`; `hlint` is clean; the full test
   suite passes, including the new `CommandSpec`/`OverlaySpec` and the extended
   `RenderSpec`.
