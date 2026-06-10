# Model-Invoked Skills (M16) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Expose every discovered skill (local `SKILL.md` + MCP prompts) to the model through one umbrella `skill` tool, so the agent can invoke skills autonomously mid-run.

**Architecture:** A new top-level module `OpenCode.SkillTool` builds a single `SomeTool` on the existing `DynamicTool` GADT tag whose schema enumerates skill names and whose executor renders the chosen skill's body as the tool result. A shared `renderSkill` function becomes the one render path for both the model tool and the user-typed `/<name>` path (TUI delegates to it). `Run.withAppEnv` merges the tool into `envRegistry`. The `OpenCode.Skill.*` namespace stays pure/MCP-free; only `OpenCode.SkillTool` may import both `Skill.*` and `MCP.*`.

**Tech Stack:** Haskell (Stack lts-22.39, GHC 9.6.6), aeson, hspec (+ `opencode-mcp-mock` exe for MCP integration tests). No new dependencies.

**Spec:** `docs/superpowers/specs/2026-06-10-model-invoked-skills-design.md`

**Build discipline (applies to every task):**
- The repo is `-Wall -Werror` and hlint-clean. Remove imports that become unused; do not suppress warnings.
- Any task that edits `package.yaml` MUST run `stack build` (hpack regenerates `opencode-hs.cabal`) and `git add opencode-hs.cabal` in the same commit. (M15 lesson: Tasks that skipped this left the generated .cabal drifted.)
- Run `make lint` (or `hlint src test app`) before each commit if the Makefile provides it; otherwise `stack test` green is the gate.

---

## File structure

| File | Action | Responsibility |
|---|---|---|
| `src/OpenCode/Skill/Registry.hs` | Modify | + `skillToolSchema`, `skillToolDescription` (pure builders) |
| `src/OpenCode/SkillTool.hs` | Create | `renderSkill`, `SkillCall`, `runSkillCall`, `skillTool`, `skillToolName` (MCP-aware wiring) |
| `src/OpenCode/Run.hs` | Modify | reserve `skill` name; merge `skillTool` into `envRegistry` |
| `src/OpenCode/TUI/App.hs` | Modify | `invokeSkill` delegates to `renderSkill`; prune dead imports |
| `test/OpenCode/Skill/RegistrySpec.hs` | Modify | tests for the pure builders |
| `test/OpenCode/SkillToolSpec.hs` | Create | unit + parity + MCP integration tests |
| `test/OpenCode/McpMock.hs` | Create | shared mock-server harness (extracted from ClientSpec) |
| `test/OpenCode/MCP/ClientSpec.hs` | Modify | use the shared harness |
| `package.yaml` (+ generated `opencode-hs.cabal`) | Modify | new exposed/other modules |
| `README.md`, `MILESTONES.md` | Modify | document M16 |

Dependency edges added: `SkillTool → {Skill.Types, Skill.Parse, Skill.Registry, MCP.Client, MCP.Protocol, Tool.Types}`, `Run → SkillTool`, `TUI.App → SkillTool`. `SkillTool` must NOT import `TUI.*` or `Run`.

---

### Task 1: Pure builders in `OpenCode.Skill.Registry`

**Files:**
- Modify: `src/OpenCode/Skill/Registry.hs`
- Test: `test/OpenCode/Skill/RegistrySpec.hs`

- [ ] **Step 1: Write the failing tests**

