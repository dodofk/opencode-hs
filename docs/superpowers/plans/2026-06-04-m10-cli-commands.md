# M10 — CLI Commands — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the stub entry point with an `optparse-applicative` driver exposing `run` / `list` / `export` / `config check`, while keeping bare `stack run` opening the TUI.

**Architecture:** A new pure library module `OpenCode.CLI` holds the command grammar plus the pure cores the test suite exercises directly (`parseModelId`, `renderSessionList`, `renderExportMarkdown`, and a testable `parseArgs`). All IO orchestration lives in `OpenCode.Run`: a shared `withAppEnv` builds config + DB + env once, and per-command runners (`runRun` / `runList` / `runExport` / `runConfigCheck`, with a streaming `runHeadless`) dispatch off the parsed `Command`. Provider selection is unified behind an exported `OpenCode.Session.streamerForProvider`.

**Tech Stack:** Haskell (GHC 9.6.6, lts-22.39), `optparse-applicative`, `conduit`/`resourcet`, `async`, `sqlite-simple`, `time`, `hspec`/`QuickCheck`.

**Reference spec:** `docs/superpowers/specs/2026-06-04-m10-cli-commands-design.md`

---

## File Structure

**Created (library):**
- `src/OpenCode/CLI.hs` — command grammar (`Command`, `RunOpts`), `parseModelId`, the optparse parser + `parseArgs`, and the pure renderers `renderSessionList` / `renderExportMarkdown`. Imports only `OpenCode.Types` + `optparse-applicative` + `time` — no IO, no cycle.

**Modified (library):**
- `src/OpenCode/Run.hs` — full rewrite: `withAppEnv`, command dispatch, `runRun`/`runList`/`runExport`/`runConfigCheck`/`runHeadless`, replacing the `getArgs` stub.
- `src/OpenCode/Session.hs` — extract/export `streamerForProvider`; redefine `selectStreamer` on top of it.
- `src/OpenCode/Config.hs` — export `defaultMiniMaxModel` (used by the config-check probe).

**Modified (executable / config):**
- `package.yaml` — add `OpenCode.CLI` to library `exposed-modules`; add `OpenCode.CLISpec` to test `other-modules`.
- `MILESTONES.md` — mark M10 done.

`app/Main.hs` is **unchanged** (`main = runApp defaultBuiltinRegistry`).

**Created (tests):**
- `test/OpenCode/CLISpec.hs` — `parseModelId`, `parseArgs`, `renderSessionList`, `renderExportMarkdown`.

**Modified (tests):**
- `test/OpenCode/SessionSpec.hs` — `streamerForProvider` cases.

The IO command runners in `OpenCode.Run` are thin glue over the separately-tested pure cores; they are verified by the manual acceptance commands in Task 7 (capturing stdout in unit tests would be contrived and brittle).

**Build/test commands used throughout:**
- Full build: `stack build`
- Full suite: `stack test`
- One group: `stack test --ta '--match "<pattern>"'`

---

## Task 1: `OpenCode.CLI` skeleton — `parseModelId` + command types

**Files:**
- Create: `src/OpenCode/CLI.hs`
- Create: `test/OpenCode/CLISpec.hs`
- Modify: `package.yaml`

- [ ] **Step 1: Create `src/OpenCode/CLI.hs`**

```haskell
-- | Pure CLI surface: the command grammar plus the pure parsers and renderers
-- the test suite exercises directly. All IO orchestration lives in
-- 'OpenCode.Run'; this module imports no IO and breaks no cycles.
module OpenCode.CLI
  ( Command (..)
  , RunOpts (..)
  , defaultRunOpts
  , parseModelId
  , providerLabel
  ) where

import Data.Text (Text)
import qualified Data.Text as T

import OpenCode.Types (ModelId (..), ProviderId (..), SessionId (..))

-- | A parsed top-level command.
data Command
  = Run RunOpts
  | List
  | Export SessionId
  | ConfigCheck
  deriving stock (Show, Eq)

-- | Options for the @run@ subcommand (and the bare-invocation default).
data RunOpts = RunOpts
  { roSession :: Maybe SessionId
  , roModel   :: Maybe ModelId
  , roPrompt  :: Maybe Text
  , roNoTui   :: Bool
  }
  deriving stock (Show, Eq)

defaultRunOpts :: RunOpts
defaultRunOpts = RunOpts Nothing Nothing Nothing False

-- | Render a provider id as its lowercase wire label.
providerLabel :: ProviderId -> Text
providerLabel = \case
  OpenAI    -> "openai"
  Anthropic -> "anthropic"
  MiniMax   -> "minimax"

-- | Parse a @provider:model@ string into a 'ModelId'. The provider must be one
-- of @openai@/@anthropic@/@minimax@ and the model part must be non-empty.
parseModelId :: Text -> Either Text ModelId
parseModelId raw =
  case T.breakOn ":" raw of
    (_, "")          -> Left ("expected provider:model, got: " <> raw)
    (provText, rest) ->
      let modelText = T.drop 1 rest
      in if T.null modelText
           then Left ("missing model in: " <> raw)
           else case providerFromText provText of
             Just p  -> Right (ModelId { provider = p, model = modelText })
             Nothing -> Left ("unknown provider: " <> provText)

providerFromText :: Text -> Maybe ProviderId
providerFromText = \case
  "openai"    -> Just OpenAI
  "anthropic" -> Just Anthropic
  "minimax"   -> Just MiniMax
  _           -> Nothing
```

- [ ] **Step 2: Register the new modules in `package.yaml`**

In `library: exposed-modules:`, add `OpenCode.CLI` right after `OpenCode.Run`:

