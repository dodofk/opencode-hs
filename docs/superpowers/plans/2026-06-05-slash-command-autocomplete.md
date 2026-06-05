# Slash-Command Autocomplete Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When the TUI input line begins with `/`, show a live, keyboard-navigable panel of matching slash commands (with descriptions) so the user doesn't have to remember command names.

**Architecture:** A non-modal suggestion panel rendered above the input box while `ModeNormal` stays in force. A pure `commandSuggestions :: Text -> [(Text, Text)]` over the input text drives visibility; a single new `AppState` field (`asSuggestSel :: Int`) holds the highlight. `↑/↓` move the highlight, `Tab` completes, `Enter` runs the highlighted command (reusing the existing `dispatchCommand`). The `/help` overlay's command list is re-derived from one shared catalog (DRY).

**Tech Stack:** Haskell, GHC 9.6.6, Stack `lts-22.39`, hpack, `brick` 2.x, `hspec` + `QuickCheck`. Build is `-Wall -Werror` and must stay `hlint`-clean.

**Spec:** `docs/superpowers/specs/2026-06-05-slash-command-autocomplete-design.md`

---

## Conventions for the implementer

- Stack binary is at `~/.ghcup/bin/stack`. Build with:
  `~/.ghcup/bin/stack build --fast --test --no-run-tests` to compile lib+tests, and
  `~/.ghcup/bin/stack test --fast` to run the suite.
- Run a single spec file's `describe` with hspec match, e.g.
  `~/.ghcup/bin/stack test --fast --ta '-m "commandSuggestions"'`.
- Lint with `hlint src test` (must be clean — the repo treats hints as failures).
- The build is `-Wall -Werror`: an **unused import**, a **missing record field** in a
  record literal, or an incomplete pattern fails the build. When you add the
  `asSuggestSel` field (Task 3) you MUST update every `AppState` record literal in
  the same commit or the build breaks.
- Every commit message MUST end with this exact trailer line (own line, blank line before it):

  ```
  Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
  ```
- Commit directly to `main` (no feature branch).
- No `package.yaml`/`.cabal` change is needed: this plan adds **no new modules and no
  new dependencies** — all tests go into existing spec files, and `Tab`-completion uses
  brick's `editorText` (cursor already lands at end), not `text-zipper`.

## File structure (what changes and why)

| File | Responsibility | Change |
| --- | --- | --- |
| `src/OpenCode/TUI/Command.hs` | command parsing + the command catalog | add `commandCatalog`, `commandSuggestions`, `clampSel` (leaf module; imported by Overlay, Render, App) |
| `src/OpenCode/TUI/Overlay.hs` | pure overlay/help logic | derive `helpOverlay`'s command rows from `commandCatalog` (DRY) |
| `src/OpenCode/TUI/Types.hs` | `AppState` record | add `asSuggestSel :: Int` |
| `src/OpenCode/TUI/Render.hs` | brick draw functions | add `suggestBox`; insert it above the input box in `drawUI` |
| `src/OpenCode/TUI/App.hs` | event handling + pure reducers | add `applySuggestMove`/`applyComplete`/`highlightedCommand`; route `↑/↓/Tab/Enter` to the panel when active |
| `test/OpenCode/TUI/CommandSpec.hs` | `commandSuggestions`/`clampSel` tests | extend |
| `test/OpenCode/TUI/OverlaySpec.hs` | catalog/help consistency test | extend |
| `test/OpenCode/TUI/AppSpec.hs` | reducer tests + builder field | extend |
| `test/OpenCode/TUI/RenderSpec.hs` | panel render tests + builder field | extend |
| `README.md`, `MILESTONES.md` | docs | document autocomplete; record M13.1 |

Dependency edges added: `Render → Command` and `Overlay → Command`. `Command` imports only `Data.Text`, so it stays a leaf and no cycle is introduced.

---

## Task 1: Command catalog, suggestions, and clamp helper

**Files:**
- Modify: `src/OpenCode/TUI/Command.hs`
- Test: `test/OpenCode/TUI/CommandSpec.hs`

- [ ] **Step 1: Write the failing tests**

Add these to `test/OpenCode/TUI/CommandSpec.hs`. First extend the import:

```haskell
import OpenCode.TUI.Command (Command (..), parseCommand, commandSuggestions, clampSel)
```

Then append these `describe` blocks inside `spec` (after the existing `parseCommand` block — keep `spec` a single `do`):

