# M13 — TUI Interaction Layer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add in-TUI slash commands, a session switcher, and per-session model switching, all through one reusable modal-overlay primitive — without restarting the process.

**Architecture:** A `UIMode` sum (`ModeNormal | ModeOverlay Overlay`) added to `AppState`; slash input is parsed by a pure `parseCommand`; pickers are pure `Overlay` values navigated by pure reducers and drawn as a brick layer. The agentic run is changed to honor the session's stored `ModelId` (so `/model` takes effect). Layering: `Types → Catalog → Overlay → Render → App`.

**Tech Stack:** Haskell (GHC 9.6.6, GHC2021), brick 2.x TUI, hspec + QuickCheck, sqlite-simple, hpack (`package.yaml`). Build is `-Wall -Werror`; lint is `hlint`.

**Spec:** `docs/superpowers/specs/2026-06-05-m13-tui-interaction-layer-design.md`

---

## Conventions for every task

- Build/test with stack: `stack build` and `stack test`. Filter tests with `stack test --test-arguments '--match "<pattern>"'`.
- The project is `-Werror`, so **unused imports fail the build**. When a task says to remove a function, remove any import that becomes unused.
- New library modules must be added to `package.yaml` under `library: exposed-modules:`; new test modules under `tests: ... other-modules:`. After editing `package.yaml`, the next `stack build`/`stack test` regenerates the cabal file (hpack runs automatically).
- Every commit message ends with the footer:
  ```
  Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
  ```
- Commit directly on `main`.

---

## File Structure

**New library modules**
- `src/OpenCode/Model/Catalog.hs` — curated model list, `availableModels`, and the shared `modelLabel`/`providerLabel`.
- `src/OpenCode/TUI/Command.hs` — `Command` type + pure `parseCommand`.
- `src/OpenCode/TUI/Overlay.hs` — pure overlay reducers, smart constructors, row labels (no brick).

**New test modules**
- `test/OpenCode/Model/CatalogSpec.hs`
- `test/OpenCode/TUI/CommandSpec.hs`
- `test/OpenCode/TUI/OverlaySpec.hs`

**Modified**
- `src/OpenCode/DB.hs` — add `updateSessionModel`.
- `src/OpenCode/Session.hs` — thread the session `ModelId` through the run path.
- `src/OpenCode/TUI/Types.hs` — `UIMode`/`Overlay`/`OverlayKind` + `asMode`/`asNotice`.
- `src/OpenCode/TUI/Render.hs` — `renderOverlay`, the notice line, overlay layering in `drawUI`.
- `src/OpenCode/TUI/App.hs` — event routing on `asMode`; slash dispatch; switch/new/model actions; re-export `modelLabel` from `Catalog`.
- `package.yaml` — register the new modules.
- Tests: `DBSpec.hs`, `SessionSpec.hs`, `ErrorPathSpec.hs`, `TUI/AppSpec.hs`, `TUI/RenderSpec.hs`.
- `MILESTONES.md`, `README.md` — status + docs (final task).

---

## Task 1: `DB.updateSessionModel`

**Files:**
- Modify: `src/OpenCode/DB.hs`
- Test: `test/OpenCode/DBSpec.hs`

- [ ] **Step 1: Write the failing test**

Add this `describe` block to `test/OpenCode/DBSpec.hs` inside `spec` (e.g. after the `createSchema` block):

```haskell
  describe "updateSessionModel" $
    it "overwrites a session's stored model" $
      withInMemoryDb $ \conn -> do
        now <- getCurrentTime
        let s = Session (SessionId "s-model") "t" (ModelId OpenAI "gpt-4o") now
        insertSession conn s
        updateSessionModel conn (SessionId "s-model")
          (ModelId Anthropic "claude-opus-4-5")
        loaded <- getSession conn (SessionId "s-model")
        fmap sessionModel loaded `shouldBe` Just (ModelId Anthropic "claude-opus-4-5")
```

(`getCurrentTime`, `Session`, `SessionId`, `ModelId`, `ProviderId`, `insertSession`, `getSession` are already imported in `DBSpec.hs`.)

- [ ] **Step 2: Run test to verify it fails**

Run: `stack test --test-arguments '--match "updateSessionModel"'`
Expected: compile error — `Variable not in scope: updateSessionModel`.

- [ ] **Step 3: Implement `updateSessionModel`**

In `src/OpenCode/DB.hs`, add to the export list right after `updateSessionTitle`:

```haskell
  , updateSessionModel
```

Add `ModelId` to the `OpenCode.Types` import list (currently it imports `Session (..)`, `SessionId (..)` but not `ModelId`):

```haskell
import OpenCode.Types
  ( Message (..)
  , MessageId (..)
  , MessagePart
  , ModelId
  , Role (..)
  , Session (..)
  , SessionId (..)
  )
```

Add the function right after `updateSessionTitle`:

```haskell
-- | Overwrite a session's model.
updateSessionModel :: Connection -> SessionId -> ModelId -> IO ()
updateSessionModel conn (SessionId sid) m = execute conn
  "UPDATE sessions SET model_id = ? WHERE id = ?"
  (encodeJsonText m, sid)
```

(`encodeJsonText` is already defined in this module — `insertSession` uses it to store `sessionModel`.)

- [ ] **Step 4: Run test to verify it passes**

Run: `stack test --test-arguments '--match "updateSessionModel"'`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/OpenCode/DB.hs test/OpenCode/DBSpec.hs
git commit -m "M13: DB.updateSessionModel — persist a session's model

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 2: Run path honors the session's model

The agentic run currently uses `Config.defaultModel` everywhere; `sessionModel` is written but never read. Thread the session's `ModelId` through `processUserMessage → processUserMessageWith → agentic → buildRequest`. Also fixes `run --session` resuming with the wrong model.

**Files:**
- Modify: `src/OpenCode/Session.hs`
- Test: `test/OpenCode/SessionSpec.hs`, `test/OpenCode/ErrorPathSpec.hs`

- [ ] **Step 1: Change the source signatures**

In `src/OpenCode/Session.hs`:

(a) Export `buildRequest` for testing — add to the export list under the `-- * Loop` group:

```haskell
  , agentic
  , buildRequest
  , maxToolRounds
```

(b) Change `buildRequest` (currently `:: AppEnv -> [Message] -> LLMRequest`) to take the model:

```haskell
buildRequest :: AppEnv -> ModelId -> [Message] -> LLMRequest
buildRequest env mdl history = LLMRequest
  { reqModel        = model mdl
  , reqMessages     = history
  , reqTools        = map someToolDefinition (Map.elems (unRegistry (envRegistry env)))
  , reqSystemPrompt = systemPrompt (envRegistry env)
  , reqMaxTokens    = Nothing
  }
```

(c) Change `agentic`'s signature and the `buildRequest` call inside it. The signature line:

```haskell
agentic :: Streamer -> ModelId -> SessionId -> [Message] -> AppM [Message]
agentic streamer mdl sid history = go 0 history []
```

and the request line inside `go` (was `let req = buildRequest env soFar`):

```haskell
          let req    = buildRequest env mdl soFar
```

(d) Change `processUserMessageWith`. Signature + remove the `mdl <- asks (...)` line (it now comes in as a parameter), and pass `mdl` to `agentic`:

```haskell
processUserMessageWith :: Streamer -> ModelId -> SessionId -> Text -> AppM ()
processUserMessageWith streamer mdl sid prompt = do
```

Inside it, **delete** this line:

```haskell
  mdl     <- asks (Config.defaultModel . envConfig)
```

and change the `agentic` call (was `_ <- agentic streamer sid history'`):

```haskell
  _        <- agentic streamer mdl sid history'
```

(e) Replace `processUserMessage` and delete the now-unused `selectStreamer`. Replace the whole `processUserMessage` definition and the `selectStreamer` helper below it with:

```haskell
processUserMessage :: SessionId -> Text -> AppM ()
processUserMessage sid prompt = do
  cfg      <- asks envConfig
  mSession <- loadSession sid
  let mdl = maybe (Config.defaultModel cfg) sessionModel mSession
  mock <- liftIO (lookupEnv "OPENCODE_MOCK")
  case mock of
    Just "1" ->
      processUserMessageWith (Mock.delayedStreamer mockChunkDelayUs mockReply) mdl sid prompt
    _ -> do
      streamer <- either throwError pure (streamerForProvider cfg (provider mdl))
      processUserMessageWith streamer mdl sid prompt
```

(`provider`, `sessionModel`, `ModelId` are already in scope via the module's `OpenCode.Types` import; `loadSession` is defined in this module.)

- [ ] **Step 2: Fix existing test call sites so the suite compiles**

In `test/OpenCode/SessionSpec.hs`:
- Add `buildRequest` to the `OpenCode.Session` import, and add an import of `reqModel`:

```haskell
import OpenCode.Session (agentic, buildRequest, createSession, loadSession, abortSession, processUserMessageWith, streamerForProvider)
import OpenCode.LLM.Types (LLMRequest (..), Streamer)
```

(the existing import is `import OpenCode.LLM.Types (Streamer)` — extend it to also bring `LLMRequest (..)`, which exports `reqModel`).

- Replace every occurrence of `agentic streamer (sessionId session)` with `agentic streamer (sessionModel session) (sessionId session)` (8 occurrences: lines ~87, 100, 113, 122, 130, 139, 151, 162, 179, 198, 220, 238, 283 — replace **all**).
- Replace the one `processUserMessageWith streamer (sessionId session) "hi there"` (line ~261) with `processUserMessageWith streamer (sessionModel session) (sessionId session) "hi there"`.

In `test/OpenCode/ErrorPathSpec.hs`, replace all three `processUserMessageWith streamer (sessionId session) <prompt>` calls (lines ~34, 50, 80) with `processUserMessageWith streamer (sessionModel session) (sessionId session) <prompt>`. (`sessionModel` is available via the existing `Session (..)` import.)

- [ ] **Step 3: Add the model-threading test**

Add to `test/OpenCode/SessionSpec.hs` inside `spec`:

```haskell
  describe "buildRequest (model threading)" $
    it "uses the supplied model, not the config default" $
      withTestEnv $ \env _session ->
        reqModel (buildRequest env (ModelId Anthropic "claude-opus-4-5") [])
          `shouldBe` ModelId Anthropic "claude-opus-4-5"
```

(The env's config default is `gpt-4o`, so asserting the Anthropic model proves the parameter — not the default — wins.)

- [ ] **Step 4: Run the full suite**

Run: `stack test`
Expected: PASS (all existing session/error-path tests still green; new `buildRequest` test passes).

- [ ] **Step 5: Commit**

```bash
git add src/OpenCode/Session.hs test/OpenCode/SessionSpec.hs test/OpenCode/ErrorPathSpec.hs
git commit -m "M13: run path honors the session's model (not config default)

Thread ModelId through processUserMessage -> processUserMessageWith ->
agentic -> buildRequest. Also fixes 'run --session' resuming with the
config default model instead of the session's stored model.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 3: `Model/Catalog.hs` + relocate `modelLabel`/`providerLabel`

**Files:**
- Create: `src/OpenCode/Model/Catalog.hs`
- Create: `test/OpenCode/Model/CatalogSpec.hs`
- Modify: `package.yaml`, `src/OpenCode/TUI/App.hs`

- [ ] **Step 1: Write the failing test**

Create `test/OpenCode/Model/CatalogSpec.hs`:

```haskell
module OpenCode.Model.CatalogSpec (spec) where

import Test.Hspec

import OpenCode.Config (ProviderConfig (..))
import OpenCode.Model.Catalog (availableModels, knownModels, modelLabel)
import OpenCode.Types (ApiKey (..), ModelId (..), ProviderId (..))

spec :: Spec
spec = do
  describe "modelLabel" $
    it "formats provider:model" $
      modelLabel (ModelId Anthropic "claude-opus-4-5")
        `shouldBe` "anthropic:claude-opus-4-5"

  describe "availableModels" $ do
    it "keeps only models whose provider has a key" $
      map provider (availableModels openaiOnly) `shouldBe` [OpenAI]

    it "is empty when no provider has a key" $
      availableModels noKeys `shouldBe` []

    it "never returns a model outside the known catalog" $
      all (`elem` knownModels) (availableModels allKeys) `shouldBe` True
  where
    openaiOnly = ProviderConfig (Just (ApiKey "k")) Nothing Nothing
    noKeys     = ProviderConfig Nothing Nothing Nothing
    allKeys    = ProviderConfig (Just (ApiKey "k")) (Just (ApiKey "k")) (Just (ApiKey "k"))
```

Register it in `package.yaml` under `tests: ... other-modules:` (keep the list alphabetical-ish; placement is not significant):

```yaml
      - OpenCode.Model.CatalogSpec
```

- [ ] **Step 2: Run test to verify it fails**

Run: `stack test --test-arguments '--match "Catalog"'`
Expected: compile error — `Could not find module 'OpenCode.Model.Catalog'`.

- [ ] **Step 3: Implement the catalog**

Create `src/OpenCode/Model/Catalog.hs`:

```haskell
-- | Static catalog of selectable models, plus shared provider/model labels.
--
-- The run path keys off each session's 'ModelId'; this module enumerates the
-- models a user may switch to (filtered to providers that actually have a key)
-- and centralizes the @provider:model@ label so the status bar and the model
-- picker format identically.
module OpenCode.Model.Catalog
  ( knownModels
  , availableModels
  , modelLabel
  , providerLabel
  ) where

import Data.Maybe (isJust)
import Data.Text (Text)

import OpenCode.Config (ProviderConfig (..))
import OpenCode.Types (ModelId (..), ProviderId (..))

-- | Curated set of models offered in the @/model@ picker. Extend by adding rows.
knownModels :: [ModelId]
knownModels =
  [ ModelId OpenAI    "gpt-4o"
  , ModelId Anthropic "claude-opus-4-5"
  , ModelId MiniMax   "MiniMax-M3"
  ]

-- | The subset of 'knownModels' whose provider has a key configured — you can't
-- run a model whose provider you have no credentials for.
availableModels :: ProviderConfig -> [ModelId]
availableModels pc = filter (hasKey . provider) knownModels
  where
    hasKey OpenAI    = isJust (openaiKey pc)
    hasKey Anthropic = isJust (anthropicKey pc)
    hasKey MiniMax   = isJust (minimaxKey pc)

-- | A human-readable @provider:model@ label (e.g. @openai:gpt-4o@).
modelLabel :: ModelId -> Text
modelLabel (ModelId p m) = providerLabel p <> ":" <> m

providerLabel :: ProviderId -> Text
providerLabel = \case
  OpenAI    -> "openai"
  Anthropic -> "anthropic"
  MiniMax   -> "minimax"
```

Register it in `package.yaml` under `library: ... exposed-modules:` (e.g. right after `- OpenCode.Types`):

```yaml
    - OpenCode.Model.Catalog
```

- [ ] **Step 4: Move `modelLabel`/`providerLabel` out of `App.hs`**

In `src/OpenCode/TUI/App.hs`:

(a) Add the import (near the other `OpenCode.*` imports):

```haskell
import OpenCode.Model.Catalog (modelLabel)
```

(b) Delete the local definitions at the bottom of the module:

```haskell
-- | A human-readable @provider:model@ label for the status bar.
modelLabel :: ModelId -> Text
modelLabel (ModelId p m) = providerLabel p <> ":" <> m

providerLabel :: ProviderId -> Text
providerLabel = \case
  OpenAI    -> "openai"
  Anthropic -> "anthropic"
  MiniMax   -> "minimax"
```

(c) `modelLabel` stays in `App.hs`'s **export list** (it now re-exports the imported one, so `AppSpec`'s `import OpenCode.TUI.App (modelLabel)` keeps working — do not remove it).

(d) Removing those functions makes `ModelId (..)` and `ProviderId (..)` unused in `App.hs`. Edit the `OpenCode.Types` import to drop them (this is required under `-Werror`):

```haskell
import OpenCode.Types
  ( Message (..)
  , MessageId (MessageId)
  , MessagePart (TextPart, ErrorPart)
  , Role (RoleUser, RoleAssistant)
  , Session (..)
  , SessionId
  )
```

- [ ] **Step 5: Run tests + build**

Run: `stack test --test-arguments '--match "Catalog"'` then `stack build`
Expected: Catalog tests PASS; `stack build` is clean (App still compiles, AppSpec's `modelLabel` test still resolves).

- [ ] **Step 6: Commit**

```bash
git add package.yaml src/OpenCode/Model/Catalog.hs test/OpenCode/Model/CatalogSpec.hs src/OpenCode/TUI/App.hs
git commit -m "M13: Model.Catalog (known/available models + shared modelLabel)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 4: `UIMode`/`Overlay`/`OverlayKind` + `asMode`/`asNotice`

Adding fields to `AppState` breaks every record constructor, so all constructors are updated in this one commit to keep the build green.

**Files:**
- Modify: `src/OpenCode/TUI/Types.hs`, `src/OpenCode/TUI/App.hs`
- Test: `test/OpenCode/TUI/AppSpec.hs`, `test/OpenCode/TUI/RenderSpec.hs`

- [ ] **Step 1: Write the failing test**

In `test/OpenCode/TUI/AppSpec.hs`, extend the existing `initialState` `it` block (lines ~106-114) with two assertions at the end:

```haskell
      asMode st `shouldBe` ModeNormal
      asNotice st `shouldBe` Nothing
```

and add `UIMode (..)` to its `OpenCode.TUI.Types` import:

```haskell
import OpenCode.TUI.Types (AppState (..), ResourceName (InputEditor), UIMode (..))
```

- [ ] **Step 2: Run test to verify it fails**

Run: `stack test --test-arguments '--match "initialState"'`
Expected: compile error — `asMode`/`asNotice`/`ModeNormal` not in scope.

- [ ] **Step 3: Add the types and fields**

Rewrite `src/OpenCode/TUI/Types.hs` to:

```haskell
-- | TUI state and resource names.
--
-- The streaming 'SessionEvent' type and 'RunState' live in
-- 'OpenCode.Session.Events'; this module re-exports them so callers can keep
-- 'OpenCode.TUI.Types' as a single import for everything UI-related.
module OpenCode.TUI.Types
  ( ResourceName (..)
  , AppState (..)
  , UIMode (..)
  , Overlay (..)
  , OverlayKind (..)
  , RunState (..)
  , SessionEvent (..)
  ) where

import Brick.Widgets.Edit (Editor)
import Data.Sequence (Seq)
import Data.Text (Text)

import OpenCode.App.Types (AppEnv)
import OpenCode.Session.Events (RunState (..), SessionEvent (..))
import OpenCode.Types (Message, ModelId, Session, SessionId)

-- ---------------------------------------------------------------------------
-- Resource names (used by brick to identify widgets / viewports)
-- ---------------------------------------------------------------------------

data ResourceName
  = ChatViewport
  | InputEditor
  | StatusBar
  deriving stock (Show, Eq, Ord)

-- ---------------------------------------------------------------------------
-- Overlay (modal picker) — pure data; logic in OpenCode.TUI.Overlay,
-- rendering in OpenCode.TUI.Render.
-- ---------------------------------------------------------------------------

data UIMode
  = ModeNormal
  | ModeOverlay Overlay
  deriving stock (Show, Eq)

data Overlay = Overlay
  { ovTitle :: Text
  , ovSel   :: Int            -- ^ selected row, clamped to [0, count-1]
  , ovKind  :: OverlayKind
  }
  deriving stock (Show, Eq)

data OverlayKind
  = OverlaySessions SessionId [Session]  -- ^ current id (for the * marker) + rows
  | OverlayModels   ModelId   [ModelId]  -- ^ current model (* marker + preselect) + rows
  | OverlayHelp     [Text]               -- ^ non-actionable lines
  deriving stock (Show, Eq)

-- ---------------------------------------------------------------------------
-- App state
-- ---------------------------------------------------------------------------

-- | The full UI state. 'asMode' drives the modal overlay; 'asNotice' is a
-- transient one-line status-bar message (block hint, model-set confirmation,
-- unknown-command). The event channel is reached via @envEventChan asEnv@.
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
  }
```

- [ ] **Step 4: Update every `AppState` constructor**

In `src/OpenCode/TUI/App.hs` `initialState` (the `AppState { ... }` record), add the two fields at the end:

```haskell
  , asSessionId        = sessionId session
  , asMode             = ModeNormal
  , asNotice           = Nothing
  }
```

and add `UIMode (..)` to App's `OpenCode.TUI.Types` import:

```haskell
import OpenCode.TUI.Types (AppState (..), ResourceName (..), UIMode (..))
```

In `test/OpenCode/TUI/AppSpec.hs` `stateWithInput` (the `AppState { ... }` record, lines ~210-221), add:

```haskell
    , asSessionId        = sessionId sampleSession
    , asMode             = ModeNormal
    , asNotice           = Nothing
    }
```

In `test/OpenCode/TUI/RenderSpec.hs` `mkState` (the `AppState { ... }` record, lines ~140-151), add:

```haskell
    , asSessionId        = sessionId sampleRenderSession
    , asMode             = ModeNormal
    , asNotice           = Nothing
    }
```

and add `UIMode (..)` to its `OpenCode.TUI.Types` import:

```haskell
import OpenCode.TUI.Types (AppState (..), ResourceName (InputEditor), UIMode (..))
```

- [ ] **Step 5: Run tests**

Run: `stack test`
Expected: PASS (build green; `initialState` test asserts `ModeNormal`/`Nothing`).

- [ ] **Step 6: Commit**

```bash
git add src/OpenCode/TUI/Types.hs src/OpenCode/TUI/App.hs test/OpenCode/TUI/AppSpec.hs test/OpenCode/TUI/RenderSpec.hs
git commit -m "M13: AppState gains UIMode overlay + asNotice fields

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 5: `TUI/Command.hs` — slash-command parsing

**Files:**
- Create: `src/OpenCode/TUI/Command.hs`
- Create: `test/OpenCode/TUI/CommandSpec.hs`
- Modify: `package.yaml`

- [ ] **Step 1: Write the failing test**

Create `test/OpenCode/TUI/CommandSpec.hs`:

```haskell
module OpenCode.TUI.CommandSpec (spec) where

import Test.Hspec

import OpenCode.TUI.Command (Command (..), parseCommand)

spec :: Spec
spec = describe "parseCommand" $ do
  it "treats non-slash input as a prompt (Nothing)" $
    parseCommand "hello world" `shouldBe` Nothing

  it "treats blank input as a prompt (Nothing)" $
    parseCommand "   " `shouldBe` Nothing

  it "parses each known command" $ do
    parseCommand "/new"      `shouldBe` Just CmdNew
    parseCommand "/sessions" `shouldBe` Just CmdSessions
    parseCommand "/model"    `shouldBe` Just CmdModel
    parseCommand "/help"     `shouldBe` Just CmdHelp
    parseCommand "/quit"     `shouldBe` Just CmdQuit

  it "is case-insensitive" $
    parseCommand "/MODEL" `shouldBe` Just CmdModel

  it "ignores surrounding whitespace" $
    parseCommand "   /help  " `shouldBe` Just CmdHelp

  it "ignores trailing arguments" $
    parseCommand "/model openai:gpt-4o" `shouldBe` Just CmdModel

  it "reports an unknown slash command (lower-cased first word)" $
    parseCommand "/Foo bar" `shouldBe` Just (CmdUnknown "/foo")
```

Register in `package.yaml` test `other-modules`:

```yaml
      - OpenCode.TUI.CommandSpec
```

- [ ] **Step 2: Run test to verify it fails**

Run: `stack test --test-arguments '--match "parseCommand"'`
Expected: compile error — `Could not find module 'OpenCode.TUI.Command'`.

- [ ] **Step 3: Implement the parser**

Create `src/OpenCode/TUI/Command.hs`:

```haskell
-- | Slash-command parsing for the TUI input line.
module OpenCode.TUI.Command
  ( Command (..)
  , parseCommand
  ) where

import Data.Text (Text)
import qualified Data.Text as T

-- | A recognized (or explicitly unknown) slash command typed at the input line.
data Command
  = CmdNew            -- ^ @/new@
  | CmdSessions       -- ^ @/sessions@
  | CmdModel          -- ^ @/model@
  | CmdHelp           -- ^ @/help@
  | CmdQuit           -- ^ @/quit@
  | CmdUnknown Text   -- ^ slash-prefixed but unrecognized (carries the word)
  deriving stock (Show, Eq)

-- | Parse an input line into a 'Command'.
--
--   * 'Nothing' — not slash-prefixed (after trimming): the caller treats it as
--     an LLM prompt.
--   * @Just cmd@ — a slash command. Matching is case-insensitive on the first
--     word; trailing arguments are ignored in M13.
parseCommand :: Text -> Maybe Command
parseCommand raw =
  case T.uncons trimmed of
    Just ('/', _) -> Just (classify firstWord)
    _             -> Nothing
  where
    trimmed   = T.strip raw
    firstWord = T.toLower (T.takeWhile (/= ' ') trimmed)
    classify w = case w of
      "/new"      -> CmdNew
      "/sessions" -> CmdSessions
      "/model"    -> CmdModel
      "/help"     -> CmdHelp
      "/quit"     -> CmdQuit
      other       -> CmdUnknown other
```

Register in `package.yaml` library `exposed-modules`:

```yaml
    - OpenCode.TUI.Command
```

- [ ] **Step 4: Run test to verify it passes**

Run: `stack test --test-arguments '--match "parseCommand"'`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add package.yaml src/OpenCode/TUI/Command.hs test/OpenCode/TUI/CommandSpec.hs
git commit -m "M13: TUI.Command — pure slash-command parser

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 6: `TUI/Overlay.hs` — pure overlay logic

**Files:**
- Create: `src/OpenCode/TUI/Overlay.hs`
- Create: `test/OpenCode/TUI/OverlaySpec.hs`
- Modify: `package.yaml`

- [ ] **Step 1: Write the failing test**

Create `test/OpenCode/TUI/OverlaySpec.hs`:

```haskell
module OpenCode.TUI.OverlaySpec (spec) where

import Data.Time (UTCTime (..), fromGregorian)
import Test.Hspec

import OpenCode.TUI.Overlay
  ( modelsOverlay, overlayCount, overlayLabels, overlayMove, overlaySelected
  , sessionsOverlay )
import OpenCode.TUI.Types (Overlay (..), OverlayKind (..))
import OpenCode.Types (ModelId (..), ProviderId (..), Session (..), SessionId (..))

spec :: Spec
spec = do
  describe "overlayMove (clamped navigation)" $ do
    let ov = modelsOverlay m1 [m1, m2, m3]   -- 3 rows, sel starts at 0

    it "moves down within bounds" $
      ovSel (overlayMove 1 ov) `shouldBe` 1

    it "clamps at the bottom" $
      ovSel (overlayMove 99 ov) `shouldBe` 2

    it "clamps at the top" $
      ovSel (overlayMove (-99) ov) `shouldBe` 0

    it "is a no-op on an empty overlay" $ do
      let empty = sessionsOverlay (SessionId "x") []
      ovSel (overlayMove 1 empty) `shouldBe` 0
      overlaySelected empty `shouldBe` Nothing

  describe "modelsOverlay" $
    it "preselects the current model" $
      ovSel (modelsOverlay m2 [m1, m2, m3]) `shouldBe` 1

  describe "overlayLabels" $ do
    it "marks the current model with a leading *" $
      overlayLabels (ovKind (modelsOverlay m2 [m1, m2]))
        `shouldBe` ["  openai:gpt-4o", "* anthropic:claude-opus-4-5"]

    it "marks the current session and counts rows" $ do
      let ov = sessionsOverlay (sessionId s2) [s1, s2]
      overlayCount (ovKind ov) `shouldBe` 2
      overlayLabels (ovKind ov) `shouldBe` ["  one", "* two"]
  where
    m1 = ModelId OpenAI "gpt-4o"
    m2 = ModelId Anthropic "claude-opus-4-5"
    m3 = ModelId MiniMax "MiniMax-M3"
    s1 = Session (SessionId "s1") "one" m1 t0
    s2 = Session (SessionId "s2") "two" m2 t0
    t0 = UTCTime (fromGregorian 2026 6 1) 0
```

Register in `package.yaml` test `other-modules`:

```yaml
      - OpenCode.TUI.OverlaySpec
```

- [ ] **Step 2: Run test to verify it fails**

Run: `stack test --test-arguments '--match "overlay"'`
Expected: compile error — `Could not find module 'OpenCode.TUI.Overlay'`.

- [ ] **Step 3: Implement the overlay logic**

Create `src/OpenCode/TUI/Overlay.hs`:

```haskell
-- | Pure logic for the TUI modal overlay (session / model / help pickers).
--
-- No brick, no IO: navigation, selection, smart constructors, and row labels
-- are pure so they can be unit-tested directly. Rendering lives in
-- 'OpenCode.TUI.Render' (it needs brick attrs).
module OpenCode.TUI.Overlay
  ( overlayCount
  , overlayMove
  , overlaySelected
  , overlayLabels
  , sessionsOverlay
  , modelsOverlay
  , helpOverlay
  ) where

import Data.List (elemIndex)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T

import OpenCode.Model.Catalog (modelLabel)
import OpenCode.TUI.Types (Overlay (..), OverlayKind (..))
import OpenCode.Types (ModelId, Session (..), SessionId)

-- | Number of selectable rows in an overlay kind.
overlayCount :: OverlayKind -> Int
overlayCount = \case
  OverlaySessions _ ss -> length ss
  OverlayModels   _ ms -> length ms
  OverlayHelp     ls   -> length ls

-- | Move the selection by a delta, clamped to @[0, count-1]@ (no-op if empty).
overlayMove :: Int -> Overlay -> Overlay
overlayMove delta ov = ov { ovSel = clamp (ovSel ov + delta) }
  where
    n = overlayCount (ovKind ov)
    clamp i
      | n <= 0    = 0
      | i < 0     = 0
      | i >= n    = n - 1
      | otherwise = i

-- | The selected row index, or 'Nothing' when the overlay has no rows.
overlaySelected :: Overlay -> Maybe Int
overlaySelected ov
  | overlayCount (ovKind ov) <= 0 = Nothing
  | otherwise                     = Just (ovSel ov)

-- | Display label per row, in payload order. The current session/model is
-- marked with a leading @* @; other rows get a @  @ pad so columns align.
overlayLabels :: OverlayKind -> [Text]
overlayLabels = \case
  OverlaySessions cur ss -> map (sessionRow cur) ss
  OverlayModels   cur ms -> map (modelRow cur) ms
  OverlayHelp     ls     -> ls
  where
    sessionRow cur s = marker (sessionId s == cur) <> titleOf s
    titleOf s
      | T.null (sessionTitle s) = "(untitled)"
      | otherwise               = sessionTitle s
    modelRow cur m = marker (m == cur) <> modelLabel m
    marker True  = "* "
    marker False = "  "

-- | A sessions overlay; current session marked, selection at the top.
sessionsOverlay :: SessionId -> [Session] -> Overlay
sessionsOverlay cur ss = Overlay
  { ovTitle = "sessions"
  , ovSel   = 0
  , ovKind  = OverlaySessions cur ss
  }

-- | A model overlay; selection starts on the current model if present.
modelsOverlay :: ModelId -> [ModelId] -> Overlay
modelsOverlay cur ms = Overlay
  { ovTitle = "model"
  , ovSel   = fromMaybe 0 (elemIndex cur ms)
  , ovKind  = OverlayModels cur ms
  }

-- | The static help overlay.
helpOverlay :: Overlay
helpOverlay = Overlay
  { ovTitle = "help"
  , ovSel   = 0
  , ovKind  = OverlayHelp helpLines
  }

helpLines :: [Text]
helpLines =
  [ "commands:"
  , "  /new       start a new session"
  , "  /sessions  switch session"
  , "  /model     change model (this session)"
  , "  /help      this help"
  , "  /quit      exit"
  , ""
  , "keys:"
  , "  Enter      send / confirm"
  , "  Esc        close overlay / abort run"
  , "  Up/Down    move selection / scroll"
  , "  Ctrl-C     quit"
  ]
```

Register in `package.yaml` library `exposed-modules`:

```yaml
    - OpenCode.TUI.Overlay
```

- [ ] **Step 4: Run test to verify it passes**

Run: `stack test --test-arguments '--match "overlay"'`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add package.yaml src/OpenCode/TUI/Overlay.hs test/OpenCode/TUI/OverlaySpec.hs
git commit -m "M13: TUI.Overlay — pure picker reducers + smart constructors

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 7: `Render` — draw the overlay + the notice line

**Files:**
- Modify: `src/OpenCode/TUI/Render.hs`
- Test: `test/OpenCode/TUI/RenderSpec.hs`

- [ ] **Step 1: Write the failing test**

In `test/OpenCode/TUI/RenderSpec.hs`, add new imports:

```haskell
import OpenCode.TUI.Overlay (helpOverlay, modelsOverlay)
import OpenCode.TUI.Types (AppState (..), ResourceName (InputEditor), UIMode (..))
```

(extend the existing `OpenCode.TUI.Types` import — added in Task 4 — to also bring nothing new beyond `UIMode (..)`, already present; add the `Overlay` import line above.)

Add this `describe` block inside `spec`:

```haskell
  describe "overlay layer" $ do

    it "renders the model overlay's rows over the chat" $ do
      st0 <- mkState []
      let ov  = modelsOverlay (ModelId OpenAI "gpt-4o")
                  [ModelId OpenAI "gpt-4o", ModelId Anthropic "claude-opus-4-5"]
          st  = st0 { asMode = ModeOverlay ov }
          pic = M.renderWidget Nothing (drawUI st) (80, 24)
      show pic `shouldContain` "claude-opus-4-5"

    it "renders the help overlay" $ do
      st0 <- mkState []
      let st  = st0 { asMode = ModeOverlay helpOverlay }
          pic = M.renderWidget Nothing (drawUI st) (80, 24)
      show pic `shouldContain` "commands:"

  describe "status-bar notice" $
    it "renders a transient notice" $ do
      st0 <- mkState []
      let st  = st0 { asNotice = Just "model set to anthropic:claude-opus-4-5" }
          pic = M.renderWidget Nothing (drawUI st) (80, 24)
      show pic `shouldContain` "model set to"
```

(`ModelId`/`ProviderId` are already imported in `RenderSpec.hs`.)

- [ ] **Step 2: Run test to verify it fails**

Run: `stack test --test-arguments '--match "overlay layer"'`
Expected: FAIL — the rendered picture does not contain `claude-opus-4-5` (overlay not drawn yet).

- [ ] **Step 3: Implement overlay + notice rendering**

In `src/OpenCode/TUI/Render.hs`:

(a) Add imports. Extend `Brick.Widgets.Core` to add `hLimit`, and add the center/overlay imports:

```haskell
import Brick.Widgets.Core
  ( hLimit
  , padLeft
  , padRight
  , str
  , txt
  , txtWrap
  , vBox
  , vLimit
  , viewport
  , withAttr
  )
import Brick.Widgets.Center (centerLayer)
import OpenCode.TUI.Overlay (overlayLabels)
import OpenCode.TUI.Types (AppState (..), Overlay (..), ResourceName (..), UIMode (..))
```

(replace the existing `OpenCode.TUI.Types (AppState (..), ResourceName (..))` import with the line above).

(b) Replace `drawUI` so the overlay is layered on top:

```haskell
-- | Top-level draw function passed to 'Brick.Main.App'. When an overlay is
-- open it is drawn as the first (top) layer over the chat.
drawUI :: AppState -> [Widget ResourceName]
drawUI st = overlayLayer (asMode st) <> [chat <=> statusBar st <=> inputBox st]
  where
    overlayLayer ModeNormal       = []
    overlayLayer (ModeOverlay ov) = [renderOverlay ov]
    chat =
      viewport ChatViewport Vertical $
        vBox (map renderMessage (toList (asMessages st)) <> reasoningBlock <> partialBlock)
    reasoningBlock
      | asRunState st /= Idle && not (T.null (asPartialReasoning st)) =
          [ withAttr streamingAttr (txt "💭 thinking")
              <=> padLeft (Pad 2) (withAttr streamingAttr (safeWrap (asPartialReasoning st)))
          ]
      | otherwise = []
    partialBlock
      | asRunState st /= Idle && not (T.null (asPartialText st)) =
          [ withAttr assistantAttr (txt (rolePrefix RoleAssistant))
              <=> padLeft (Pad 2) (withAttr streamingAttr (safeWrap (asPartialText st)))
          ]
      | otherwise = []
```

(c) Add the overlay renderer (place it after `drawUI`, before the status-bar section):

```haskell
-- ---------------------------------------------------------------------------
-- Overlay (modal picker)
-- ---------------------------------------------------------------------------

-- | Draw a centered, bordered picker. The selected row is shown with the
-- 'statusAttr' highlight bar. Pure data comes from 'OpenCode.TUI.Overlay'.
renderOverlay :: Overlay -> Widget ResourceName
renderOverlay ov =
  centerLayer $
    B.borderWithLabel (txt (" " <> ovTitle ov <> " ")) $
      hLimit 60 $
        vBox (zipWith renderRow [0 ..] (overlayLabels (ovKind ov)))
  where
    renderRow :: Int -> Text -> Widget ResourceName
    renderRow i label
      | i == ovSel ov = withAttr statusAttr (padRight Max (txt (" " <> label)))
      | otherwise     = padRight Max (txt (" " <> label))
```

(d) Add the notice to the status bar. Replace `statusBar`:

```haskell
statusBar :: AppState -> Widget ResourceName
statusBar st =
  withAttr statusAttr $
    vLimit 1 $
      padRight Max (txt (leftLabel st)) <+> txt (rightText st)

-- | Right-hand status segment: a transient notice when present, else the
-- run-state and round indicator.
rightText :: AppState -> Text
rightText st = case asNotice st of
  Just n  -> n
  Nothing -> runStateLabel (asRunState st) <> roundSuffix (asRound st)
```

(`renderOverlay` and `rightText` are module-internal; that's fine.)

- [ ] **Step 4: Run test to verify it passes**

Run: `stack test --test-arguments '--match "overlay layer"'` then `stack test --test-arguments '--match "notice"'`
Expected: PASS for both. Then run the existing render tests: `stack test --test-arguments '--match "drawUI"'` — still PASS.

- [ ] **Step 5: Commit**

```bash
git add src/OpenCode/TUI/Render.hs test/OpenCode/TUI/RenderSpec.hs
git commit -m "M13: render the modal overlay layer + status-bar notice

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 8: `App` — event routing, slash dispatch & actions

Wire it together: branch on `asMode`, parse slash commands, drive the overlay, and perform the switch/new/model actions. Pure transitions (`applySwitch`, `applyModelSet`) are unit-tested; IO is wrapped in `try` so a DB hiccup becomes a notice, not a crash.

**Files:**
- Modify: `src/OpenCode/TUI/App.hs`
- Test: `test/OpenCode/TUI/AppSpec.hs`

- [ ] **Step 1: Write the failing test**

In `test/OpenCode/TUI/AppSpec.hs`:

(a) Extend the `OpenCode.TUI.App` import to bring the two new pure helpers:

```haskell
import OpenCode.TUI.App
  ( appendUserMessage
  , applyEnter
  , applyEvent
  , applyModelSet
  , applySwitch
  , currentInput
  , initialState
  , modelLabel
  , shouldSubmit
  , startRun
  )
```

(b) Add these `describe` blocks inside `spec`:

```haskell
  describe "applySwitch (session switch reducer)" $
    it "replaces history/id/title/model and resets view state" $ do
      st0 <- stateWithInput "typing"
      let other = Session (SessionId "s-other") "Other Chat"
                    (ModelId Anthropic "claude-opus-4-5") t0
          st1 = (applyEvent (PartialText "draft") st0) { asRound = Just (2, 10) }
          st2 = applySwitch other [userMsg, userMsg] st1
      asSessionId st2 `shouldBe` SessionId "s-other"
      asTitle st2 `shouldBe` "Other Chat"
      asStatusLine st2 `shouldBe` "anthropic:claude-opus-4-5"
      Seq.length (asMessages st2) `shouldBe` 2
      asPartialText st2 `shouldBe` ""
      asRound st2 `shouldBe` Nothing
      asRunState st2 `shouldBe` Idle
      asMode st2 `shouldBe` ModeNormal

  describe "applyModelSet (model switch reducer)" $
    it "updates the status line and sets a confirmation notice" $ do
      st0 <- stateWithInput ""
      let st1 = applyModelSet (ModelId Anthropic "claude-opus-4-5") st0
      asStatusLine st1 `shouldBe` "anthropic:claude-opus-4-5"
      asNotice st1 `shouldBe` Just "model set to anthropic:claude-opus-4-5"
      asMode st1 `shouldBe` ModeNormal
```

(`Session (..)`, `SessionId (..)`, `ModelId (..)`, `ProviderId (..)`, `t0`, `userMsg` are already imported/defined in `AppSpec.hs`.)

- [ ] **Step 2: Run test to verify it fails**

Run: `stack test --test-arguments '--match "applySwitch"'`
Expected: compile error — `applySwitch`/`applyModelSet` not in scope.

- [ ] **Step 3: Update `App.hs` imports and exports**

In `src/OpenCode/TUI/App.hs`:

(a) Add to the **export list** (after `applyEvent`):

```haskell
  , applyEvent
  , applySwitch
  , applyModelSet
```

(b) Imports — add these lines alongside the existing imports:

```haskell
import OpenCode.App (runAppM, AppError)
import OpenCode.Config (Config (..))
import OpenCode.Model.Catalog (availableModels, modelLabel)
import OpenCode.Session (processUserMessage, createSession)
import OpenCode.TUI.Command (Command (..), parseCommand)
import OpenCode.TUI.Overlay
  ( helpOverlay, modelsOverlay, sessionsOverlay, overlayMove, overlaySelected )
```

Notes:
- `import OpenCode.App (runAppM)` already exists — **replace** it with the line above (adds `AppError`).
- `import OpenCode.Model.Catalog (modelLabel)` was added in Task 3 — **replace** it with the line above (adds `availableModels`).
- `import OpenCode.Session (processUserMessage)` already exists — **replace** it with the line above (adds `createSession`).

(c) Extend the `OpenCode.TUI.Types` import (currently `(AppState (..), ResourceName (..), UIMode (..))`) to add the overlay types:

```haskell
import OpenCode.TUI.Types
  ( AppState (..), ResourceName (..), UIMode (..), Overlay (..), OverlayKind (..) )
```

(d) Add `ModelId` back to the `OpenCode.Types` import (Task 3 removed it). The block becomes:

```haskell
import OpenCode.Types
  ( Message (..)
  , MessageId (MessageId)
  , MessagePart (TextPart, ErrorPart)
  , ModelId
  , Role (RoleUser, RoleAssistant)
  , Session (..)
  , SessionId
  )
```

- [ ] **Step 4: Replace the event-handling section**

Replace the entire `handleEvent` definition (and keep `lineStep`/`pageStep`/`chatScroll` as they are) with the following, and add the new helper functions below it:

```haskell
-- | Top-level event router. Ctrl-C always quits. Session events apply in any
-- mode. Otherwise dispatch on whether a modal overlay is open.
handleEvent :: BrickEvent ResourceName SessionEvent -> EventM ResourceName AppState ()
handleEvent (VtyEvent (V.EvKey (V.KChar 'c') [V.MCtrl])) = M.halt
handleEvent (AppEvent ev) = do
  st <- get
  put (applyEvent ev st)
  M.vScrollToEnd chatScroll
handleEvent ev = do
  st <- get
  case asMode st of
    ModeOverlay ov -> handleOverlay ov ev
    ModeNormal     -> handleNormal ev

-- | Normal-mode keys: Esc aborts a run, Enter parses commands or submits a
-- prompt, arrows/page scroll, everything else feeds the editor.
handleNormal :: BrickEvent ResourceName SessionEvent -> EventM ResourceName AppState ()
handleNormal (VtyEvent (V.EvKey V.KEsc [])) = do
  st <- get
  liftIO (atomically (writeTVar (envAbort (asEnv st)) True))
handleNormal (VtyEvent (V.EvKey V.KEnter []))     = onEnter
handleNormal (VtyEvent (V.EvKey V.KUp       []))  = M.vScrollBy chatScroll (-lineStep)
handleNormal (VtyEvent (V.EvKey V.KDown     []))  = M.vScrollBy chatScroll lineStep
handleNormal (VtyEvent (V.EvKey V.KPageUp   []))  = M.vScrollBy chatScroll (-pageStep)
handleNormal (VtyEvent (V.EvKey V.KPageDown []))  = M.vScrollBy chatScroll pageStep
handleNormal (VtyEvent ev) = zoom inputL (E.handleEditorEvent (VtyEvent ev))
handleNormal _ = pure ()

-- | The Enter action in normal mode: a slash command dispatches; anything else
-- is submitted to the LLM exactly as before.
onEnter :: EventM ResourceName AppState ()
onEnter = do
  st <- get
  let body = currentInput st
  case parseCommand body of
    Nothing ->
      when (asRunState st == Idle && shouldSubmit body) $ do
        msg <- liftIO (mkUserMessage body)
        put ((applyEnter msg st) { asRunState = RunningLLM, asNotice = Nothing })
        liftIO (startRun (asEnv st) (asSessionId st) body)
        M.vScrollToEnd chatScroll
    Just cmd -> do
      put st { asInput = emptyEditor, asNotice = Nothing }
      dispatchCommand cmd

-- | Run a slash command. Context-changing commands are blocked while a run is
-- in flight (with a notice); /help and /quit always work.
dispatchCommand :: Command -> EventM ResourceName AppState ()
dispatchCommand cmd = do
  st <- get
  case cmd of
    CmdHelp      -> put st { asMode = ModeOverlay helpOverlay }
    CmdQuit      -> M.halt
    CmdUnknown w -> put st { asNotice = Just ("unknown command: " <> w) }
    CmdNew       -> whenIdle st (openNew st)
    CmdSessions  -> whenIdle st (openSessions st)
    CmdModel     -> whenIdle st (openModel st)
  where
    whenIdle st act
      | asRunState st == Idle = act
      | otherwise             = put st { asNotice = Just "press Esc to abort the run first" }

-- | Overlay-mode keys: Esc closes, arrows move, Enter commits the selection.
handleOverlay :: Overlay -> BrickEvent ResourceName SessionEvent -> EventM ResourceName AppState ()
handleOverlay ov ev = case ev of
  VtyEvent (V.EvKey V.KEsc [])   -> closeOverlay
  VtyEvent (V.EvKey V.KUp [])    -> moveSel (-1)
  VtyEvent (V.EvKey V.KDown [])  -> moveSel 1
  VtyEvent (V.EvKey V.KEnter []) -> commitOverlay ov
  _                              -> pure ()
  where
    closeOverlay = do
      s <- get
      put s { asMode = ModeNormal }
    moveSel d = do
      s <- get
      case asMode s of
        ModeOverlay o -> put s { asMode = ModeOverlay (overlayMove d o) }
        ModeNormal    -> pure ()

-- | Perform the action for the currently-selected overlay row.
commitOverlay :: Overlay -> EventM ResourceName AppState ()
commitOverlay ov = do
  st <- get
  case overlaySelected ov of
    Nothing -> put st { asMode = ModeNormal }
    Just i  -> case ovKind ov of
      OverlayHelp _        -> put st { asMode = ModeNormal }
      OverlaySessions _ ss -> maybe (put st { asMode = ModeNormal })
                                    (\s -> switchTo s st { asNotice = Nothing })
                                    (safeIndex ss i)
      OverlayModels _ ms   -> maybe (put st { asMode = ModeNormal })
                                    (\m -> setModel m st)
                                    (safeIndex ms i)

-- | /new: create a session with the config default model and switch to it.
openNew :: AppState -> EventM ResourceName AppState ()
openNew st = do
  let env = asEnv st
      mdl = defaultModel (envConfig env)
  result <- liftIO (try (runAppM env (createSession mdl))
                      :: IO (Either SomeException (Either AppError Session)))
  case result of
    Right (Right s) -> switchTo s st { asNotice = Just "new session created" }
    Right (Left e)  -> put st { asNotice = Just ("error: " <> displayAppError e) }
    Left e          -> put st { asNotice = Just ("error: " <> T.pack (displayException e)) }

-- | /sessions: open a picker of all stored sessions.
openSessions :: AppState -> EventM ResourceName AppState ()
openSessions st = do
  result <- liftIO (try (DB.listSessions (envDb (asEnv st)))
                      :: IO (Either SomeException [Session]))
  case result of
    Left e   -> put st { asNotice = Just ("error: " <> T.pack (displayException e)) }
    Right ss -> put st { asMode = ModeOverlay (sessionsOverlay (asSessionId st) ss) }

-- | /model: open a picker of models for the configured providers.
openModel :: AppState -> EventM ResourceName AppState ()
openModel st = do
  let env = asEnv st
  result <- liftIO (try (DB.getSession (envDb env) (asSessionId st))
                      :: IO (Either SomeException (Maybe Session)))
  case result of
    Left e         -> put st { asNotice = Just ("error: " <> T.pack (displayException e)) }
    Right Nothing  -> put st { asNotice = Just "error: session not found" }
    Right (Just s) -> case availableModels (providers (envConfig env)) of
      [] -> put st { asNotice = Just "no models available" }
      ms -> put st { asMode = ModeOverlay (modelsOverlay (sessionModel s) ms) }

-- | Load a session's history and switch the UI to it.
switchTo :: Session -> AppState -> EventM ResourceName AppState ()
switchTo session st = do
  result <- liftIO (try (DB.getMessages (envDb (asEnv st)) (sessionId session))
                      :: IO (Either SomeException [Message]))
  case result of
    Left e     -> put st { asNotice = Just ("error: " <> T.pack (displayException e)) }
    Right msgs -> do
      put (applySwitch session msgs st)
      M.vScrollToEnd chatScroll

-- | Persist the chosen model to the session, then update the UI.
setModel :: ModelId -> AppState -> EventM ResourceName AppState ()
setModel mdl st = do
  result <- liftIO (try (DB.updateSessionModel (envDb (asEnv st)) (asSessionId st) mdl)
                      :: IO (Either SomeException ()))
  case result of
    Left e   -> put st { asMode = ModeNormal
                       , asNotice = Just ("error: " <> T.pack (displayException e)) }
    Right () -> put (applyModelSet mdl st)

-- | Total list indexing.
safeIndex :: [a] -> Int -> Maybe a
safeIndex xs i
  | i >= 0 && i < length xs = Just (xs !! i)
  | otherwise               = Nothing

-- | Pure: switch the UI to another session, resetting per-session view state.
-- Preserves env and notice; clears the input.
applySwitch :: Session -> [Message] -> AppState -> AppState
applySwitch session msgs st = st
  { asMessages         = Seq.fromList msgs
  , asInput            = emptyEditor
  , asSessionId        = sessionId session
  , asTitle            = sessionTitle session
  , asStatusLine       = modelLabel (sessionModel session)
  , asPartialText      = ""
  , asPartialReasoning = ""
  , asRound            = Nothing
  , asRunState         = Idle
  , asMode             = ModeNormal
  }

-- | Pure: apply a model switch (status line + confirmation notice + close).
applyModelSet :: ModelId -> AppState -> AppState
applyModelSet mdl st = st
  { asStatusLine = modelLabel mdl
  , asMode       = ModeNormal
  , asNotice     = Just ("model set to " <> modelLabel mdl)
  }
```

Note: `Seq.fromList` (from the existing `qualified Data.Sequence as Seq`), `try`/`SomeException`/`displayException` (already imported), `displayAppError` (already imported), and `DB.*` (via `qualified OpenCode.DB as DB`) are all already available.

- [ ] **Step 5: Run the new tests**

Run: `stack test --test-arguments '--match "applySwitch"'` and `stack test --test-arguments '--match "applyModelSet"'`
Expected: PASS.

- [ ] **Step 6: Build the whole project (catches -Werror issues)**

Run: `stack build`
Expected: clean — no warnings/errors. If an "unused import" fires, remove the offending import.

- [ ] **Step 7: Commit**

```bash
git add src/OpenCode/TUI/App.hs test/OpenCode/TUI/AppSpec.hs
git commit -m "M13: TUI event routing, slash dispatch, session/model actions

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 9: Integration — full suite, lint, smoke, docs

**Files:**
- Modify: `MILESTONES.md`, `README.md`

- [ ] **Step 1: Full clean build (-Werror)**

Run: `stack build`
Expected: clean.

- [ ] **Step 2: Full test suite**

Run: `stack test`
Expected: all green (including `CatalogSpec`, `CommandSpec`, `OverlaySpec`, extended `RenderSpec`/`AppSpec`, and the unchanged session/error-path suites).

- [ ] **Step 3: Lint**

Run: `hlint src test`
Expected: `No hints`. Apply any suggested fixes (or add a targeted `{-# ANN #-}`/`.hlint.yaml` ignore only if a hint is a false positive), then re-run `stack build`.

- [ ] **Step 4: Manual smoke test (interactive — TUI)**

Run: `OPENCODE_MOCK=1 stack run opencode-hs`

Verify by hand:
- `/help` then Enter → help overlay opens; `Esc` closes it; chat unchanged.
- `/model` then Enter → model picker opens with `*` on the current model; `↑/↓` moves; `Enter` shows "model set to …" in the status bar and updates the left label; `Esc` cancels with no change.
- `/sessions` then Enter → session picker; `Enter` switches (chat + title + model label change); `Esc` cancels.
- `/new` then Enter → empty chat, "new session created".
- Type a normal line + Enter → mock reply streams (commands not triggered).
- Type a prompt, while it streams type `/model` + Enter → "press Esc to abort the run first"; `/help` still opens.
- `/foo` + Enter → "unknown command: /foo".
- `/quit` → exits.

- [ ] **Step 5: Update docs**

In `README.md`, under the "TUI keys" section, add a slash-commands subsection:

```markdown
## Slash commands

Type these at the input line (Enter to run):

| Command     | Action                                                    |
|-------------|-----------------------------------------------------------|
| `/new`      | Start a new session and switch to it                      |
| `/sessions` | Open a picker to switch to another stored session         |
| `/model`    | Open a picker to change this session's model (persisted)  |
| `/help`     | Show keys and commands                                    |
| `/quit`     | Exit (same as Ctrl-C)                                     |

Pickers are modal: `↑/↓` to move, `Enter` to confirm, `Esc` to cancel.
Context-changing commands (`/new`, `/sessions`, `/model`) are disabled while a
run is streaming — press `Esc` to abort first.
```

In `MILESTONES.md`:
- Flip the M13 snapshot-table row from `planned` to `done` with the commit range.
- Change the `## M13 — TUI interaction layer` section status from `PLANNED` to `DONE` (mirror how M12 records its status).

- [ ] **Step 6: Commit**

```bash
git add MILESTONES.md README.md
git commit -m "M13: docs — slash commands in README, milestone status

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Self-Review (completed by plan author)

**Spec coverage:**
- Slash parsing/dispatch → Task 5 (`parseCommand`) + Task 8 (`dispatchCommand`). ✓
- Reusable modal overlay → Tasks 4 (types), 6 (logic), 7 (render). ✓
- `/sessions` switch → Task 8 (`openSessions`/`switchTo`/`applySwitch`). ✓
- `/new` → Task 8 (`openNew`). ✓
- `/model` persisted to session → Task 1 (`updateSessionModel`) + Task 8 (`setModel`/`applyModelSet`). ✓
- `/help`, `/quit`, unknown → Task 8 (`dispatchCommand`). ✓
- Run honors `sessionModel` → Task 2. ✓
- Block-until-idle + notice → Task 8 (`whenIdle`, `asNotice`) + Task 7 (render). ✓
- Esc disambiguation → Task 8 (`handleOverlay` Esc vs `handleNormal` Esc). ✓
- Model catalog filtered by keys → Task 3. ✓
- Graceful DB errors → Task 8 (`try` in every action). ✓
- Tests (Command/Overlay/Catalog/Render/App) → Tasks 1,3,5,6,7,8. ✓
- `-Werror`/hlint/full suite → Task 9. ✓

**Type consistency:** `Overlay`/`OverlayKind` constructors (`OverlaySessions SessionId [Session]`, `OverlayModels ModelId [ModelId]`, `OverlayHelp [Text]`) are defined once in Task 4 and used identically in Tasks 6/7/8. `parseCommand :: Text -> Maybe Command` and the `Command` constructors match between Tasks 5 and 8. `applySwitch :: Session -> [Message] -> AppState -> AppState` and `applyModelSet :: ModelId -> AppState -> AppState` match between their Task 8 definitions and the AppSpec tests. `buildRequest :: AppEnv -> ModelId -> [Message] -> LLMRequest` and `agentic :: Streamer -> ModelId -> SessionId -> [Message] -> AppM [Message]` are consistent across Task 2's source and test edits.

**Placeholder scan:** none — every code step contains complete code; every command has an expected result.