```yaml
    - OpenCode.App
    - OpenCode.Run
    - OpenCode.CLI
```

In `tests: opencode-hs-test: other-modules:`, add `OpenCode.CLISpec` (keep the list alphabetical-ish — place after `OpenCode.ConfigSpec`):

```yaml
    other-modules:
      - OpenCode.CLISpec
      - OpenCode.ConfigSpec
```

- [ ] **Step 3: Write the failing `parseModelId` tests in `test/OpenCode/CLISpec.hs`**

```haskell
module OpenCode.CLISpec (spec) where

import Data.Either (isLeft)
import Test.Hspec

import OpenCode.CLI
import OpenCode.Types (ModelId (..), ProviderId (..))

spec :: Spec
spec =
  describe "parseModelId" $ do
    it "parses openai:gpt-4o" $
      parseModelId "openai:gpt-4o" `shouldBe` Right (ModelId OpenAI "gpt-4o")
    it "parses minimax:MiniMax-M3" $
      parseModelId "minimax:MiniMax-M3" `shouldBe` Right (ModelId MiniMax "MiniMax-M3")
    it "parses anthropic:claude-opus-4-5" $
      parseModelId "anthropic:claude-opus-4-5"
        `shouldBe` Right (ModelId Anthropic "claude-opus-4-5")
    it "rejects a string with no colon" $
      parseModelId "garbage" `shouldSatisfy` isLeft
    it "rejects an empty model part" $
      parseModelId "openai:" `shouldSatisfy` isLeft
    it "rejects an unknown provider" $
      parseModelId "weird:m" `shouldSatisfy` isLeft
```

- [ ] **Step 4: Run the tests — verify they FAIL (then pass on first build)**

Run:
```bash
stack test --ta '--match "parseModelId"'
```
Expected: the module compiles and the six `parseModelId` examples pass. (There is no prior `parseModelId` to fail against; the "red" here is purely "does it compile and is the logic right" — if any example fails, fix `parseModelId` before continuing.)

- [ ] **Step 5: Commit**

```bash
git add src/OpenCode/CLI.hs test/OpenCode/CLISpec.hs package.yaml
git commit -m "$(cat <<'EOF'
M10: OpenCode.CLI skeleton — command types + parseModelId

New pure CLI module: Command/RunOpts grammar, parseModelId (provider:model,
openai/anthropic/minimax), providerLabel. Registered as a library module and
a test module.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: optparse parser + testable `parseArgs`

**Files:**
- Modify: `src/OpenCode/CLI.hs`
- Test: `test/OpenCode/CLISpec.hs`

- [ ] **Step 1: Write the failing parser tests in `test/OpenCode/CLISpec.hs`**

Extend the imports:

```haskell
import OpenCode.Types (ModelId (..), ProviderId (..), SessionId (..))
```

(Replace the existing `OpenCode.Types` import line with the one above — it adds `SessionId (..)`.)

Change `spec` from a single `describe` into a `do` block and add the parser group:

```haskell
spec :: Spec
spec = do
  describe "parseModelId" $ do
    ... (the six existing examples, unchanged) ...

  describe "parseArgs (command grammar)" $ do
    it "parses no args as the default Run" $
      parseArgs [] `shouldBe` Just (Run defaultRunOpts)
    it "parses 'list'" $
      parseArgs ["list"] `shouldBe` Just List
    it "parses 'export <id>'" $
      parseArgs ["export", "abc"] `shouldBe` Just (Export (SessionId "abc"))
    it "parses 'config check'" $
      parseArgs ["config", "check"] `shouldBe` Just ConfigCheck
    it "parses run flags" $
      parseArgs ["run", "--no-tui", "--prompt", "hi", "--model", "openai:gpt-4o"]
        `shouldBe` Just (Run RunOpts
          { roSession = Nothing
          , roModel   = Just (ModelId OpenAI "gpt-4o")
          , roPrompt  = Just "hi"
          , roNoTui   = True
          })
    it "rejects an invalid --model" $
      parseArgs ["run", "--model", "garbage"] `shouldBe` Nothing
    it "rejects an unknown subcommand" $
      parseArgs ["frobnicate"] `shouldBe` Nothing
```

- [ ] **Step 2: Run the tests — verify they FAIL**

Run:
```bash
stack test --ta '--match "parseArgs"'
```
Expected: RED — compile error "Variable not in scope: parseArgs".

- [ ] **Step 3: Implement the parser in `src/OpenCode/CLI.hs`**

Add to the export list:

```haskell
  , commandParserInfo
  , parseArgs
```

Add the imports:

```haskell
import Data.Bifunctor (first)
import Options.Applicative
  ( Parser, ParserInfo, ReadM, command, defaultPrefs, eitherReader
  , execParserPure, fullDesc, getParseResult, header, help, helper, info
  , long, metavar, option, optional, progDesc, strArgument, strOption
  , subparser, switch, (<**>)
  )
```

Add the definitions:

```haskell
-- | Top-level parser info (program description + @--help@).
commandParserInfo :: ParserInfo Command
commandParserInfo = info (commandParser <**> helper)
  (fullDesc <> progDesc "A terminal AI coding agent" <> header "opencode-hs")

commandParser :: Parser Command
commandParser = subparser
  ( command "run"
      (info (Run <$> runOptsParser <**> helper)
            (progDesc "Start the TUI, or run a single prompt headless"))
 <> command "list"
      (info (pure List) (progDesc "List stored sessions"))
 <> command "export"
      (info (Export <$> sessionIdArg <**> helper)
            (progDesc "Export a session as Markdown to stdout"))
 <> command "config"
      (info (configParser <**> helper) (progDesc "Configuration commands"))
  )