```haskell
  describe "commandSuggestions" $ do
    it "lists every command for a bare slash, in catalog order" $
      map fst (commandSuggestions "/") `shouldBe`
        ["/new", "/sessions", "/model", "/help", "/quit"]

    it "filters by case-insensitive name prefix" $
      map fst (commandSuggestions "/se") `shouldBe` ["/sessions"]

    it "is case-insensitive on the typed prefix" $
      map fst (commandSuggestions "/SE") `shouldBe` ["/sessions"]

    it "tolerates leading whitespace" $
      map fst (commandSuggestions "  /m") `shouldBe` ["/model"]

    it "returns nothing for non-slash input" $
      commandSuggestions "hello" `shouldBe` []

    it "returns nothing for an unknown command" $
      commandSuggestions "/foo" `shouldBe` []

    it "pairs each match with its description" $
      lookup "/model" (commandSuggestions "/m")
        `shouldBe` Just "change model (this session)"

  describe "clampSel" $ do
    it "clamps a negative index to zero"      $ clampSel 3 (-5) `shouldBe` 0
    it "clamps an over-large index to n-1"    $ clampSel 3 99   `shouldBe` 2
    it "passes an in-range index through"      $ clampSel 3 1    `shouldBe` 1
    it "is zero for an empty list"             $ clampSel 0 4    `shouldBe` 0
```

The existing `parseCommand` block above must remain. (`describe` blocks compose in a `do`.)

- [ ] **Step 2: Run the tests to verify they fail**

Run: `~/.ghcup/bin/stack test --fast --ta '-m "commandSuggestions"'`
Expected: compile error — `commandSuggestions`/`clampSel` are not in scope / not exported.

- [ ] **Step 3: Implement the catalog, suggestions, and clamp**

Edit `src/OpenCode/TUI/Command.hs`. Replace the module header export list:

```haskell
module OpenCode.TUI.Command
  ( Command (..)
  , parseCommand
  , commandCatalog
  , commandSuggestions
  , clampSel
  ) where
```

Keep the existing imports (`Data.Text`, `qualified Data.Text as T`) and the existing `Command` type and `parseCommand` unchanged. Append at the end of the file:

```haskell
-- | Every slash command with its @\/name@ and a one-line description, in the
-- order they appear in the autocomplete panel and the help overlay. This is the
-- single source of truth for command names + descriptions.
commandCatalog :: [(Command, Text, Text)]
commandCatalog =
  [ (CmdNew,      "/new",      "start a new session")
  , (CmdSessions, "/sessions", "switch session")
  , (CmdModel,    "/model",    "change model (this session)")
  , (CmdHelp,     "/help",     "show help")
  , (CmdQuit,     "/quit",     "exit")
  ]

-- | Autocomplete matches for the current input line. Empty unless the trimmed
-- input begins with @\/@; otherwise the catalog rows whose @\/name@ has the typed
-- first token as a case-insensitive prefix.
--
-- @\/@ alone matches every command; @\/se@ matches @\/sessions@; @\/foo@ matches
-- nothing. Returns @(name, description)@ pairs in catalog order.
commandSuggestions :: Text -> [(Text, Text)]
commandSuggestions raw =
  case T.uncons trimmed of
    Just ('/', _) ->
      [ (name, desc)
      | (_, name, desc) <- commandCatalog
      , token `T.isPrefixOf` T.toLower name
      ]
    _ -> []
  where
    trimmed = T.strip raw
    token   = T.toLower firstWord
    firstWord = case T.words trimmed of
      (w:_) -> w
      []    -> ""

-- | Clamp a selection index into @[0, n-1]@ (0 when the list is empty).
clampSel :: Int -> Int -> Int
clampSel n i
  | n <= 0    = 0
  | i < 0     = 0
  | i >= n    = n - 1
  | otherwise = i
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `~/.ghcup/bin/stack test --fast --ta '-m "commandSuggestions"'` then
`~/.ghcup/bin/stack test --fast --ta '-m "clampSel"'`
Expected: PASS (all new examples green; existing `parseCommand` examples still pass).

- [ ] **Step 5: Lint**

Run: `hlint src/OpenCode/TUI/Command.hs test/OpenCode/TUI/CommandSpec.hs`
Expected: `No hints`.

- [ ] **Step 6: Commit**

```bash
git add src/OpenCode/TUI/Command.hs test/OpenCode/TUI/CommandSpec.hs
git commit -m "$(cat <<'EOF'
M13.1: command catalog + commandSuggestions + clampSel

Single source of truth for command name/description, a pure prefix-filter
for the autocomplete panel, and a selection-index clamp. Leaf module, fully
unit-tested.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Derive the help overlay's command rows from the catalog

**Files:**
- Modify: `src/OpenCode/TUI/Overlay.hs`
- Test: `test/OpenCode/TUI/OverlaySpec.hs`