Append to the top-level `spec` in `test/OpenCode/Skill/RegistrySpec.hs` (match the file's existing helper for building a `Skill`; if it has none, use the literal below). Add the imports the file is missing: `qualified Data.Aeson as Aeson`, `Data.Aeson (Value)`, `qualified Data.Aeson.KeyMap as KM`, `qualified Data.Text as T`, and `OpenCode.Skill.Types (Skill (..), SkillSource (..))` if not already imported.

```haskell
  describe "skillToolDescription" $ do
    it "enumerates one line per skill with name and description" $ do
      let ss = [ Skill "explain" "explain a file" [] (LocalSkill "body")
               , Skill "srv_greet" "greet someone" ["who"] (McpPromptSkill "srv" "greet") ]
          d  = skillToolDescription ss
      d `shouldSatisfy` T.isInfixOf "  - explain: explain a file"
      d `shouldSatisfy` T.isInfixOf "  - srv_greet: greet someone (needs: who)"

    it "starts with the invocation instruction" $
      skillToolDescription [Skill "a" "b" [] (LocalSkill "x")]
        `shouldSatisfy` T.isPrefixOf "Invoke a named skill"

  describe "skillToolSchema" $ do
    it "is an object schema requiring name, with the skill names as the enum" $ do
      let v = skillToolSchema [ Skill "a" "" [] (LocalSkill "x")
                              , Skill "b" "" [] (LocalSkill "y") ]
      -- decode the schema back to inspect it structurally
      case v of
        Aeson.Object o -> do
          KM.lookup "required" o `shouldBe` Just (Aeson.toJSON (["name"] :: [T.Text]))
          case KM.lookup "properties" o of
            Just (Aeson.Object props) -> case KM.lookup "name" props of
              Just (Aeson.Object nameP) ->
                KM.lookup "enum" nameP `shouldBe` Just (Aeson.toJSON (["a", "b"] :: [T.Text]))
              _ -> expectationFailure "properties.name missing"
            _ -> expectationFailure "properties missing"
        _ -> expectationFailure "schema is not an object"

    it "round-trips through aeson" $ do
      let v = skillToolSchema [Skill "a" "" [] (LocalSkill "x")]
      Aeson.decode (Aeson.encode v) `shouldBe` Just v
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `stack test --ta '-m "skillTool"'`
Expected: FAIL to compile — `skillToolDescription`/`skillToolSchema` not in scope.

- [ ] **Step 3: Implement the builders**

In `src/OpenCode/Skill/Registry.hs`: add `skillToolSchema` and `skillToolDescription` to the export list, add imports `Data.Aeson (Value, object, (.=))` and `qualified Data.Text as T`, and append:

```haskell
-- | Tool description for the umbrella @skill@ tool: an invocation instruction
-- plus one line per skill. MCP-prompt skills with required args advertise them
-- as @(needs: a, b)@ so the model supplies @key=value@ pairs in @arguments@.
skillToolDescription :: [Skill] -> Text
skillToolDescription skills = T.intercalate "\n" (header : map line skills)
  where
    header =
      "Invoke a named skill: a reusable instruction bundle. The result is the \
      \skill's instructions; follow them. Available skills:"
    line s = "  - " <> skName s <> ": " <> skDescription s <> needs (skRequiredArgs s)
    needs [] = ""
    needs as = " (needs: " <> T.intercalate ", " as <> ")"

-- | Input schema for the umbrella @skill@ tool. The @name@ enum lists exactly
-- the registered skill names, so an invalid name is unrepresentable at the
-- wire level.
skillToolSchema :: [Skill] -> Value
skillToolSchema skills = object
  [ "type" .= ("object" :: Text)
  , "properties" .= object
      [ "name" .= object
          [ "type" .= ("string" :: Text)
          , "enum" .= map skName skills
          ]
      , "arguments" .= object
          [ "type" .= ("string" :: Text)
          , "description" .=
              ("free text for the skill; for skills with required args, \
               \key=value pairs" :: Text)
          ]
      ]
  , "required" .= (["name"] :: [Text])
  ]
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `stack test --ta '-m "skillTool"'`
Expected: PASS (all new cases green; zero failures overall in the matched set).

- [ ] **Step 5: Commit**

```bash
git add src/OpenCode/Skill/Registry.hs test/OpenCode/Skill/RegistrySpec.hs
git commit -m "M16: pure schema/description builders for the umbrella skill tool"
```

---

### Task 2: `OpenCode.SkillTool` — renderSkill, runSkillCall, skillTool (unit-testable core)

**Files:**
- Create: `src/OpenCode/SkillTool.hs`
- Create: `test/OpenCode/SkillToolSpec.hs`
- Modify: `package.yaml` (library `exposed-modules` + test `other-modules`)

- [ ] **Step 1: Register the new modules in package.yaml**

In `package.yaml`: add `- OpenCode.SkillTool` to the library `exposed-modules` (after `OpenCode.Skill.Discovery`), and `- OpenCode.SkillToolSpec` to the `opencode-hs-test` `other-modules` (after `OpenCode.Skill.DiscoverySpec`).

- [ ] **Step 2: Write the failing tests**

Create `test/OpenCode/SkillToolSpec.hs`:

```haskell
module OpenCode.SkillToolSpec (spec) where

import qualified Data.Aeson as Aeson
import Data.Aeson (object, (.=))
import Data.Text (Text)
import qualified Data.Text as T
import Test.Hspec

import OpenCode.SkillTool
import OpenCode.Skill.Types (Skill (..), SkillSource (..))
import OpenCode.Tool.Types (SomeTool (..))

localSkill :: Skill
localSkill = Skill "explain" "explain a file" []
  (LocalSkill "Explain this, step by step: $ARGUMENTS")

mcpSkill :: Skill
mcpSkill = Skill "srv_greet" "greet someone" ["who"]
  (McpPromptSkill "srv" "greet")

call :: Text -> Text -> Aeson.Value
call name args = object ["name" .= name, "arguments" .= args]

spec :: Spec
spec = do
  describe "renderSkill (no MCP needed)" $ do
    it "renders a local skill body with $ARGUMENTS substituted" $
      renderSkill [] localSkill "src/Foo.hs"
        `shouldReturn` Right "Explain this, step by step: src/Foo.hs"

    it "reports a missing required arg before contacting any server" $
      renderSkill [] mcpSkill "lang=en"
        `shouldReturn` Left "missing required arg: who"

    it "reports an unavailable server when args are satisfied" $
      renderSkill [] mcpSkill "who=ada"
        `shouldReturn` Left "prompt server unavailable"

  describe "runSkillCall" $ do
    it "renders the named local skill" $
      runSkillCall [] [localSkill] (call "explain" "src/Foo.hs")
        `shouldReturn` "Explain this, step by step: src/Foo.hs"

    it "returns guidance listing valid names for an unknown skill" $ do
      r <- runSkillCall [] [localSkill] (call "nope" "")
      r `shouldSatisfy` T.isInfixOf "unknown skill 'nope'"
      r `shouldSatisfy` T.isInfixOf "explain"

    it "returns guidance for a skill-level failure (missing arg)" $ do
      r <- runSkillCall [] [mcpSkill] (call "srv_greet" "")
      r `shouldSatisfy` T.isInfixOf "missing required arg: who"

    it "returns guidance for a malformed call object" $ do
      r <- runSkillCall [] [localSkill] (object ["bogus" .= True])
      r `shouldSatisfy` T.isInfixOf "invalid skill call"

    it "flags a skill that renders to blank" $ do
      let blank = Skill "empty" "" [] (LocalSkill "$ARGUMENTS")
      r <- runSkillCall [] [blank] (call "empty" "")
      r `shouldSatisfy` T.isInfixOf "produced no content"

  describe "skillTool" $ do
    it "is absent when no skills exist" $
      fmap toolName (skillTool [] []) `shouldBe` Nothing

    it "is named 'skill' and carries the enumerated description" $
      case skillTool [] [localSkill] of
        Nothing -> expectationFailure "expected the tool to exist"
        Just t  -> do
          toolName t `shouldBe` skillToolName
          toolDesc t `shouldSatisfy` T.isInfixOf "explain a file"
```

(The `Maybe SomeTool` is inspected only through `toolName`/`toolDesc`, which the
existential exposes; the executor itself is covered through `runSkillCall` and,
in Task 4, end-to-end via `executeTool`.)

- [ ] **Step 3: Run the tests to verify they fail**

Run: `stack test --ta '-m "SkillTool"'`
Expected: FAIL to compile — module `OpenCode.SkillTool` does not exist.

- [ ] **Step 4: Implement the module**

Create `src/OpenCode/SkillTool.hs`:

```haskell
-- | The umbrella @skill@ tool: exposes every discovered skill (local SKILL.md
-- and MCP prompts) to the model as a single tool whose result is the rendered
-- skill body. Also home to 'renderSkill', the one render path shared with the
-- user-typed @/<name>@ invocation in the TUI. This is the only module allowed
-- to import both @Skill.*@ and @MCP.*@ (the @Skill.*@ namespace stays pure).
module OpenCode.SkillTool
  ( SkillCall (..)
  , skillToolName
  , renderSkill
  , runSkillCall
  , skillTool
  ) where

import Control.Exception (SomeException, displayException, try)
import Control.Monad.IO.Class (liftIO)
import Data.Aeson (FromJSON (..), Value)
import qualified Data.Aeson as Aeson
import Data.List (find)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import GHC.Generics (Generic)

import OpenCode.MCP.Client
  ( McpClient (..), McpError, getPrompt, renderMcpError )
import OpenCode.MCP.Protocol (GetPromptResult (..), PromptMessage (..))
import OpenCode.Skill.Parse (missingArgs, parseArgs, substituteArgs)
import OpenCode.Skill.Registry
  ( lookupSkill, skillToolDescription, skillToolSchema )
import OpenCode.Skill.Types (Skill (..), SkillSource (..))
import OpenCode.Tool.Types
  ( SomeTool (..), ToolDef (DynamicTool), inputOptions )

-- | The reserved tool/command name. A local skill with this name is dropped by
-- the registry ('OpenCode.Run' adds it to the reserved list).
skillToolName :: Text
skillToolName = "skill"

-- | The model's call payload: @{"name": ..., "arguments": ...}@.
data SkillCall = SkillCall
  { scName      :: Text
  , scArguments :: Maybe Text
  }
  deriving stock (Show, Eq, Generic)

instance FromJSON SkillCall where
  parseJSON = Aeson.genericParseJSON inputOptions

-- | Render a skill for the given trailing text. The single render path shared
-- by the user-typed @/<name>@ invocation (TUI) and the model's @skill@ tool.
-- Local skills substitute @$ARGUMENTS@ (pure, never 'Left'); MCP prompts parse
-- @key=value@ args, validate required args, and fetch from the live server.
-- 'Left' is human-readable guidance; never throws.
renderSkill :: [McpClient] -> Skill -> Text -> IO (Either Text Text)
renderSkill clients skill rest = case skSource skill of
  LocalSkill body ->
    pure (Right (substituteArgs body (T.strip rest)))
  McpPromptSkill server prompt -> case missingArgs (skRequiredArgs skill) args of
    (m : _) -> pure (Left ("missing required arg: " <> m))
    []      -> case find ((== server) . mcName) clients of
      Nothing -> pure (Left "prompt server unavailable")
      Just c  -> do
        result <- try (getPrompt c prompt args)
                    :: IO (Either SomeException (Either McpError GetPromptResult))
        pure $ case result of
          Left ex         -> Left ("prompt error: " <> T.pack (displayException ex))
          Right (Left e)  -> Left ("prompt error: " <> renderMcpError e)
          Right (Right g) -> Right (T.intercalate "\n\n" (map pmText (gprMessages g)))
  where args = parseArgs rest

-- | Execute one model call against the registry snapshot. Skill-level problems
-- (unknown name, missing args, fetch failure, blank render) come back as
-- guidance text — not a thrown error — so the run survives and the model can
-- self-correct (the M14 convention for error-ish tool results).
runSkillCall :: [McpClient] -> [Skill] -> Value -> IO Text
runSkillCall clients skills v = case Aeson.fromJSON v of
  Aeson.Error e -> pure (T.pack ("invalid skill call: " <> e))
  Aeson.Success c -> case lookupSkill (scName c) skills of
    Nothing -> pure ("unknown skill '" <> scName c <> "'. Valid names: "
                       <> T.intercalate ", " (map skName skills))
    Just s  -> do
      r <- renderSkill clients s (fromMaybe "" (scArguments c))
      pure $ case r of
        Left err -> "skill '" <> skName s <> "' failed: " <> err
        Right rendered
          | T.null (T.strip rendered) ->
              "skill '" <> skName s <> "' produced no content"
          | otherwise -> rendered

-- | The umbrella tool, or 'Nothing' when there are no skills to expose. Built
-- on the 'DynamicTool' tag like the MCP adapters; the executor closes over the
-- clients and the startup skill snapshot.
skillTool :: [McpClient] -> [Skill] -> Maybe SomeTool
skillTool _ [] = Nothing
skillTool clients skills = Just SomeTool
  { toolDef     = DynamicTool
  , toolName    = skillToolName
  , toolDesc    = skillToolDescription skills
  , toolSchema  = skillToolSchema skills
  , toolExecute = liftIO . runSkillCall clients skills
  , toolRender  = id
  }
```

- [ ] **Step 5: Build and run the tests**

Run: `stack build && stack test --ta '-m "SkillTool"'`
Expected: build succeeds (hpack regenerates `opencode-hs.cabal`); all `SkillToolSpec` cases PASS.

- [ ] **Step 6: Commit (including the regenerated .cabal)**

```bash
git add package.yaml opencode-hs.cabal src/OpenCode/SkillTool.hs test/OpenCode/SkillToolSpec.hs
git commit -m "M16: OpenCode.SkillTool — renderSkill core + umbrella skill tool"
```

---

### Task 3: Extract the shared MCP mock harness

The mock-server bring-up (`mockServerPath`/`withMock`) is currently private to `ClientSpec`; Task 4 needs it too. Extract, don't duplicate.

**Files:**
- Create: `test/OpenCode/McpMock.hs`
- Modify: `test/OpenCode/MCP/ClientSpec.hs`
- Modify: `package.yaml` (test `other-modules`)

- [ ] **Step 1: Create the harness module**

Create `test/OpenCode/McpMock.hs` by moving (verbatim, plus the module header) `mockServerPath` and `withMock` out of `test/OpenCode/MCP/ClientSpec.hs`:

```haskell
-- | Shared test harness for the in-repo @opencode-mcp-mock@ stdio server:
-- locate the built executable and run an action against a connected client.
module OpenCode.McpMock
  ( mockServerPath
  , withMock
  ) where

import Control.Exception (bracket)
import qualified Data.Text as T
import System.Directory (doesFileExist)
import System.Environment (lookupEnv)
import System.FilePath ((</>))

import Paths_opencode_hs (getBinDir)
import OpenCode.Config (McpServerConfig (..))
import OpenCode.MCP.Client (McpClient, connect, renderMcpError, shutdown)

-- | Locate the built mock server: honor OPENCODE_MCP_MOCK, else look in the
-- package's bin dir (stack builds executables before running the test suite).
mockServerPath :: IO (Maybe FilePath)
mockServerPath = do
  override <- lookupEnv "OPENCODE_MCP_MOCK"
  case override of
    Just p  -> pure (Just p)
    Nothing -> do
      bin <- getBinDir
      let p = bin </> "opencode-mcp-mock"
      ok <- doesFileExist p
      pure (if ok then Just p else Nothing)

withMock :: (McpClient -> IO a) -> IO a
withMock k = do
  mp <- mockServerPath
  case mp of
    Nothing   -> error "opencode-mcp-mock not found (build it with `stack build`)"
    Just path -> do
      let cfg = McpServerConfig { mcsCommand = path, mcsArgs = [], mcsEnv = [], mcsEnabled = True }
      r <- connect "mock" cfg
      case r of
        Left e  -> error ("mock connect failed: " <> T.unpack (renderMcpError e))
        Right c -> bracket (pure c) shutdown k
```

(If `OpenCode.MCP.Client` does not export `shutdown` by name in the import list ClientSpec used, mirror however ClientSpec brought it into scope.)

- [ ] **Step 2: Point ClientSpec at the harness**

In `test/OpenCode/MCP/ClientSpec.hs`: delete the moved `mockServerPath`/`withMock` definitions, add `import OpenCode.McpMock (withMock)`, and delete the imports that are now unused there (`bracket`, `doesFileExist`, `lookupEnv`, `(</>)`, `getBinDir`, `McpServerConfig (..)` — keep whatever the remaining tests still use; let `-Wall -Werror` be the judge).

- [ ] **Step 3: Register the module**

In `package.yaml`, add `- OpenCode.McpMock` to the `opencode-hs-test` `other-modules`.

- [ ] **Step 4: Build and run the MCP client tests**

Run: `stack build && stack test --ta '-m "OpenCode.MCP.Client"'`
Expected: compiles; the existing ClientSpec suite PASSES unchanged.

- [ ] **Step 5: Commit (including the regenerated .cabal)**

```bash
git add package.yaml opencode-hs.cabal test/OpenCode/McpMock.hs test/OpenCode/MCP/ClientSpec.hs
git commit -m "M16: extract shared opencode-mcp-mock harness for reuse"
```

---

### Task 4: SkillTool integration tests (live MCP path, executeTool round-trip, parity)

**Files:**
- Modify: `test/OpenCode/SkillToolSpec.hs`

- [ ] **Step 1: Write the failing tests**

Append to `spec` in `test/OpenCode/SkillToolSpec.hs`. Add imports:

```haskell
import OpenCode.App (runAppM)
import OpenCode.App.Types (AppEnv (..))
import OpenCode.McpMock (withMock)
import OpenCode.TestEnv (newDummyEnv)
import OpenCode.Tool.Types (emptyRegistry, executeTool, registerTool)
```

The mock server (`test/mcp-mock/Main.hs`) advertises one prompt `greet` (no
required args) whose `prompts/get` returns one message `"hello there"`.

```haskell
  describe "renderSkill / runSkillCall against the mock MCP server" $ do
    let greetSkill = Skill "mock_greet" "greet someone" [] (McpPromptSkill "mock" "greet")

    it "renders an MCP-prompt skill from the live server" $ withMock $ \c ->
      renderSkill [c] greetSkill "" `shouldReturn` Right "hello there"

    it "runs an MCP-prompt skill through the tool call path" $ withMock $ \c ->
      runSkillCall [c] [greetSkill] (call "mock_greet" "")
        `shouldReturn` "hello there"

    it "tool path and direct render path agree (parity)" $ withMock $ \c -> do
      direct <- renderSkill [c] greetSkill ""
      viaTool <- runSkillCall [c] [greetSkill] (call "mock_greet" "")
      direct `shouldBe` Right viaTool

  describe "skill tool via executeTool (registry round-trip)" $ do
    it "dispatches a skill call end to end in AppM" $ do
      env <- newDummyEnv
      let Just t = skillTool [] [localSkill]
          reg    = registerTool t emptyRegistry
      r <- runAppM env (executeTool reg "skill" (call "explain" "src/Foo.hs"))
      r `shouldBe` Right "Explain this, step by step: src/Foo.hs"
```

(`newDummyEnv` comes from `OpenCode.TestEnv`; it is already used by other specs
that need an `AppEnv` without a real session. The `Just t` partial match is
acceptable in test code where the preceding `skillTool` case is pinned by the
Task 2 tests; if hlint objects, use a `case` with `expectationFailure`.)

- [ ] **Step 2: Run the tests to verify the new ones fail/compile**

Run: `stack test --ta '-m "SkillTool"'`
Expected: compiles and the three mock-server tests plus the round-trip PASS only if the implementation is correct — they should pass immediately since Task 2 implemented the logic; what this step verifies is the live wire format (`prompts/get` flattening) and the `executeTool` decode path. If any fail, fix `renderSkill`/`runSkillCall` (not the tests) — likely suspects: arg stripping or message flattening.

- [ ] **Step 3: Run the whole suite**

Run: `stack test`
Expected: 0 failures (404 existing tests + the new ones).

- [ ] **Step 4: Commit**

```bash
git add test/OpenCode/SkillToolSpec.hs
git commit -m "M16: SkillTool integration tests (mock MCP, executeTool, parity)"
```

---

### Task 5: Wire the tool into `Run.withAppEnv` and reserve the name

**Files:**
- Modify: `src/OpenCode/Run.hs` (the `withAppEnv` let-block, currently around lines 130–151)
- Test: `test/OpenCode/Skill/RegistrySpec.hs` (reserved-name pin)

- [ ] **Step 1: Write the failing reserved-name test**

In `test/OpenCode/Skill/RegistrySpec.hs`, add (import `OpenCode.SkillTool (skillToolName)`):

```haskell
  describe "skill tool name reservation" $
    it "a local skill named 'skill' is dropped when the name is reserved" $ do
      let s = Skill skillToolName "shadow attempt" [] (LocalSkill "x")
      buildSkillRegistry [skillToolName] [s] `shouldBe` []
```

Run: `stack test --ta '-m "reservation"'`
Expected: FAIL to compile (`skillToolName` not imported) → then PASS once the import is added, since `buildSkillRegistry` already honors reserved names. This test pins the constant so a rename can't silently un-reserve it.

- [ ] **Step 2: Wire `Run.hs`**

In `src/OpenCode/Run.hs`:

1. Add the import (alongside the existing `OpenCode.Skill.*` imports):

```haskell
import OpenCode.SkillTool (skillTool, skillToolName)
```

2. In `withAppEnv`, change the reserved list:

```haskell
        let reserved  = skillToolName : [ T.drop 1 name | (_, name, _) <- commandCatalog ]
```

3. Change `envRegistry` so the umbrella tool (when present) is registered over the MCP additions — registered last, so it wins any (unlikely) name clash, keeping `skill` unshadowable like the built-in commands. `Tool.` is the existing qualified import of `OpenCode.Tool.Types` in this file:

```haskell
              , envRegistry  = maybe id Tool.registerTool (skillTool clients skills)
                                 (mcpRegistryAdditions clients registry)
```

(`skills` is already in scope from the preceding `let`; `registerTool` must be added to the existing qualified import if the qualified style requires no change, or to the import list if `Tool.Types` is imported by name — match the file.)

4. Update the `withAppEnv` haddock comment's last sentence to mention the tool:

```haskell
-- skills are discovered and merged with MCP prompts into 'envSkills', and the
-- umbrella @skill@ tool (when any skills exist) is merged into the registry so
-- the model can invoke skills autonomously.
```

- [ ] **Step 3: Build and run the full suite**

Run: `stack build && stack test`
Expected: compiles under `-Wall -Werror`; 0 failures.

- [ ] **Step 4: Manual smoke check (headless)**

Run: `stack run -- run --no-tui --prompt "List your available tools." 2>/dev/null | head -40` (requires an API key; skip if none is configured and note that in the task report).
Expected: with at least one skill present under `./.opencode-hs/skills/` or `~/.config/opencode-hs/skills/`, the model's tool list includes `skill`. With zero skills, no `skill` tool is mentioned.

- [ ] **Step 5: Commit**

```bash
git add src/OpenCode/Run.hs test/OpenCode/Skill/RegistrySpec.hs
git commit -m "M16: register the umbrella skill tool in withAppEnv; reserve 'skill'"
```

---

### Task 6: Refactor `TUI.App.invokeSkill` to delegate to `renderSkill`

**Files:**
- Modify: `src/OpenCode/TUI/App.hs` (`invokeSkill`, currently around lines 374–402, plus imports)

- [ ] **Step 1: Replace `invokeSkill`**

Replace the whole `invokeSkill` definition (keep its haddock position; update the comment) with:

```haskell
-- | Run a skill. Rendering is delegated to 'renderSkill' — the same path the
-- model's umbrella @skill@ tool uses — so the user-typed and model-invoked
-- flows can never drift. The rendered text is injected as a user turn and run.
-- 'invokeSkill' clears the input on every branch.
invokeSkill :: Skill -> Text -> AppState -> EventM ResourceName AppState ()
invokeSkill skill rest st = do
  result <- liftIO (renderSkill (envMcp (asEnv st)) skill rest)
  case result of
    Left err -> put st { asInput = emptyEditor, asNotice = Just err }
    Right rendered
      | T.null (T.strip rendered) ->
          put st { asInput = emptyEditor, asNotice = Just "skill produced no content" }
      | otherwise -> runText rendered st
```

Behavior notes (intentional, document in the commit message):
- Notice strings `"missing required arg: <a>"`, `"prompt server unavailable"`, and `"prompt error: …"` are unchanged (they now come from `renderSkill`).
- The MCP blank-result notice changes from `"prompt returned no content"` to the unified `"skill produced no content"`.

- [ ] **Step 2: Prune imports**

Add `import OpenCode.SkillTool (renderSkill)`. Then remove the now-unused imports — expected casualties: the entire `OpenCode.MCP.Client` and `OpenCode.MCP.Protocol` import lines, and the `OpenCode.Skill.Parse (substituteArgs, parseArgs, missingArgs)` line. `Data.List (find)`, `try`/`SomeException`/`displayException` are still used elsewhere in the file (e.g. `openModel`, `switchTo`) — keep them. Let `-Wall -Werror` flag anything residual.

- [ ] **Step 3: Build and run the full suite**

Run: `stack build && stack test`
Expected: compiles clean; 0 failures (TUI specs unchanged — `invokeSkill` is not directly exercised by `AppSpec`, but `selectSkill`'s call site and the `/`-routing through `matchSkill` are, and must keep passing).

- [ ] **Step 4: Manual TUI smoke check**

With a local skill present (e.g. `./.opencode-hs/skills/explain/SKILL.md` from the README example): `stack run -- run`, type `/explain hello`, Enter.
Expected: the rendered body appears as your user message and a run starts — identical to pre-refactor behavior.

- [ ] **Step 5: Commit**

```bash
git add src/OpenCode/TUI/App.hs
git commit -m "M16: TUI invokeSkill delegates to the shared renderSkill path"
```

---

### Task 7: Documentation

**Files:**
- Modify: `README.md` (the `## Skills` section)
- Modify: `MILESTONES.md` (new M16 entry, matching the M15 entry's style, placed after it and before the `---` that precedes "Dependency notes")

- [ ] **Step 1: README**

In `README.md`, in the `## Skills` section, change the opening paragraph's first
two sentences from:

```markdown
A **skill** is a named instruction bundle you invoke as `/<name> [text]`. Running
a skill injects its rendered text as your next message and starts a run.
```

to:

```markdown
A **skill** is a named instruction bundle, invoked either by you as
`/<name> [text]` or autonomously by the model through the `skill` tool. A
user-typed skill injects its rendered text as your next message and starts a
run; a model-invoked skill returns its rendered text as a tool result mid-run.
```

and add one bullet to the list at the end of the section (after the
"loaded once at startup" bullet):

```markdown
- Every skill (local or MCP prompt) is also exposed to the model through a
  single `skill` tool whose description lists the available names — the model
  can decide mid-run to pull a skill's instructions into context. The name
  `skill` is reserved (a skill can't take it). With zero skills, the tool is
  not registered.
```

- [ ] **Step 2: MILESTONES**

Add an M16 entry after the M15 entry, using the same heading style as the
existing milestone entries, with this body:

```markdown
Skills become model-invokable. A single umbrella **`skill` tool** (built on the
M14 `DynamicTool` tag, registered only when at least one skill exists) exposes
every discovered skill — local `SKILL.md` and MCP prompts — to the model: the
tool's description enumerates `name — description (needs: args)` lines, the
input schema's `name` enum pins the valid names, and the executor returns the
rendered skill body as the tool result (progressive disclosure). Skill-level
failures (unknown name, missing required args, fetch errors, blank render) come
back as guidance text rather than thrown errors, so the model can self-correct.

New module `OpenCode.SkillTool` (`renderSkill`, `runSkillCall`, `skillTool`) is
the only module that imports both `Skill.*` and `MCP.*`; the pure builders
(`skillToolSchema`, `skillToolDescription`) live in `OpenCode.Skill.Registry`.
The TUI's `invokeSkill` now delegates to the shared `renderSkill`, so the
user-typed and model paths cannot drift. `Run.withAppEnv` registers the tool
into `envRegistry` (after the MCP additions, so `skill` is unshadowable) and
reserves the name `skill` in `buildSkillRegistry`. Headless `run --no-tui` gets
model-invoked skills for free. No new dependencies.
```

- [ ] **Step 3: Final verification**

Run: `stack build && stack test`
Expected: clean build, 0 failures.

- [ ] **Step 4: Commit**

```bash
git add README.md MILESTONES.md
git commit -m "M16: document model-invoked skills (README + MILESTONES)"
```