configParser :: Parser Command
configParser = subparser
  ( command "check"
      (info (pure ConfigCheck) (progDesc "Probe each configured provider")) )

runOptsParser :: Parser RunOpts
runOptsParser = RunOpts
  <$> optional (SessionId <$> strOption
        (long "session" <> metavar "ID" <> help "Resume an existing session"))
  <*> optional (option modelReader
        (long "model" <> metavar "PROVIDER:MODEL" <> help "Model, e.g. openai:gpt-4o"))
  <*> optional (strOption
        (long "prompt" <> metavar "TEXT" <> help "Prompt to send (requires --no-tui)"))
  <*> switch (long "no-tui" <> help "Run headless: stream the reply to stdout")

modelReader :: ReadM ModelId
modelReader = eitherReader (first T.unpack . parseModelId . T.pack)

sessionIdArg :: Parser SessionId
sessionIdArg = SessionId <$> strArgument
  (metavar "SESSION_ID" <> help "Session id to export")

-- | Pure parse used by tests and by 'OpenCode.Run.runApp'. Empty args map to
-- the default Run (bare invocation → TUI); otherwise run the optparse grammar.
parseArgs :: [String] -> Maybe Command
parseArgs [] = Just (Run defaultRunOpts)
parseArgs as = getParseResult (execParserPure defaultPrefs commandParserInfo as)
```

- [ ] **Step 4: Run the tests — verify they PASS**

Run:
```bash
stack test --ta '--match "parseArgs"'
```
Expected: GREEN — all seven parser examples pass (default Run, list, export, config check, full run flags, invalid `--model` → `Nothing`, unknown subcommand → `Nothing`).

- [ ] **Step 5: Commit**

```bash
git add src/OpenCode/CLI.hs test/OpenCode/CLISpec.hs
git commit -m "$(cat <<'EOF'
M10: optparse command grammar + testable parseArgs

subparser for run/list/export/config check; run flags --session/--model/
--prompt/--no-tui; --model validated via parseModelId. parseArgs wraps
execParserPure ([] -> default Run) for unit testing without importing
Options.Applicative into the test suite.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: `renderSessionList`

**Files:**
- Modify: `src/OpenCode/CLI.hs`
- Test: `test/OpenCode/CLISpec.hs`

- [ ] **Step 1: Write the failing `renderSessionList` tests in `test/OpenCode/CLISpec.hs`**

Add imports:

```haskell
import qualified Data.Text as T
import Data.Time (UTCTime (..), fromGregorian)
import OpenCode.Types (ModelId (..), ProviderId (..), Session (..), SessionId (..))
```

(Merge `Session (..)` into the existing `OpenCode.Types` import; add the `Data.Text`/`Data.Time` imports.)

Add a `describe` group inside `spec`:

```haskell
  describe "renderSessionList" $ do
    it "renders one row per session with model labels and a header" $ do
      let out = renderSessionList [sess1, sess2]
      out `shouldSatisfy` T.isInfixOf "s-001"
      out `shouldSatisfy` T.isInfixOf "s-002"
      out `shouldSatisfy` T.isInfixOf "first"
      out `shouldSatisfy` T.isInfixOf "second"
      out `shouldSatisfy` T.isInfixOf "openai:gpt-4o"
      out `shouldSatisfy` T.isInfixOf "minimax:MiniMax-M3"
      out `shouldSatisfy` T.isInfixOf "ID"
    it "renders a placeholder for an empty list" $
      renderSessionList [] `shouldBe` "(no sessions)\n"
```

Add fixtures at the bottom of the file:

```haskell
t0 :: UTCTime
t0 = UTCTime (fromGregorian 2026 6 4) 0

sess1 :: Session
sess1 = Session (SessionId "s-001") "first" (ModelId OpenAI "gpt-4o") t0

sess2 :: Session
sess2 = Session (SessionId "s-002") "second" (ModelId MiniMax "MiniMax-M3") t0
```

- [ ] **Step 2: Run the tests — verify they FAIL**

Run:
```bash
stack test --ta '--match "renderSessionList"'
```
Expected: RED — compile error "Variable not in scope: renderSessionList".

- [ ] **Step 3: Implement `renderSessionList` in `src/OpenCode/CLI.hs`**

Add to the export list:

```haskell
  , renderSessionList
```

Add imports:

```haskell
import Data.Time (UTCTime)
import Data.Time.Format (defaultTimeLocale, formatTime)
import OpenCode.Types (ModelId (..), ProviderId (..), Session (..), SessionId (..))
```

(Merge `Session (..)` into the existing `OpenCode.Types` import line; add the two `Data.Time*` imports.)

Add the definitions:

```haskell
-- | A fixed-width table of sessions: @ID  TITLE  MODEL  CREATED@.
renderSessionList :: [Session] -> Text
renderSessionList [] = "(no sessions)\n"
renderSessionList sessions = T.unlines (headerRow : map row sessions)
  where
    idW    = colWidth "ID"    (unSessionId . sessionId)
    titleW = colWidth "TITLE" sessionTitle
    modelW = colWidth "MODEL" (modelText . sessionModel)
    colWidth h f = maximum (T.length h : map (T.length . f) sessions)
    headerRow = rowCells "ID" "TITLE" "MODEL" "CREATED"
    row s = rowCells (unSessionId (sessionId s)) (sessionTitle s)
                     (modelText (sessionModel s)) (createdText (sessionCreated s))
    rowCells a b c d =
      pad idW a <> "  " <> pad titleW b <> "  " <> pad modelW c <> "  " <> d
    pad w t = t <> T.replicate (max 0 (w - T.length t)) " "

modelText :: ModelId -> Text
modelText m = providerLabel (provider m) <> ":" <> model m

createdText :: UTCTime -> Text
createdText = T.pack . formatTime defaultTimeLocale "%Y-%m-%d %H:%M"
```