- [ ] **Step 1: Write the failing test**

Add to `test/OpenCode/TUI/OverlaySpec.hs`. Extend the imports:

```haskell
import qualified Data.Text as T

import OpenCode.TUI.Overlay
  ( helpOverlay, modelsOverlay, overlayCount, overlayLabels, overlayMove
  , overlaySelected, sessionsOverlay )
import OpenCode.TUI.Command (commandCatalog)
```

(Keep the other existing imports.) Add this `describe` block inside `spec`:

```haskell
  describe "helpOverlay / catalog consistency" $
    it "lists every catalog command name in the help rows" $ do
      let rows  = overlayLabels (ovKind helpOverlay)
          names = [ n | (_, n, _) <- commandCatalog ]
      all (\n -> any (n `T.isInfixOf`) rows) names `shouldBe` True
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `~/.ghcup/bin/stack test --fast --ta '-m "catalog consistency"'`
Expected: compile error — `helpOverlay` / `commandCatalog` not imported (or, once imported, this passes only if help is derived; see Step 3).

- [ ] **Step 3: Derive `helpLines` from the catalog**

Edit `src/OpenCode/TUI/Overlay.hs`. Add the import (near the other `OpenCode.TUI.*` imports):

```haskell
import OpenCode.TUI.Command (commandCatalog)
```

Replace the existing `helpLines` definition with:

```haskell
helpLines :: [Text]
helpLines =
  "commands:" : map commandRow commandCatalog
    <> [ ""
       , "keys:"
       , "  Enter      send / confirm"
       , "  Esc        close overlay / abort run"
       , "  Up/Down    move selection / scroll"
       , "  Tab        complete the highlighted command"
       , "  Ctrl-C     quit"
       ]
  where
    commandRow (_, name, desc) = "  " <> T.justifyLeft 9 ' ' name <> "  " <> desc
```

(`:` is `infixr 5` and `<>` is `infixr 6`, so this parses as
`"commands:" : (map commandRow commandCatalog <> [...])` — the head consed onto
the rest, hlint-clean.)

(`T` is already imported as `qualified Data.Text as T` in this module.)

- [ ] **Step 4: Run the test to verify it passes**

Run: `~/.ghcup/bin/stack test --fast --ta '-m "catalog consistency"'`
Expected: PASS. Also run `~/.ghcup/bin/stack test --fast --ta '-m "overlayLabels"'` — the
existing Overlay tests still pass (they don't assert help text).

- [ ] **Step 5: Lint**

Run: `hlint src/OpenCode/TUI/Overlay.hs test/OpenCode/TUI/OverlaySpec.hs`
Expected: `No hints`.

- [ ] **Step 6: Commit**

```bash
git add src/OpenCode/TUI/Overlay.hs test/OpenCode/TUI/OverlaySpec.hs
git commit -m "$(cat <<'EOF'
M13.1: derive /help command rows from the shared command catalog

Help and autocomplete now read from one catalog so they cannot drift; adds a
Tab line to the help keys. Consistency test asserts every catalog name appears
in the help rows.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Add the `asSuggestSel` field to `AppState`

**Files:**
- Modify: `src/OpenCode/TUI/Types.hs`
- Modify: `src/OpenCode/TUI/App.hs:344-358` (`initialState`)
- Modify: `test/OpenCode/TUI/AppSpec.hs:236-251` (`stateWithInput`)
- Modify: `test/OpenCode/TUI/RenderSpec.hs:166-182` (`mkState`)
- Test: `test/OpenCode/TUI/AppSpec.hs` (assert default in `initialState` test)

- [ ] **Step 1: Write the failing assertion**

In `test/OpenCode/TUI/AppSpec.hs`, inside the existing `describe "initialState"` →
`it "loads the given history and starts Idle with an empty input"` block, add one line
at the end of that `it`:

```haskell
      asSuggestSel st `shouldBe` 0
```

- [ ] **Step 2: Run to verify it fails**

Run: `~/.ghcup/bin/stack test --fast --ta '-m "initialState"'`
Expected: compile error — `asSuggestSel` is not a field of `AppState`.

- [ ] **Step 3: Add the field and update every record literal**

Edit `src/OpenCode/TUI/Types.hs`. In the `AppState` record, add the field (after
`asNotice`), and extend the record's haddock to mention it:

```haskell
-- | The full UI state. 'asMode' drives the modal overlay; 'asNotice' is a
-- transient one-line status-bar message (block hint, model-set confirmation,
-- unknown-command); 'asSuggestSel' is the highlighted row of the non-modal
-- slash-command autocomplete panel (visibility is derived from the input text,
-- so only the index is stored). The event channel is reached via
-- @envEventChan asEnv@.
data AppState = AppState
  { asMessages         :: Seq Message
  , asInput            :: Editor Text ResourceName
  , asRunState         :: RunState
  , asStatusLine       :: Text
  , asPartialText      :: Text
  , asPartialReasoning :: Text
  , asRound            :: Maybe (Int, Int)
  , asTitle            :: Text
  , asEnv              :: AppEnv
  , asSessionId        :: SessionId
  , asMode             :: UIMode
  , asNotice           :: Maybe Text
  , asSuggestSel       :: Int
  }
```

Edit `src/OpenCode/TUI/App.hs` `initialState` (the record literal ending at line 358):
add `, asSuggestSel = 0` as the last field before the closing `}`:

```haskell
  , asMode             = ModeNormal
  , asNotice           = Nothing
  , asSuggestSel       = 0
  }
```

Edit `test/OpenCode/TUI/AppSpec.hs` `stateWithInput` (record literal ending ~line 251):
add the same field:

```haskell
    , asMode             = ModeNormal
    , asNotice           = Nothing
    , asSuggestSel       = 0
    }
```

Edit `test/OpenCode/TUI/RenderSpec.hs` `mkState` (record literal ending ~line 182):
add the same field:

```haskell
    , asMode             = ModeNormal
    , asNotice           = Nothing
    , asSuggestSel       = 0
    }
```

- [ ] **Step 4: Run to verify it passes (and nothing else broke)**

Run: `~/.ghcup/bin/stack build --fast --test --no-run-tests`
Expected: compiles clean (no `-Wmissing-fields` error). Then:
`~/.ghcup/bin/stack test --fast --ta '-m "initialState"'`
Expected: PASS.

- [ ] **Step 5: Lint**

Run: `hlint src/OpenCode/TUI/Types.hs src/OpenCode/TUI/App.hs`
Expected: `No hints`.

- [ ] **Step 6: Commit**

```bash
git add src/OpenCode/TUI/Types.hs src/OpenCode/TUI/App.hs \
        test/OpenCode/TUI/AppSpec.hs test/OpenCode/TUI/RenderSpec.hs
git commit -m "$(cat <<'EOF'
M13.1: add asSuggestSel field to AppState (autocomplete highlight)

Single new field for the autocomplete panel's highlighted row; panel
visibility stays derived from the input text. Updates initialState and the
two test builders; asserts the default is 0.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: Pure reducers — move highlight, complete, highlighted command

**Files:**
- Modify: `src/OpenCode/TUI/App.hs` (imports, exports, new pure functions)
- Test: `test/OpenCode/TUI/AppSpec.hs`

- [ ] **Step 1: Write the failing tests**

In `test/OpenCode/TUI/AppSpec.hs`, extend the App import to include the new reducers:

```haskell
import OpenCode.TUI.App
  ( appendUserMessage
  , applyComplete
  , applyEnter
  , applyEvent
  , applyModelSet
  , applySuggestMove
  , applySwitch
  , currentInput
  , initialState
  , modelLabel
  , shouldSubmit
  , startRun
  )
```

Add these `describe` blocks inside `spec`:

```haskell
  describe "applySuggestMove (autocomplete highlight)" $ do
    it "moves the highlight down within the match list" $ do
      st <- stateWithInput "/"          -- 5 matches
      asSuggestSel (applySuggestMove 1 st) `shouldBe` 1

    it "clamps the highlight at the bottom" $ do
      st <- stateWithInput "/"
      asSuggestSel (applySuggestMove 99 st) `shouldBe` 4

    it "clamps the highlight at the top" $ do
      st <- stateWithInput "/"
      asSuggestSel (applySuggestMove (-99) st) `shouldBe` 0

    it "is a no-op when no suggestions are showing" $ do
      st <- stateWithInput "hello"
      asSuggestSel (applySuggestMove 1 st) `shouldBe` 0

  describe "applyComplete (Tab completion)" $ do
    it "completes to the highlighted command and resets the highlight" $ do
      st0 <- stateWithInput "/se"
      let st1 = applyComplete st0
      currentInput st1 `shouldBe` "/sessions"
      asSuggestSel st1 `shouldBe` 0

    it "completes the row chosen with the arrows" $ do
      st0 <- stateWithInput "/"
      let st1 = applyComplete (applySuggestMove 2 st0)   -- 0:/new 1:/sessions 2:/model
      currentInput st1 `shouldBe` "/model"

    it "is a no-op when no suggestions are showing" $ do
      st <- stateWithInput "hello"
      currentInput (applyComplete st) `shouldBe` "hello"
