# M13.1 — Slash-Command Autocomplete Design

> Enhancement to the M13 TUI interaction layer. Numbered M13.1 so the M14
> (MCP client) / M15 (skill system) roadmap numbering is untouched.

**Goal:** When the user types `/` at the input line, show the available slash
commands (with descriptions) in a live, keyboard-navigable panel, so they don't
have to remember the command names.

## Problem

M13 added slash commands (`/new`, `/sessions`, `/model`, `/help`, `/quit`) that
are parsed only *after* the user presses Enter (`parseCommand`). There is no
discovery affordance: a user must already know a command exists and how it is
spelled. `/help` lists them, but only if you remember `/help`.

## Solution overview

A **non-modal suggestion panel** that appears the moment the input begins with
`/`, listing the commands whose name matches what has been typed so far, each
with a one-line description. It is keyboard-navigable:

- `↑` / `↓` — move the highlight through the matches
- `Tab` — complete the highlighted command into the input (cursor at end)
- `Enter` — run the highlighted command immediately

The panel is **derived purely from the current input text** — it auto-shows when
the input starts with `/` and has ≥1 match, and auto-hides otherwise. The only
new state is the highlighted row index.

### Why not reuse the modal overlay (`ModeOverlay` / `OverlayKind`)?

The existing overlay machinery (session/model/help pickers) is **modal**: it is a
centered layer that blocks the editor and routes keys away from it. Autocomplete
is the opposite — the user must keep *typing into the editor* while the panel is
visible. Modeling it as a `UIMode` or an `OverlayKind` would fight that
abstraction and require special-casing the "still editing" behavior everywhere.
Instead this is a thin, non-modal panel layered above the input box while
`ModeNormal` remains in force.

## Architecture

One focused change across the existing TUI layering
(`Types → Catalog → Overlay → Render → App`). No new module, no new `UIMode`.

### 1. `OpenCode.TUI.Command` (extend) — command catalog & suggestions

The single source of truth for command name + description:

```haskell
-- name (with leading slash) + one-line description, in display order.
commandCatalog :: [(Command, Text, Text)]
commandCatalog =
  [ (CmdNew,      "/new",      "start a new session")
  , (CmdSessions, "/sessions", "switch session")
  , (CmdModel,    "/model",    "change model (this session)")
  , (CmdHelp,     "/help",     "show help")
  , (CmdQuit,     "/quit",     "exit")
  ]

-- Matches for the current input line. Empty unless the trimmed input starts
-- with '/'. Otherwise: catalog rows whose name has the typed first token as a
-- case-insensitive prefix. '/' alone matches all; '/se' -> just '/sessions';
-- '/foo' -> []. Returns (name, description) pairs in catalog order.
commandSuggestions :: Text -> [(Text, Text)]
```

`parseCommand` is unchanged. The matching token is the first whitespace-delimited
word of the trimmed input, lower-cased (consistent with `parseCommand`).

### 2. `OpenCode.TUI.Overlay` — derive help from the catalog (DRY)

`helpOverlay`'s "commands:" block currently hard-codes the same five
command/description lines. Re-derive that block from `commandCatalog` so the help
text and the autocomplete panel can never drift apart. The "keys:" block stays as
is.

### 3. `OpenCode.TUI.Types` — one new field

```haskell
data AppState = AppState
  { ...
  , asSuggestSel :: Int   -- ^ highlighted suggestion row; clamped to matches
  }
```

Panel *visibility* is not stored — it is derived from
`commandSuggestions (currentInput st)`. `asSuggestSel` is the only new state, and
is reset to 0 whenever the input changes (see §5).

### 4. `OpenCode.TUI.Render` — the panel

`drawUI` gains a suggestion layer between the status bar and the input box:

```haskell
drawUI st =
  overlayLayer (asMode st)
    <> [chat <=> statusBar st <=> suggestBox st <=> inputBox st]
```

`suggestBox st` is `Brick.emptyWidget` when `commandSuggestions (currentInput st)`
is empty; otherwise a bordered panel titled `commands`, one row per match
(`/name  description`), with the row at `asSuggestSel` drawn using the existing
`statusAttr` highlight bar (the same look as overlay rows). Left-aligned (not
centered — it sits directly above the input).