- [ ] **Step 4: Run the tests — verify they PASS**

Run:
```bash
stack test --ta '--match "renderSessionList"'
```
Expected: GREEN — both examples pass.

- [ ] **Step 5: Commit**

```bash
git add src/OpenCode/CLI.hs test/OpenCode/CLISpec.hs
git commit -m "$(cat <<'EOF'
M10: renderSessionList — fixed-width session table

Pure renderer: ID/TITLE/MODEL/CREATED columns padded to width, model shown
as provider:model, created via formatTime; "(no sessions)" for empty.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: `renderExportMarkdown`

**Files:**
- Modify: `src/OpenCode/CLI.hs`
- Test: `test/OpenCode/CLISpec.hs`

- [ ] **Step 1: Write the failing `renderExportMarkdown` tests in `test/OpenCode/CLISpec.hs`**

Add imports:

```haskell
import Data.List.NonEmpty (NonEmpty ((:|)))
import OpenCode.Types
  ( Message (..), MessageId (..), MessagePart (..), ModelId (..), ProviderId (..)
  , Role (..), Session (..), SessionId (..), ToolArgs (..), ToolCall (..)
  , ToolResult (..)
  )
```

(Replace the existing `OpenCode.Types` import with the wider one above; add the `Data.List.NonEmpty` import.)

Add a `describe` group inside `spec`:

```haskell
  describe "renderExportMarkdown" $
    it "renders metadata, role headings, and fenced tool blocks" $ do
      let md = renderExportMarkdown sess1 [userMsg, assistantMsg]
      md `shouldSatisfy` T.isInfixOf "# first"
      md `shouldSatisfy` T.isInfixOf "**ID:** s-001"
      md `shouldSatisfy` T.isInfixOf "**Model:** openai:gpt-4o"
      md `shouldSatisfy` T.isInfixOf "## User"
      md `shouldSatisfy` T.isInfixOf "## Assistant"
      md `shouldSatisfy` T.isInfixOf "hello"
      md `shouldSatisfy` T.isInfixOf "```bash"
      md `shouldSatisfy` T.isInfixOf "```result"
      md `shouldSatisfy` T.isInfixOf "file.txt"
```

Add fixtures at the bottom of the file:

```haskell
userMsg :: Message
userMsg = Message (MessageId "m1") RoleUser (TextPart "hello" :| []) t0

assistantMsg :: Message
assistantMsg = Message (MessageId "m2") RoleAssistant
  ( ToolCallPart (ToolCall "c1" "bash" (ToolArgs "{\"command\":\"ls\"}"))
    :| [ ToolResultPart (ToolResult "c1" "file.txt" False) ] ) t0
```

- [ ] **Step 2: Run the tests — verify they FAIL**

Run:
```bash
stack test --ta '--match "renderExportMarkdown"'
```
Expected: RED — compile error "Variable not in scope: renderExportMarkdown".

- [ ] **Step 3: Implement `renderExportMarkdown` in `src/OpenCode/CLI.hs`**

Add to the export list:

```haskell
  , renderExportMarkdown
```

Add imports:

```haskell
import qualified Data.List.NonEmpty as NE
import OpenCode.Types
  ( Message (..), MessagePart (..), ModelId (..), ProviderId (..), Role (..)
  , Session (..), SessionId (..), ToolArgs (..), ToolCall (..), ToolResult (..)
  )
```

(Merge the new names — `Message (..)`, `MessagePart (..)`, `Role (..)`, `ToolArgs (..)`, `ToolCall (..)`, `ToolResult (..)` — into the existing `OpenCode.Types` import; add the `Data.List.NonEmpty` qualified import.)

Add the definitions:

```haskell
-- | Render a session and its messages as Markdown: a title + metadata block,
-- then one @##@ section per message with text, fenced tool calls/results, and
-- blockquoted errors.
renderExportMarkdown :: Session -> [Message] -> Text
renderExportMarkdown s msgs = T.unlines $
  [ "# " <> sessionTitle s
  , ""
  , "- **ID:** " <> unSessionId (sessionId s)
  , "- **Model:** " <> modelText (sessionModel s)
  , "- **Created:** " <> createdText (sessionCreated s)
  , ""
  ] <> concatMap renderMessageMd msgs

renderMessageMd :: Message -> [Text]
renderMessageMd m =
  ("## " <> roleHeading (msgRole m))
  : ""
  : (concatMap renderPartMd (NE.toList (msgParts m)) <> [""])

roleHeading :: Role -> Text
roleHeading = \case
  RoleUser      -> "User"
  RoleAssistant -> "Assistant"
  RoleTool      -> "Tool"

renderPartMd :: MessagePart -> [Text]
renderPartMd = \case
  TextPart t        -> [t, ""]
  ToolCallPart tc   -> ["```" <> toolName tc, unToolArgs (arguments tc), "```", ""]
  ToolResultPart tr -> ["```result", content tr, "```", ""]
  ErrorPart e       -> ["> ⚠ " <> e, ""]
```

- [ ] **Step 4: Run the tests — verify they PASS**

Run:
```bash
stack test --ta '--match "renderExportMarkdown"'
```
Expected: GREEN — the export example passes.

- [ ] **Step 5: Commit**

```bash
git add src/OpenCode/CLI.hs test/OpenCode/CLISpec.hs
git commit -m "$(cat <<'EOF'
M10: renderExportMarkdown — session to Markdown