```

- [ ] **Step 2: Run to verify it fails**

Run: `~/.ghcup/bin/stack test --fast --ta '-m "applySuggestMove"'`
Expected: compile error — `applySuggestMove`/`applyComplete` not in scope.

- [ ] **Step 3: Implement the reducers**

Edit `src/OpenCode/TUI/App.hs`.

Extend the `Command` import to pull in the new helpers:

```haskell
import OpenCode.TUI.Command (Command (..), parseCommand, commandSuggestions, clampSel)
```

Add the new functions to the module export list (in the "State helpers" group, next to `applySwitch`/`applyModelSet`):

```haskell
  , applySwitch
  , applyModelSet
  , applySuggestMove
  , applyComplete
  , highlightedCommand
```

Append these definitions near `applyModelSet` (after line 326):

```haskell
-- | The currently-highlighted command name, if the autocomplete panel is
-- showing for the current input. Total: 'clampSel' keeps the index in range
-- and 'safeIndex' guards the lookup.
highlightedCommand :: AppState -> Maybe Text
highlightedCommand st =
  case commandSuggestions (currentInput st) of
    [] -> Nothing
    xs -> fst <$> safeIndex xs (clampSel (length xs) (asSuggestSel st))

-- | Pure: move the autocomplete highlight by a delta, clamped to the current
-- match count. No-op when no suggestions are showing.
applySuggestMove :: Int -> AppState -> AppState
applySuggestMove delta st =
  st { asSuggestSel = clampSel n (asSuggestSel st + delta) }
  where n = length (commandSuggestions (currentInput st))