### 5. `OpenCode.TUI.App` — key handling

`handleNormal` branches on whether suggestions are active
(`not (null (commandSuggestions (currentInput st)))`):

**When suggestions are active:**

| Key       | Action                                                                 |
|-----------|------------------------------------------------------------------------|
| `↑` / `↓` | Move highlight, clamped to `[0, matchCount-1]`                          |
| `Tab`     | Replace input with the highlighted `/name` (cursor at end); reset highlight to 0 |
| `Enter`   | Run the highlighted command: clear input, then `parseCommand name` → `dispatchCommand` |
| `PgUp`/`PgDn` | Scroll the chat (unchanged)                                        |
| other     | Pass to the editor as before, **and reset `asSuggestSel` to 0**         |

**When suggestions are not active:** behavior is exactly today's — `Enter` =
`onEnter`, `↑`/`↓` scroll, etc. `Esc` is unchanged in both cases (the panel needs
no explicit dismiss; it auto-hides when the input no longer starts with `/`).

`Enter`-on-highlight reuses the existing `dispatchCommand`, so run-in-flight
gating (`/new`, `/sessions`, `/model` blocked mid-run with a notice) and DB-error
handling are inherited unchanged. `Tab`-complete keeps the user in edit mode so a
second `Enter` runs it.

Pure reducers (matching the codebase's testable-core pattern):

- `applySuggestMove :: Int -> AppState -> AppState` — move the highlight by a
  delta, clamped to the current match count (no-op when there are no matches).
- `applyComplete :: AppState -> AppState` — `Tab`: set the input to the
  highlighted command name (cursor at end), reset highlight to 0.

## Data flow

```
keystroke ──▶ handleNormal
                 │  matches = commandSuggestions (currentInput st)
                 ├─ matches /= [] ─▶ ↑/↓  : applySuggestMove
                 │                   Tab  : applyComplete
                 │                   Enter: parseCommand (highlighted name)
                 │                           ▶ dispatchCommand (existing path)
                 │                   other: editor edit + reset highlight
                 └─ matches == [] ─▶ existing normal-mode handling

drawUI ──▶ ... <=> suggestBox st <=> inputBox st
              suggestBox = emptyWidget          when matches == []
                         = bordered "commands"  otherwise (highlight @ asSuggestSel)
```

## Error handling

No new error paths. Suggestions are pure over the input text. Running a command
flows through the existing `dispatchCommand`, which already turns run-in-flight
and DB failures into status-bar notices.

## Testing

All logic is pure and unit-testable (live key→action wiring stays untested for
the same reason as M13: brick 2.x exposes no pure `EventM` runner).

- **`commandSuggestions`**: `/` alone → all five in catalog order; `/se` → just
  `/sessions`; prefix is case-insensitive (`/SE` → `/sessions`); leading
  whitespace tolerated (`"  /m"` → `/model`); non-slash input → `[]`; unknown
  (`/foo`) → `[]`.
- **`applySuggestMove`**: clamps at both ends; no-op when matches is empty;
  composes (down, down, up).
- **`applyComplete`**: after completing, `currentInput` equals the highlighted
  command name and `asSuggestSel` is 0; no-op when matches is empty.
- **catalog/help consistency**: `helpOverlay`'s command rows are derived from
  `commandCatalog` (a test asserts each catalog name appears in the help rows).

## Acceptance criteria

1. Typing `/` shows a panel listing all five commands with descriptions.
2. Typing more characters narrows the panel by case-insensitive name prefix;
   `/foo` (no match) shows no panel.
3. `↑`/`↓` move a visible highlight, clamped to the list.
4. `Tab` completes the highlighted command into the input (cursor at end) and
   leaves the user in edit mode.
5. `Enter` runs the highlighted command (same effect as typing it fully and
   pressing Enter), including run-in-flight gating for context-changing commands.
6. The panel disappears as soon as the input no longer starts with `/`.
7. Existing normal-mode behavior (chat scroll, prompt submission, modal pickers)
   is unchanged when no suggestions are showing.

## Out of scope (YAGNI)

- Fuzzy / substring matching (prefix only).
- Argument completion (commands take no args in M13).
- Mouse interaction.
- Completing non-command text (history, file paths).