Pure renderer: # title + ID/Model/Created metadata, ## role sections, text
prose, fenced tool-call (```<tool>) and result (```result) blocks, and
blockquoted errors.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: `streamerForProvider` refactor in `OpenCode.Session`

**Files:**
- Modify: `src/OpenCode/Session.hs`
- Test: `test/OpenCode/SessionSpec.hs`

- [ ] **Step 1: Write the failing `streamerForProvider` tests in `test/OpenCode/SessionSpec.hs`**

Add imports:

```haskell
import Data.Either (isLeft, isRight)
import OpenCode.Config (Config (..), ProviderConfig (..))
import OpenCode.Session (streamerForProvider)
import OpenCode.Types (ApiKey (..), ModelId (..), ProviderId (..))
```

(Merge `streamerForProvider` into the existing `OpenCode.Session` import; merge `ApiKey (..)`/`ModelId (..)`/`ProviderId (..)` into the existing `OpenCode.Types` import; add the `Data.Either` and `OpenCode.Config` imports if not already present.)

Add a `describe` block:

```haskell
  describe "streamerForProvider" $ do
    it "returns a streamer when the OpenAI key is present" $
      isRight (streamerForProvider (cfgWith (Just (ApiKey "k")) Nothing) OpenAI)
        `shouldBe` True
    it "fails when the OpenAI key is absent" $
      isLeft (streamerForProvider (cfgWith Nothing Nothing) OpenAI) `shouldBe` True
    it "returns a streamer when the MiniMax key is present" $
      isRight (streamerForProvider (cfgWith Nothing (Just (ApiKey "k"))) MiniMax)
        `shouldBe` True
    it "fails for Anthropic (not yet implemented)" $
      isLeft (streamerForProvider (cfgWith (Just (ApiKey "k")) Nothing) Anthropic)
        `shouldBe` True
```

Add a fixture helper at the bottom of the file:

```haskell
cfgWith :: Maybe ApiKey -> Maybe ApiKey -> Config
cfgWith oa mm = Config
  { providers    = ProviderConfig
      { openaiKey = oa, anthropicKey = Nothing, minimaxKey = mm }
  , defaultModel = ModelId OpenAI "gpt-4o"
  }
```

- [ ] **Step 2: Run the tests — verify they FAIL**

Run:
```bash
stack test --ta '--match "streamerForProvider"'
```
Expected: RED — compile error "Variable not in scope: streamerForProvider" (it is not yet exported).

- [ ] **Step 3: Refactor `selectStreamer` in `src/OpenCode/Session.hs`**

Add `streamerForProvider` to the module export list (next to `processUserMessage` / under a `-- * Provider selection` heading or alongside the existing exports):

```haskell
    -- * Provider selection
  , streamerForProvider
```

Replace the existing `selectStreamer` definition:

```haskell
selectStreamer :: Config.Config -> Either AppError Streamer
selectStreamer cfg =
  case provider (Config.defaultModel cfg) of
    OpenAI    -> withKey (Config.openaiKey  pc) "OpenAI"  OpenAI.defaultOpenAI
    MiniMax   -> withKey (Config.minimaxKey pc) "MiniMax" OpenAI.minimaxOpenAI
    Anthropic -> Left (LLMError
      "Anthropic streaming is not yet implemented; configure a MiniMax or OpenAI model")
  where
    pc = Config.providers cfg
    withKey mKey label mkProvider = case mKey of
      Nothing  -> Left (LLMError ("no " <> label <> " API key configured"))
      Just key -> Right (OpenAI.streamOpenAI (mkProvider key))
```

with:

```haskell
-- | Pick a streaming provider for the configured default model. Thin wrapper
-- over 'streamerForProvider'.
selectStreamer :: Config.Config -> Either AppError Streamer
selectStreamer cfg = streamerForProvider cfg (provider (Config.defaultModel cfg))

-- | Pick a streamer for a specific provider id, given the configured keys.
-- MiniMax and OpenAI share the OpenAI-compatible wire format and differ only in
-- base URL, so both go through 'OpenAI.streamOpenAI'. The Anthropic path is not
-- yet implemented. Exported so @config check@ can probe a provider other than
-- the default model's.
streamerForProvider :: Config.Config -> ProviderId -> Either AppError Streamer
streamerForProvider cfg pid =
  case pid of
    OpenAI    -> withKey (Config.openaiKey  pc) "OpenAI"  OpenAI.defaultOpenAI
    MiniMax   -> withKey (Config.minimaxKey pc) "MiniMax" OpenAI.minimaxOpenAI
    Anthropic -> Left (LLMError
      "Anthropic streaming is not yet implemented; configure a MiniMax or OpenAI model")
  where
    pc = Config.providers cfg
    withKey mKey label mkProvider = case mKey of
      Nothing  -> Left (LLMError ("no " <> label <> " API key configured"))
      Just key -> Right (OpenAI.streamOpenAI (mkProvider key))
```

(`ProviderId` is already in scope in `Session.hs` via the existing `OpenCode.Types` import that brings in `ProviderId (..)`.)

- [ ] **Step 4: Run the tests — verify they PASS**