-- | Pure: complete the input to the highlighted command name (the rebuilt
-- editor's cursor lands at the end) and reset the highlight. No-op when no
-- suggestions are showing.
applyComplete :: AppState -> AppState
applyComplete st = case highlightedCommand st of
  Nothing   -> st
  Just name -> st
    { asInput      = E.editorText InputEditor (Just 1) name
    , asSuggestSel = 0
    }
```

Note: `safeIndex`, `currentInput`, and `emptyEditor` already exist in this module;
`E` is `Brick.Widgets.Edit`; `InputEditor` is in scope. No new imports beyond the
`Command` one above.

- [ ] **Step 4: Run to verify it passes**

Run: `~/.ghcup/bin/stack test --fast --ta '-m "applySuggestMove"'` then
`~/.ghcup/bin/stack test --fast --ta '-m "applyComplete"'`
Expected: PASS.

- [ ] **Step 5: Lint**

Run: `hlint src/OpenCode/TUI/App.hs test/OpenCode/TUI/AppSpec.hs`
Expected: `No hints`.

- [ ] **Step 6: Commit**

```bash
git add src/OpenCode/TUI/App.hs test/OpenCode/TUI/AppSpec.hs
git commit -m "$(cat <<'EOF'
M13.1: pure reducers for autocomplete highlight + Tab completion

applySuggestMove (clamped), applyComplete (rebuilds input to the highlighted
command, cursor at end), and highlightedCommand. All pure and unit-tested.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: Render the suggestion panel

**Files:**
- Modify: `src/OpenCode/TUI/Render.hs`
- Test: `test/OpenCode/TUI/RenderSpec.hs`

- [ ] **Step 1: Write the failing tests**

Add to `test/OpenCode/TUI/RenderSpec.hs` inside `spec`:

```haskell
  describe "command autocomplete panel" $ do

    it "hides the panel for non-command input" $ do
      st0 <- mkState []
      let st  = st0 { asInput = E.editorText InputEditor (Just 1) "hello" }
          pic = M.renderWidget Nothing (drawUI st) (80, 24)
      show pic `shouldNotContain` "switch session"

    it "shows matching commands when the line starts with '/'" $ do
      st0 <- mkState []
      let st  = st0 { asInput = E.editorText InputEditor (Just 1) "/se" }
          pic = M.renderWidget Nothing (drawUI st) (80, 24)
      show pic `shouldContain` "switch session"

    it "narrows the panel as more is typed" $ do
      st0 <- mkState []
      let st  = st0 { asInput = E.editorText InputEditor (Just 1) "/se" }
          pic = M.renderWidget Nothing (drawUI st) (80, 24)
      show pic `shouldNotContain` "start a new session"

    it "keeps a single layer in normal mode even when the panel shows" $ do
      st0 <- mkState []
      let st = st0 { asInput = E.editorText InputEditor (Just 1) "/" }
      length (drawUI st) `shouldBe` 1
```

- [ ] **Step 2: Run to verify it fails**

Run: `~/.ghcup/bin/stack test --fast --ta '-m "autocomplete panel"'`
Expected: FAIL — `show pic` does not contain `"switch session"` (panel not rendered yet).

- [ ] **Step 3: Implement `suggestBox` and wire it into `drawUI`**

Edit `src/OpenCode/TUI/Render.hs`.

Add `emptyWidget` to the `Brick` import list:

```haskell
import Brick
  ( Padding (Max, Pad)
  , Widget
  , emptyWidget
  , (<+>)
  , (<=>)
  )
```

Add an import of the suggestion helpers (with the other `OpenCode.TUI.*` imports):

```haskell
import OpenCode.TUI.Command (clampSel, commandSuggestions)
```

Change `drawUI` to insert the panel between the status bar and the input box:

```haskell
drawUI :: AppState -> [Widget ResourceName]
drawUI st = overlayLayer (asMode st)
  <> [chat <=> statusBar st <=> suggestBox st <=> inputBox st]
  where
```

(Keep the existing `where` bindings — `overlayLayer`, `chat`, `reasoningBlock`,
`partialBlock` — exactly as they are; only the list element changed.)

Add these definitions (place them just after the `renderOverlay` block, in the
"Overlay (modal picker)" area is fine, or in a new small section before the status
bar). The panel reuses the existing `statusAttr` highlight:

```haskell
-- ---------------------------------------------------------------------------
-- Slash-command autocomplete panel (non-modal; shown above the input)
-- ---------------------------------------------------------------------------

-- | A non-modal panel of slash-command suggestions, shown while the input line
-- begins with @\/@ and matches at least one command. 'Brick.emptyWidget' when
-- there are no matches. The row at 'asSuggestSel' (clamped) gets the highlight
-- bar (same look as overlay rows).
suggestBox :: AppState -> Widget ResourceName
suggestBox st =
  case commandSuggestions (currentInputText st) of
    [] -> emptyWidget
    xs ->
      B.borderWithLabel (txt " commands ") $
        hLimit 60 $
          vBox (zipWith renderRow [0 ..] xs)
      where
        sel = clampSel (length xs) (asSuggestSel st)
        renderRow :: Int -> (Text, Text) -> Widget ResourceName
        renderRow i (name, desc)
          | i == sel  = withAttr statusAttr (padRight Max (txt (rowText name desc)))
          | otherwise = padRight Max (txt (rowText name desc))
        rowText name desc = " " <> name <> "  " <> desc

-- | The input line as plain text. Mirrors 'OpenCode.TUI.App.currentInput',
-- duplicated here to avoid a Render → App import cycle.
currentInputText :: AppState -> Text
currentInputText = T.intercalate "\n" . E.getEditContents . asInput
```

Note: `B` (`Brick.Widgets.Border`), `hLimit`, `vBox`, `padRight`, `txt`,
`withAttr`, `statusAttr`, `Max`, and `E` (`Brick.Widgets.Edit`) are all already
imported in this module.

- [ ] **Step 4: Run to verify it passes**

Run: `~/.ghcup/bin/stack test --fast --ta '-m "autocomplete panel"'`
Expected: PASS. Then run the whole render group to confirm no regressions:
`~/.ghcup/bin/stack test --fast --ta '-m "drawUI"'`
Expected: PASS (including the existing "produces one layer in ModeNormal" test).

- [ ] **Step 5: Lint**

Run: `hlint src/OpenCode/TUI/Render.hs test/OpenCode/TUI/RenderSpec.hs`
Expected: `No hints`.

- [ ] **Step 6: Commit**

```bash
git add src/OpenCode/TUI/Render.hs test/OpenCode/TUI/RenderSpec.hs
git commit -m "$(cat <<'EOF'
M13.1: render the non-modal slash-command autocomplete panel

suggestBox sits above the input box, listing matching commands with
descriptions; the highlighted row uses the status highlight. Empty widget
when the line isn't a command, so the layout/layers are unchanged otherwise.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: Wire the keys (↑/↓ / Tab / Enter) into normal-mode handling

**Files:**
- Modify: `src/OpenCode/TUI/App.hs` (`handleNormal` and new helpers)

This task is integration glue. brick 2.x exposes no pure `EventM` runner, so the
key→action wiring itself cannot be unit-tested; correctness rests on the pure
reducers (Task 4) and render (Task 5) already under test, plus the manual smoke
check in Step 4. There is therefore no failing-test step here.

- [ ] **Step 1: Add the `modify` import**

In `src/OpenCode/TUI/App.hs`, extend the State import:

```haskell
import Control.Monad.State.Class (get, modify, put)
```

- [ ] **Step 2: Replace `handleNormal` and add the helper handlers**

Replace the entire current `handleNormal` definition (lines 164-174) with:

```haskell
-- | Normal-mode keys. Esc and page-scroll are unconditional. When the slash
-- autocomplete panel is active, Up/Down move the highlight, Tab completes, and
-- Enter runs the highlighted command; otherwise the keys keep their existing
-- meaning (Enter submits, Up/Down scroll, others edit the input).
handleNormal :: BrickEvent ResourceName SessionEvent -> EventM ResourceName AppState ()
handleNormal (VtyEvent (V.EvKey V.KEsc [])) = do
  st <- get
  liftIO (atomically (writeTVar (envAbort (asEnv st)) True))
handleNormal (VtyEvent (V.EvKey V.KPageUp   [])) = M.vScrollBy chatScroll (-pageStep)
handleNormal (VtyEvent (V.EvKey V.KPageDown [])) = M.vScrollBy chatScroll pageStep
handleNormal ev = do
  st <- get
  if suggestionsActive st
    then handleSuggest ev
    else handleEdit ev

-- | Whether the autocomplete panel is currently showing.
suggestionsActive :: AppState -> Bool
suggestionsActive = not . null . commandSuggestions . currentInput

-- | Keys while the autocomplete panel is open.
handleSuggest :: BrickEvent ResourceName SessionEvent -> EventM ResourceName AppState ()
handleSuggest = \case
  VtyEvent (V.EvKey V.KUp   [])        -> modify (applySuggestMove (-1))
  VtyEvent (V.EvKey V.KDown [])        -> modify (applySuggestMove 1)
  VtyEvent (V.EvKey (V.KChar '\t') []) -> modify applyComplete
  VtyEvent (V.EvKey V.KEnter [])       -> runHighlighted
  ev                                   -> editAndReset ev

-- | Normal editing keys when no panel is open (the pre-M13.1 behavior).
handleEdit :: BrickEvent ResourceName SessionEvent -> EventM ResourceName AppState ()
handleEdit = \case
  VtyEvent (V.EvKey V.KEnter [])     -> onEnter
  VtyEvent (V.EvKey V.KUp   [])      -> M.vScrollBy chatScroll (-lineStep)
  VtyEvent (V.EvKey V.KDown [])      -> M.vScrollBy chatScroll lineStep
  VtyEvent vev                       -> zoom inputL (E.handleEditorEvent (VtyEvent vev))
  _                                  -> pure ()

-- | Feed an editing key to the editor, then reset the highlight to the top (the
-- match set may have changed).
editAndReset :: BrickEvent ResourceName SessionEvent -> EventM ResourceName AppState ()
editAndReset ev = do
  case ev of
    VtyEvent vev -> zoom inputL (E.handleEditorEvent (VtyEvent vev))
    _            -> pure ()
  modify (\s -> s { asSuggestSel = 0 })

-- | Enter while the panel is open: run the highlighted command via the existing
-- dispatcher (so run-in-flight gating and notices are inherited). Falls back to
-- the normal submit path if, defensively, there is no highlight.
runHighlighted :: EventM ResourceName AppState ()
runHighlighted = do
  st <- get
  case highlightedCommand st of
    Nothing   -> onEnter
    Just name -> do
      put st { asInput = emptyEditor, asNotice = Nothing, asSuggestSel = 0 }
      maybe (pure ()) dispatchCommand (parseCommand name)
```

`onEnter`, `dispatchCommand`, `parseCommand`, `emptyEditor`, `currentInput`,
`commandSuggestions`, `applySuggestMove`, `applyComplete`, and `highlightedCommand`
are all in scope (defined earlier or imported in Tasks 1/4).

- [ ] **Step 3: Build and lint**

Run: `~/.ghcup/bin/stack build --fast --test --no-run-tests`
Expected: compiles clean under `-Wall -Werror`.
Run: `hlint src/OpenCode/TUI/App.hs`
Expected: `No hints`. (If hlint suggests merging the `case` in `editAndReset`,
apply the suggested form.)

- [ ] **Step 4: Manual smoke check**

Run: `OPENCODE_MOCK=1 ~/.ghcup/bin/stack run opencode-hs`
Verify by hand, then quit with Ctrl-C:
- Type `/` → a `commands` panel lists all five commands with descriptions.
- Type `se` (now `/se`) → panel narrows to `/sessions`.
- Press `↑`/`↓` (on `/` ) → the highlight bar moves and clamps at the ends.
- Press `Tab` → the input becomes the highlighted command (e.g. `/sessions`).
- Press `Enter` on a highlighted `/help` → the help overlay opens.
- Delete back to empty → the panel disappears; a normal prompt + `Enter` still streams a mock reply; `↑`/`↓` scroll the chat.

(If you cannot run an interactive terminal in this environment, state that the
manual check was not performed and rely on the automated suite + reducer/render
tests.)

- [ ] **Step 5: Run the full suite**

Run: `~/.ghcup/bin/stack test --fast`
Expected: all examples pass, 0 failures.

- [ ] **Step 6: Commit**

```bash
git add src/OpenCode/TUI/App.hs
git commit -m "$(cat <<'EOF'
M13.1: route Up/Down/Tab/Enter to the autocomplete panel when active

handleNormal now branches on whether the panel is showing: arrows move the
highlight, Tab completes, Enter runs the highlighted command via the existing
dispatcher (inheriting run-in-flight gating). All other keys edit the input and
reset the highlight; Esc and page-scroll are unchanged.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: Documentation (README + MILESTONES)

**Files:**
- Modify: `README.md` (the `## Slash commands` section, ~lines 128-142)
- Modify: `MILESTONES.md` (status-snapshot table + a new `## M13.1` subsection)

- [ ] **Step 1: Update the README**

In `README.md`, in the `## Slash commands` section, insert this paragraph
immediately **before** the line `Pickers are modal:`:

```markdown
**Autocomplete:** as soon as the input line begins with `/`, a panel lists the
matching commands with descriptions. Use `↑`/`↓` to highlight, `Tab` to complete
the highlighted command into the input, and `Enter` to run it. The panel
disappears when the line no longer starts with `/`.

```

- [ ] **Step 2: Update MILESTONES.md — snapshot row**

In the status-snapshot table, insert a new row directly **after** the `M13` row:

```markdown
| M13.1 | Slash-command autocomplete             | done      | `8f2e9b1..`        |
```

- [ ] **Step 3: Update MILESTONES.md — milestone subsection**

Insert this subsection immediately **after** the `## M13 — TUI interaction layer
(sub-project A) — DONE` section's acceptance bullets (i.e. directly before
`## M14 — MCP client (sub-project B) — PLANNED`):