Run:
```bash
stack test --ta '--match "streamerForProvider"'
```
Expected: GREEN — all four cases pass (`selectStreamer`'s behavior is unchanged, so existing session tests stay green too).

- [ ] **Step 5: Commit**

```bash
git add src/OpenCode/Session.hs test/OpenCode/SessionSpec.hs
git commit -m "$(cat <<'EOF'
M10: export streamerForProvider; selectStreamer wraps it

Generalize provider dispatch to any ProviderId so config check can probe a
provider other than the default model's. selectStreamer is now a thin
wrapper; behavior unchanged.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: `OpenCode.Run` — env wiring + command runners + dispatch

**Files:**
- Modify: `src/OpenCode/Config.hs` (export `defaultMiniMaxModel`)
- Modify: `src/OpenCode/Run.hs` (full rewrite)

This task has no new unit tests: the runners are thin IO glue over the pure cores tested in Tasks 1–4, and are verified by the acceptance commands in Task 7. Each step keeps the build green.

- [ ] **Step 1: Export `defaultMiniMaxModel` from `src/OpenCode/Config.hs`**

In the `OpenCode.Config` export list, under `-- * Pure assembly (exported for white-box testing)`, add `defaultMiniMaxModel`:

```haskell
    -- * Pure assembly (exported for white-box testing)
  , buildConfig
  , EnvOverride (..)
  , defaultMiniMaxModel
```

- [ ] **Step 2: Rewrite `src/OpenCode/Run.hs`**

Replace the entire file with:

```haskell
{-# LANGUAGE ScopedTypeVariables #-}

-- | Top-level application wiring: CLI dispatch + environment construction.
-- Sits above 'OpenCode.App', 'OpenCode.Session', 'OpenCode.CLI', and the TUI so
-- it can build the environment and launch any subcommand without inducing an
-- import cycle.
module OpenCode.Run
  ( runApp
  ) where

import qualified Brick.BChan as BChan
import Conduit ((.|))
import qualified Conduit
import Control.Concurrent.Async (async, poll, waitCatch)
import qualified Control.Concurrent.STM as STM
import Control.Exception (SomeException, try)
import Data.List.NonEmpty (NonEmpty ((:|)))
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import Data.Time (UTCTime (..), fromGregorian)
import Options.Applicative (defaultPrefs, execParserPure, handleParseResult)
import System.Environment (getArgs)
import System.Exit (exitFailure)
import System.IO (hFlush, hPutStrLn, stderr, stdout)
import System.Timeout (timeout)

import OpenCode.App (AppEnv (..), runAppM)
import OpenCode.App.Error (displayAppError)
import OpenCode.CLI
  ( Command (..)
  , RunOpts (..)
  , commandParserInfo
  , defaultRunOpts
  , providerLabel
  , renderExportMarkdown
  , renderSessionList
  )
import OpenCode.Config
  ( Config (..), ProviderConfig (..), defaultMiniMaxModel, loadConfig )
import qualified OpenCode.DB as DB
import OpenCode.LLM.Types (LLMRequest (..), Streamer)
import OpenCode.Session
  ( createSession, loadSession, processUserMessage, streamerForProvider )
import OpenCode.Session.Events (RunState (Idle), SessionEvent (..))
import qualified OpenCode.Tool.Types as Tool
import OpenCode.TUI.App (startTUI)
import OpenCode.Types
  ( Message (..)
  , MessageId (MessageId)
  , MessagePart (TextPart)
  , ModelId (..)
  , ProviderId (..)
  , Role (RoleUser)
  , Session (..)
  , SessionId (..)
  , StreamEvent (StreamError)
  )

-- | Entry point. No arguments → interactive TUI on a fresh session; otherwise
-- parse the subcommand. Every command runs inside 'withAppEnv'.
runApp :: Tool.ToolRegistry -> IO ()
runApp registry = do
  args <- getArgs
  cmd  <- case args of
    [] -> pure (Run defaultRunOpts)
    _  -> handleParseResult (execParserPure defaultPrefs commandParserInfo args)
  withAppEnv registry (\cfg env -> dispatch cfg env cmd)

dispatch :: Config -> AppEnv -> Command -> IO ()
dispatch cfg env = \case
  Run ro      -> runRun cfg env ro
  List        -> runList env
  Export sid  -> runExport env sid
  ConfigCheck -> runConfigCheck cfg env

-- | Load config, open the DB, and build an 'AppEnv'; run the continuation.
-- A config error is reported to stderr and the process exits non-zero.
withAppEnv :: Tool.ToolRegistry -> (Config -> AppEnv -> IO a) -> IO a
withAppEnv registry k = do
  cfgResult <- loadConfig
  case cfgResult of
    Left err  -> do
      hPutStrLn stderr ("opencode-hs: config error: " <> show err)
      exitFailure
    Right cfg -> do
      dbPath   <- DB.defaultDbPath
      conn     <- DB.openDb dbPath
      chan     <- BChan.newBChan 100
      abortVar <- STM.newTVarIO False
      let env = AppEnv
            { envConfig    = cfg
            , envDb        = conn
            , envRegistry  = registry
            , envEventChan = chan
            , envAbort     = abortVar
            }
      k cfg env

-- ---------------------------------------------------------------------------
-- run
-- ---------------------------------------------------------------------------

runRun :: Config -> AppEnv -> RunOpts -> IO ()
runRun cfg env ro = do
  session <- resolveSession cfg env ro
  if roNoTui ro
    then case roPrompt ro of
      Nothing     -> dieT "--no-tui requires --prompt"
      Just prompt -> runHeadless env (sessionId session) prompt
    else startTUI env session

resolveSession :: Config -> AppEnv -> RunOpts -> IO Session
resolveSession cfg env ro = case roSession ro of
  Just sid -> do
    result <- runAppM env (loadSession sid)
    case result of
      Right (Just s) -> pure s
      Right Nothing  -> dieT ("no such session: " <> unSessionId sid)
      Left err       -> dieT (displayAppError err)
  Nothing -> do
    let mdl = fromMaybe (defaultModel cfg) (roModel ro)
    result <- runAppM env (createSession mdl)
    either (dieT . displayAppError) pure result

-- | Headless run: stream the assistant reply to stdout as it arrives. Reads
-- 'envEventChan' until the run emits @RunStateChanged Idle@ or the worker
-- finishes (the latter covers an early failure that emits no events).
runHeadless :: AppEnv -> SessionId -> Text -> IO ()
runHeadless env sid prompt = do
  worker <- async (runAppM env (processUserMessage sid prompt))
  drain worker
  result <- waitCatch worker
  putStrLn ""
  case result of
    Left ex          -> TIO.hPutStrLn stderr (T.pack (show ex)) >> exitFailure
    Right (Left err) -> TIO.hPutStrLn stderr (displayAppError err) >> exitFailure
    Right (Right ()) -> pure ()
  where
    drain worker = do
      mev <- timeout 50000 (BChan.readBChan (envEventChan env))
      case mev of
        Just (RunStateChanged Idle) -> pure ()
        Just ev                     -> handleEv ev >> drain worker
        Nothing                     -> do
          done <- poll worker
          case done of
            Just _  -> pure ()
            Nothing -> drain worker
    handleEv ev = case ev of
      PartialText t   -> TIO.hPutStr stdout t >> hFlush stdout
      ToolStarted n   -> TIO.hPutStrLn stderr ("⚙ " <> n)
      ErrorOccurred e -> TIO.hPutStrLn stderr e
      _               -> pure ()

-- ---------------------------------------------------------------------------
-- list / export
-- ---------------------------------------------------------------------------

runList :: AppEnv -> IO ()
runList env = do
  sessions <- DB.listSessions (envDb env)
  TIO.putStr (renderSessionList sessions)

runExport :: AppEnv -> SessionId -> IO ()
runExport env sid = do
  mSession <- DB.getSession (envDb env) sid
  case mSession of
    Nothing      -> dieT ("no such session: " <> unSessionId sid)
    Just session -> do
      msgs <- DB.getMessages (envDb env) sid
      TIO.putStr (renderExportMarkdown session msgs)

-- ---------------------------------------------------------------------------
-- config check
-- ---------------------------------------------------------------------------

runConfigCheck :: Config -> AppEnv -> IO ()
runConfigCheck cfg _env = mapM_ (checkProvider cfg) [OpenAI, MiniMax, Anthropic]

checkProvider :: Config -> ProviderId -> IO ()
checkProvider cfg pid = do
  let pc   = providers cfg
      mKey = case pid of
        OpenAI    -> openaiKey pc
        MiniMax   -> minimaxKey pc
        Anthropic -> anthropicKey pc
  status <- case mKey of
    Nothing -> pure "not configured"
    Just _  -> case pid of
      Anthropic -> pure "FAIL (not implemented until M11)"
      _         -> case streamerForProvider cfg pid of
        Left err       -> pure ("FAIL (" <> displayAppError err <> ")")
        Right streamer -> probeProvider streamer (probeModel cfg pid)
  TIO.putStrLn (providerLabel pid <> ": " <> status)

-- | Model to probe with: the configured default model when its provider
-- matches, else a per-provider default (so a key-only config still probes).
probeModel :: Config -> ProviderId -> Text
probeModel cfg pid
  | provider (defaultModel cfg) == pid = model (defaultModel cfg)
  | otherwise = case pid of
      OpenAI    -> "gpt-4o"
      MiniMax   -> defaultMiniMaxModel
      Anthropic -> ""   -- never probed

-- | Issue a minimal one-token request and inspect the first stream event.
probeProvider :: Streamer -> Text -> IO Text
probeProvider streamer mdl = do
  let req = LLMRequest
        { reqModel        = mdl
        , reqMessages     = [pingMessage]
        , reqTools        = []
        , reqSystemPrompt = ""
        , reqMaxTokens    = Just 1
        }
  outcome <- try (Conduit.runResourceT
                    (Conduit.runConduit (streamer req .| Conduit.await)))
  pure $ case outcome of
    Left (e :: SomeException)    -> "FAIL (" <> T.pack (show e) <> ")"
    Right (Just (StreamError e)) -> "FAIL (" <> T.take 120 e <> ")"
    Right _                      -> "OK"

pingMessage :: Message
pingMessage = Message
  { msgId      = MessageId "probe"
  , msgRole    = RoleUser
  , msgParts   = TextPart "ping" :| []
  , msgCreated = UTCTime (fromGregorian 1970 1 1) 0
  }

-- ---------------------------------------------------------------------------
-- helpers
-- ---------------------------------------------------------------------------

dieT :: Text -> IO a
dieT msg = do
  TIO.hPutStrLn stderr ("opencode-hs: " <> msg)
  exitFailure
```

- [ ] **Step 3: Build and run the full suite — verify GREEN**

Run:
```bash
stack build && stack test
```
Expected: compiles; entire suite passes. If GHC flags any unused import in `Run.hs`, remove it. (The `app/Main.hs` line `main = runApp defaultBuiltinRegistry` is unchanged and still type-checks.)

- [ ] **Step 4: Smoke-test the read-only commands**

Run:
```bash
stack run -- list
stack run -- --help
```
Expected: `list` prints the session table (or `(no sessions)`); `--help` prints usage listing the `run`/`list`/`export`/`config` subcommands. Neither requires a network call.

- [ ] **Step 5: Commit**

```bash
git add src/OpenCode/Run.hs src/OpenCode/Config.hs
git commit -m "$(cat <<'EOF'
M10: OpenCode.Run CLI dispatch + command runners

withAppEnv builds config/DB/env once; dispatch routes run/list/export/
config check. runHeadless streams PartialText to stdout (terminates on Idle
or worker completion); runConfigCheck probes each configured provider via
streamerForProvider. Bare invocation still launches the TUI. Export
defaultMiniMaxModel for the probe.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: Integration — acceptance + mark M10 done

**Files:**
- Modify: `MILESTONES.md`

- [ ] **Step 1: Full build + test + lint**

Run:
```bash
stack build 2>&1 | tail -20
stack test  2>&1 | tail -30
hlint src app test
```
Expected: build clean (warnings acceptable for M10; `-Werror` is an M12 task), entire suite green, `hlint` reports `No hints`. Fix any new hlint hints in the touched files before proceeding.

- [ ] **Step 2: Manual acceptance — the four subcommands**

With a provider key set (e.g. `MINIMAX_API_KEY` or `OPENAI_API_KEY`), run and confirm by observation:

```bash
# headless run: streams a complete reply to stdout, persists the session
stack run -- run --prompt "say hello in one word" --no-tui

# the new session now appears in the list
stack run -- list

# export the most recent session id from the list above
stack run -- export <SESSION_ID>

# probe connectivity per provider
stack run -- config check

# bare invocation still opens the TUI
stack run
```
Confirm:
1. `run --no-tui` streams text to stdout and exits 0; the session is persisted.
2. `list` shows the new row (ID/TITLE/MODEL/CREATED).
3. `export <id>` prints Markdown (`# title`, `## User`/`## Assistant`, fenced tool blocks if any).
4. `export bogus-id` prints `opencode-hs: no such session: bogus-id` to stderr and exits non-zero.
5. `config check` prints one line per provider (`OK` / `FAIL (...)` / `not configured`; a configured Anthropic key shows the M11 deferral).
6. Bare `stack run` opens the TUI; `Ctrl+C` exits.

- [ ] **Step 3: Mark M10 done in `MILESTONES.md`**

In the status-snapshot table, change the M10 row from:

```markdown
| M10 | CLI commands                           | pending   | —                  |
```

to (use the first M10 commit SHA from `git log --oneline --grep "^M10"` for the cell):

```markdown
| M10 | CLI commands                           | done      | `<first-M10-sha>..` |
```

Change the M10 section heading from `## M10 — CLI commands` to `## M10 — CLI commands — DONE` and insert an outcome paragraph immediately under it (mirroring M8/M9):

```markdown
## M10 — CLI commands — DONE

Outcome: a new pure `OpenCode.CLI` module holds the `optparse-applicative`
grammar (`run`/`list`/`export`/`config check`), `parseModelId`
(`provider:model` over openai/anthropic/minimax), a testable `parseArgs`, and
the pure renderers `renderSessionList` (fixed-width table) and
`renderExportMarkdown` (session → Markdown). `OpenCode.Run` builds config + DB
+ env once via `withAppEnv` and dispatches to `runRun`/`runList`/`runExport`/
`runConfigCheck`; `runHeadless` streams `PartialText` to stdout under
`--no-tui`, and `config check` probes each configured provider through the
newly-exported `OpenCode.Session.streamerForProvider`. Bare `stack run` still
opens the TUI. Anthropic parses but reports the M11 deferral; `--version`,
SIGINT, and title auto-generation remain in M12.
```

(Leave the existing Tasks/Tests/Acceptance subsections below the new outcome paragraph.)

- [ ] **Step 4: Commit**

```bash
git add MILESTONES.md
git commit -m "$(cat <<'EOF'
M10: acceptance verification + mark milestone done

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Self-Review

**Spec coverage** (against `2026-06-04-m10-cli-commands-design.md`):
- `OpenCode.CLI` parser + `parseModelId` → Tasks 1, 2.
- `renderSessionList` → Task 3.
- `renderExportMarkdown` → Task 4.
- `streamerForProvider` (single dispatch point) → Task 5.
- `withAppEnv` + dispatch + `runRun`/`runList`/`runExport`/`runConfigCheck` + `runHeadless` → Task 6.
- `config check` per-provider probe with per-provider default model → Task 6 (`checkProvider`/`probeModel`/`probeProvider`).
- Bare invocation → TUI → Task 6 (`runApp` empty-args branch).
- Testing (parseModelId, parseArgs, renderers, streamerForProvider) → Tasks 1–5; acceptance commands → Task 7.

**Type/name consistency:** `Command`/`RunOpts`/`defaultRunOpts` defined in Task 1, consumed by `parseArgs` (Task 2) and `OpenCode.Run` dispatch (Task 6); `providerLabel` defined Task 1, used by `modelText` (Task 3) and `checkProvider` (Task 6); `modelText`/`createdText` defined Task 3, reused by `renderExportMarkdown` (Task 4); `streamerForProvider :: Config -> ProviderId -> Either AppError Streamer` defined Task 5, called in Task 6; `defaultMiniMaxModel` exported Task 6 Step 1, used in `probeModel` Task 6 Step 2; `LLMRequest` field names (`reqModel`/`reqMessages`/`reqTools`/`reqSystemPrompt`/`reqMaxTokens`) match `OpenCode.LLM.Types`; all record accessors (`sessionId`/`sessionTitle`/`sessionModel`/`sessionCreated`, `msgRole`/`msgParts`, `toolName`/`arguments`/`unToolArgs`, `content`, `unSessionId`) match `OpenCode.Types`.

**Placeholder scan:** no TBD/TODO; every code step shows complete code; the only "fill-in" is the M10 commit SHA in Task 7 Step 3, which is a concrete `git log` instruction (the SHA cannot exist before the commits do), consistent with the existing table convention.