```markdown
## M13.1 — Slash-command autocomplete — DONE

**Goal**: When the input line begins with `/`, show a live, keyboard-navigable
panel of matching commands (with descriptions) so command names need not be
memorized. An enhancement to M13; numbered M13.1 so M14/M15 numbering is
untouched.

### Scope

- **Non-modal panel**: shown above the input whenever the line starts with `/`
  and matches a command; derived purely from the input text (`commandSuggestions`).
- **Navigation**: `↑`/`↓` move the highlight, `Tab` completes the highlighted
  command into the input, `Enter` runs it via the existing dispatcher.
- **DRY**: the `/help` command list is re-derived from a single `commandCatalog`
  shared with the panel.

### Acceptance

- Typing `/` shows all five commands; typing more narrows by name prefix.
- `Tab` completes the highlighted command; `Enter` runs it (with the same
  run-in-flight gating as typing it out).
- The panel disappears once the line no longer starts with `/`; existing
  normal-mode behavior (scroll, submit, pickers) is unchanged otherwise.

```

- [ ] **Step 4: Verify docs build nothing / suite still green**

Run: `~/.ghcup/bin/stack test --fast`
Expected: all examples pass, 0 failures (docs don't affect the build, but confirm
the tree is green before committing).

- [ ] **Step 5: Commit**

```bash
git add README.md MILESTONES.md
git commit -m "$(cat <<'EOF'
M13.1: document slash-command autocomplete (README + MILESTONES)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Final verification (after all tasks)

- [ ] `~/.ghcup/bin/stack build --fast --test --no-run-tests` — clean under `-Wall -Werror`.
- [ ] `~/.ghcup/bin/stack test --fast` — all examples pass, 0 failures.
- [ ] `hlint src test` — `No hints`.
- [ ] `git log --oneline` shows the seven M13.1 commits on `main`.

## Spec coverage map

| Spec acceptance criterion | Task(s) |
| --- | --- |
| 1. `/` shows all five commands w/ descriptions | 1 (suggestions), 5 (render) |
| 2. Prefix-narrowing; `/foo` shows nothing | 1, 5 |
| 3. `↑`/`↓` move a clamped highlight | 4 (reducer), 6 (wiring) |
| 4. `Tab` completes, stays in edit mode | 4 (`applyComplete`), 6 |
| 5. `Enter` runs highlighted (incl. gating) | 6 (`runHighlighted` → `dispatchCommand`) |
| 6. Panel hides when line isn't a command | 1, 5 (`emptyWidget`) |
| 7. Existing normal-mode behavior unchanged | 6 (`handleEdit` branch), 5 (layer-count test) |
| DRY: help derived from catalog | 2 |
