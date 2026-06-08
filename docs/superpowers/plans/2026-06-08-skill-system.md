# Skill System (M15) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a unified skill system — local `SKILL.md` instruction bundles plus MCP prompts — invoked as `/<name> [text]`, injected as a user-turn message that starts a run.

**Architecture:** Four pure/IO `OpenCode.Skill.*` modules (Types → Parse → Registry, plus Discovery) that never import `MCP.*` or `TUI.*`. The unification (folding MCP prompts in) happens above them in `OpenCode.Run`, which maps each MCP `PromptEntry` to a `Skill` and merges with discovered local skills into `AppEnv.envSkills`. The TUI's old `/prompts` surface is renamed/retargeted to `/skills`.

**Tech Stack:** Haskell, GHC 9.6.6, Stack `lts-22.39`, hpack (`package.yaml`), hspec + hspec-discover, `yaml` (frontmatter), `temporary` (test temp dirs). No new dependencies.

**Conventions for every task:**
- Build: `~/.ghcup/bin/stack build --fast --ghc-options -Werror`
- Test (all): `~/.ghcup/bin/stack test --fast`
- Test (one spec): `~/.ghcup/bin/stack test --fast --ta '-m "Pattern"'`
- Lint: `hlint src test` (must print `No hints`)
- The library uses an **explicit** `library.exposed-modules` list — every new `src/` module must be added there.
- New test specs are auto-run by `hspec-discover` but must still be listed in the test component's `other-modules`.
- Every commit message ends with:
  `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`
- Spec reference: `docs/superpowers/specs/2026-06-08-skill-system-design.md`.

---

## File Structure

**New library modules:**
- `src/OpenCode/Skill/Types.hs` — `Skill`, `SkillSource` (pure data; no app deps).
- `src/OpenCode/Skill/Parse.hs` — frontmatter/body, `$ARGUMENTS`, invocation grammar (pure).
- `src/OpenCode/Skill/Registry.hs` — merge/lookup/match/autocomplete (pure).
- `src/OpenCode/Skill/Discovery.hs` — filesystem scan (IO; never throws).

**New tests:**
- `test/OpenCode/Skill/ParseSpec.hs`
- `test/OpenCode/Skill/RegistrySpec.hs`
- `test/OpenCode/Skill/DiscoverySpec.hs`

**Modified:**
- `src/OpenCode/App/Types.hs` — `envSkills :: [Skill]` on `AppEnv`.
- `src/OpenCode/Run.hs` — discover + map + register skills into `envSkills`.
- `src/OpenCode/TUI/Command.hs` — `CmdSkills` / `/skills`.
- `src/OpenCode/TUI/Types.hs` — `OverlaySkills [Skill]`.
- `src/OpenCode/TUI/Overlay.hs` — `skillsOverlay`, source-tagged rows.
- `src/OpenCode/TUI/App.hs` — skill routing (`openSkills`/`invokeSkill`/`selectSkill`, `onEnter`).
- `src/OpenCode/TUI/Render.hs` — autocomplete from skills.
- `src/OpenCode/MCP/Adapters.hs` — remove the now-centralized prompt helpers.
- `package.yaml` — register new modules + specs.
- Test `AppEnv` literals (13 across 10 files) — add `envSkills = []`.
- TUI specs (`CommandSpec`, `OverlaySpec`, `RenderSpec`), `MCP/AdaptersSpec`.
- `README.md`, `MILESTONES.md`.

---

## Task 1: Skill.Types + Skill.Parse (pure parsing layer)

**Files:**
- Create: `src/OpenCode/Skill/Types.hs`
- Create: `src/OpenCode/Skill/Parse.hs`
- Create: `test/OpenCode/Skill/ParseSpec.hs`
- Modify: `package.yaml`

- [ ] **Step 1: Create `src/OpenCode/Skill/Types.hs`**

```haskell
-- | Core skill data: a named instruction bundle and where it came from. Pure
-- data with no app-specific imports — in particular the MCP variant holds plain
-- 'Text', so this module does not depend on @OpenCode.MCP.*@.
module OpenCode.Skill.Types
  ( Skill (..)
  , SkillSource (..)
  ) where

import Data.Text (Text)

-- | Where a skill's text comes from.
data SkillSource
  = LocalSkill Text            -- ^ the SKILL.md body (may contain @$ARGUMENTS@)
  | McpPromptSkill Text Text   -- ^ server name, raw prompt name
  deriving stock (Show, Eq)

-- | A named, invocable instruction bundle.
data Skill = Skill
  { skName         :: Text     -- ^ invocation name, no leading slash
  , skDescription  :: Text     -- ^ shown in the listing
  , skRequiredArgs :: [Text]   -- ^ required arg names ([] for local skills)
  , skSource       :: SkillSource
  }
  deriving stock (Show, Eq)
```

- [ ] **Step 2: Register both modules in `package.yaml`**

In `library.exposed-modules`, immediately after the line `    - OpenCode.MCP.Startup`, add:

```yaml
    - OpenCode.Skill.Types
    - OpenCode.Skill.Parse
```

In the test component's `other-modules`, immediately after `      - OpenCode.MCP.StartupSpec`, add:

```yaml
      - OpenCode.Skill.ParseSpec
```

- [ ] **Step 3: Write the failing test `test/OpenCode/Skill/ParseSpec.hs`**

```haskell
{-# LANGUAGE OverloadedStrings #-}
module OpenCode.Skill.ParseSpec (spec) where

import Data.Either (isLeft)
import Test.Hspec

import OpenCode.Skill.Parse
import OpenCode.Skill.Types (Skill (..), SkillSource (..))

spec :: Spec
spec = do
  describe "splitFrontmatter" $ do
    it "splits frontmatter from body" $
      splitFrontmatter "---\nname: greet\n---\nhello\n"
        `shouldBe` (Just "name: greet\n", "hello\n")

    it "returns Nothing when there is no opening fence" $
      splitFrontmatter "just a body\n" `shouldBe` (Nothing, "just a body\n")

    it "treats an unterminated fence as all body" $
      splitFrontmatter "---\nname: x\nno close"
        `shouldBe` (Nothing, "---\nname: x\nno close")

  describe "parseSkillFile" $ do
    it "reads name, description, and body from frontmatter" $ do
      let r = parseSkillFile "dir"
                "---\nname: greet\ndescription: say hi\n---\nBody $ARGUMENTS\n"
      fmap skName r        `shouldBe` Right "greet"
      fmap skDescription r `shouldBe` Right "say hi"
      fmap skSource r      `shouldBe` Right (LocalSkill "Body $ARGUMENTS")

    it "defaults the name to the directory name when omitted" $
      fmap skName (parseSkillFile "mydir" "---\ndescription: d\n---\nbody\n")
        `shouldBe` Right "mydir"

    it "defaults the name when the frontmatter name is blank" $
      fmap skName (parseSkillFile "mydir" "---\nname: \"  \"\n---\nbody\n")
        `shouldBe` Right "mydir"

    it "uses the whole file as the body when there is no frontmatter" $
      fmap skSource (parseSkillFile "d" "plain body\n")
        `shouldBe` Right (LocalSkill "plain body")

    it "gives an empty description when omitted" $
      fmap skDescription (parseSkillFile "d" "body") `shouldBe` Right ""

    it "sets no required args for a local skill" $
      fmap skRequiredArgs (parseSkillFile "d" "body") `shouldBe` Right []

    it "reports a Left for malformed frontmatter" $
      parseSkillFile "d" "---\nnot an object\n---\nbody\n" `shouldSatisfy` isLeft

  describe "substituteArgs" $ do
    it "replaces every $ARGUMENTS token" $
      substituteArgs "a $ARGUMENTS b $ARGUMENTS" "X" `shouldBe` "a X b X"

    it "appends args after a blank line when there is no token" $
      substituteArgs "body" "tail" `shouldBe` "body\n\ntail"

    it "leaves the body unchanged when there are no args and no token" $
      substituteArgs "body" "  " `shouldBe` "body"

  describe "splitInvocation" $ do
    it "splits the name from the trailing free text" $
      splitInvocation "/greet make it formal" `shouldBe` Just ("greet", "make it formal")

    it "parses a bare name with empty rest" $
      splitInvocation "/greet" `shouldBe` Just ("greet", "")

    it "trims surrounding whitespace" $
      splitInvocation "   /greet   hi there  " `shouldBe` Just ("greet", "hi there")

    it "returns Nothing for non-slash input" $
      splitInvocation "hello" `shouldBe` Nothing

    it "returns Nothing for a bare slash" $
      splitInvocation "/" `shouldBe` Nothing

  describe "parseArgs" $ do
    it "parses key=value pairs" $
      parseArgs "name=ann lang=en" `shouldBe` [("name", "ann"), ("lang", "en")]

    it "ignores tokens without '='" $
      parseArgs "hello name=ann" `shouldBe` [("name", "ann")]

    it "splits on the first '=' only" $
      parseArgs "k=v=w" `shouldBe` [("k", "v=w")]

    it "passes an empty value through" $
      parseArgs "foo=" `shouldBe` [("foo", "")]

  describe "missingArgs" $ do
    it "reports required names that are absent" $
      missingArgs ["name", "lang"] [("name", "a")] `shouldBe` ["lang"]

    it "is empty when all present" $
      missingArgs ["name"] [("name", "a")] `shouldBe` []
```

- [ ] **Step 4: Run the test to verify it fails**

Run: `~/.ghcup/bin/stack test --fast --ta '-m "Skill.Parse"'`
Expected: compile failure — `OpenCode.Skill.Parse` not found / `splitFrontmatter` not in scope.

- [ ] **Step 5: Implement `src/OpenCode/Skill/Parse.hs`**

```haskell
{-# LANGUAGE OverloadedStrings #-}

-- | Pure parsing and rendering for skills: SKILL.md frontmatter/body, the
-- @$ARGUMENTS@ substitution, and the invocation-line grammar shared by local
-- skills and MCP-prompt skills. No IO.
module OpenCode.Skill.Parse
  ( splitFrontmatter
  , parseSkillFile
  , substituteArgs
  , splitInvocation
  , parseArgs
  , missingArgs
  ) where

import Data.Aeson (FromJSON (..), withObject, (.:?))
import Data.Bifunctor (first)
import Data.Char (isSpace)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Text.Encoding (encodeUtf8)
import qualified Data.Yaml as Yaml

import OpenCode.Skill.Types (Skill (..), SkillSource (LocalSkill))

-- | Optional SKILL.md frontmatter fields.
data Frontmatter = Frontmatter
  { fmName :: Maybe Text, fmDescription :: Maybe Text }

instance FromJSON Frontmatter where
  parseJSON = withObject "Frontmatter" $ \o ->
    Frontmatter <$> o .:? "name" <*> o .:? "description"

emptyFrontmatter :: Frontmatter
emptyFrontmatter = Frontmatter Nothing Nothing

-- | Split a file into (optional raw frontmatter, body). Frontmatter is the text
-- between a leading @---@ line and the next @---@ line. With no opening fence (or
-- no closing fence) the whole input is the body and the frontmatter is 'Nothing'.
splitFrontmatter :: Text -> (Maybe Text, Text)
splitFrontmatter content =
  case T.lines content of
    (h : rest) | T.strip h == "---" ->
      case break ((== "---") . T.strip) rest of
        (fmLines, _closing : bodyLines) -> (Just (T.unlines fmLines), T.unlines bodyLines)
        (_, [])                         -> (Nothing, content)  -- unterminated fence
    _ -> (Nothing, content)

-- | Parse a SKILL.md file into a local 'Skill'. The first argument is the
-- fallback name (the skill's directory name), used when the frontmatter omits a
-- non-blank @name@. 'Left' carries a human-readable YAML error.
parseSkillFile :: Text -> Text -> Either Text Skill
parseSkillFile defName content = do
  let (mfm, body) = splitFrontmatter content
  fm <- maybe (Right emptyFrontmatter) decodeFrontmatter mfm
  Right Skill
    { skName         = fromMaybe defName (nonBlank =<< fmName fm)
    , skDescription  = fromMaybe "" (fmDescription fm)
    , skRequiredArgs = []
    , skSource       = LocalSkill (T.strip body)
    }
  where
    nonBlank t = if T.null (T.strip t) then Nothing else Just t
    decodeFrontmatter t
      | T.null (T.strip t) = Right emptyFrontmatter
      | otherwise = first (T.pack . Yaml.prettyPrintParseException)
                          (Yaml.decodeEither' (encodeUtf8 t))

-- | Render a skill body for the given trailing arguments. Every literal
-- @$ARGUMENTS@ is replaced by the args; if the body has no such token and the
-- args are non-empty, they are appended after a blank line.
substituteArgs :: Text -> Text -> Text
substituteArgs body args
  | placeholder `T.isInfixOf` body = T.replace placeholder args body
  | T.null (T.strip args)          = body
  | otherwise                      = body <> "\n\n" <> args
  where placeholder = "$ARGUMENTS"

-- | Split a @\/word rest...@ invocation line into (name without slash, trailing
-- text trimmed). 'Nothing' if not slash-prefixed or the name is empty.
splitInvocation :: Text -> Maybe (Text, Text)
splitInvocation raw =
  let s = T.stripStart raw
  in case T.uncons s of
       Just ('/', _) ->
         let (w, rest) = T.break isSpace s
             nm        = T.drop 1 w
         in if T.null nm then Nothing else Just (nm, T.strip rest)
       _ -> Nothing

-- | Parse @key=value@ tokens from trailing text. Splits each token on its first
-- @=@; tokens without @=@ are ignored; an empty value (@k=@) passes through.
parseArgs :: Text -> [(Text, Text)]
parseArgs rest =
  [ (k, T.drop 1 vEq)
  | tok <- T.words rest
  , let (k, vEq) = T.breakOn "=" tok
  , not (T.null k), not (T.null vEq)
  ]

-- | Required arg names absent from the supplied key=value pairs.
missingArgs :: [Text] -> [(Text, Text)] -> [Text]
missingArgs required supplied = [ a | a <- required, a `notElem` map fst supplied ]
```

- [ ] **Step 6: Run the test to verify it passes**

Run: `~/.ghcup/bin/stack test --fast --ta '-m "Skill.Parse"'`
Expected: all `Skill.Parse` examples pass.

- [ ] **Step 7: Lint + full build**

Run: `hlint src test` → `No hints`. Run: `~/.ghcup/bin/stack build --fast --ghc-options -Werror` → clean.

- [ ] **Step 8: Commit**

```bash
git add src/OpenCode/Skill/Types.hs src/OpenCode/Skill/Parse.hs test/OpenCode/Skill/ParseSpec.hs package.yaml
git commit -m "M15: Skill.Types + Skill.Parse (frontmatter, \$ARGUMENTS, invocation grammar)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 2: Skill.Registry (merge / lookup / match / autocomplete)

**Files:**
- Create: `src/OpenCode/Skill/Registry.hs`
- Create: `test/OpenCode/Skill/RegistrySpec.hs`
- Modify: `package.yaml`

- [ ] **Step 1: Register the module in `package.yaml`**

In `library.exposed-modules`, after `    - OpenCode.Skill.Parse`, add:

```yaml
    - OpenCode.Skill.Registry
```

In the test `other-modules`, after `      - OpenCode.Skill.ParseSpec`, add:

```yaml
      - OpenCode.Skill.RegistrySpec
```

- [ ] **Step 2: Write the failing test `test/OpenCode/Skill/RegistrySpec.hs`**

```haskell
{-# LANGUAGE OverloadedStrings #-}
module OpenCode.Skill.RegistrySpec (spec) where

import Data.Text (Text)
import Test.Hspec

import OpenCode.Skill.Registry
import OpenCode.Skill.Types (Skill (..), SkillSource (..))

mkLocal :: Text -> Text -> Skill
mkLocal n d = Skill n d [] (LocalSkill "body")

mkMcp :: Text -> Skill
mkMcp n = Skill n "" [] (McpPromptSkill "srv" n)

spec :: Spec
spec = do
  describe "buildSkillRegistry" $ do
    it "keeps the first skill on a name clash (project over user over mcp)" $ do
      let proj = mkLocal "greet" "project"
          user = mkLocal "greet" "user"
          mcp  = mkMcp "greet"
      map skDescription (buildSkillRegistry [] [proj, user, mcp]) `shouldBe` ["project"]

    it "drops skills whose name is reserved" $
      map skName (buildSkillRegistry ["help"] [mkLocal "help" "x", mkLocal "greet" "y"])
        `shouldBe` ["greet"]

    it "preserves order and de-duplicates" $
      map skName (buildSkillRegistry [] [mkLocal "a" "", mkLocal "b" "", mkLocal "a" ""])
        `shouldBe` ["a", "b"]

  describe "lookupSkill" $ do
    it "finds a skill by name" $
      fmap skName (lookupSkill "b" [mkLocal "a" "", mkLocal "b" ""]) `shouldBe` Just "b"
    it "is Nothing when absent" $
      lookupSkill "z" [mkLocal "a" ""] `shouldBe` Nothing

  describe "matchSkill" $ do
    it "resolves an invocation to a skill and its trailing text" $ do
      let ss = [mkLocal "greet" ""]
      fmap (skName . fst) (matchSkill ss "/greet hi there") `shouldBe` Just "greet"
      fmap snd            (matchSkill ss "/greet hi there") `shouldBe` Just "hi there"
    it "is Nothing for an unknown name" $
      matchSkill [mkLocal "greet" ""] "/nope" `shouldBe` Nothing
    it "is Nothing for non-slash input" $
      matchSkill [mkLocal "greet" ""] "hello" `shouldBe` Nothing

  describe "skillSuggestEntries" $
    it "slash-prefixes names and pairs them with descriptions" $
      skillSuggestEntries [mkLocal "greet" "say hi"] `shouldBe` [("/greet", "say hi")]
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `~/.ghcup/bin/stack test --fast --ta '-m "Skill.Registry"'`
Expected: compile failure — `OpenCode.Skill.Registry` not found.

- [ ] **Step 4: Implement `src/OpenCode/Skill/Registry.hs`**

```haskell
{-# LANGUAGE OverloadedStrings #-}

-- | Pure merge, lookup, and autocomplete for the unified skill list. Knows
-- nothing of MCP or the TUI — callers pass candidates already in precedence
-- order and a list of reserved (built-in command) names to exclude.
module OpenCode.Skill.Registry
  ( buildSkillRegistry
  , lookupSkill
  , matchSkill
  , skillSuggestEntries
  ) where

import Data.List (find)
import Data.Text (Text)

import OpenCode.Skill.Parse (splitInvocation)
import OpenCode.Skill.Types (Skill (..))

-- | Merge candidate skills into a registry. Earlier candidates win on a name
-- clash, and any candidate whose name is reserved (a built-in command) is
-- dropped. Callers order candidates project-skills, then user-skills, then
-- MCP-prompt skills, giving precedence built-in > project > user > mcp.
buildSkillRegistry :: [Text] -> [Skill] -> [Skill]
buildSkillRegistry reserved = go []
  where
    go acc [] = reverse acc
    go acc (s : ss)
      | skName s `elem` reserved        = go acc ss
      | skName s `elem` map skName acc  = go acc ss
      | otherwise                       = go (s : acc) ss

-- | Find a skill by exact name.
lookupSkill :: Text -> [Skill] -> Maybe Skill
lookupSkill nm = find ((== nm) . skName)

-- | Resolve an invocation line against the registry: split the @\/name rest@
-- line, look the name up, and return the skill with the raw trailing text.
matchSkill :: [Skill] -> Text -> Maybe (Skill, Text)
matchSkill skills body = do
  (nm, rest) <- splitInvocation body
  s          <- lookupSkill nm skills
  pure (s, rest)

-- | Autocomplete entries (slash-prefixed name + description) for the registry.
skillSuggestEntries :: [Skill] -> [(Text, Text)]
skillSuggestEntries = map (\s -> ("/" <> skName s, skDescription s))
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `~/.ghcup/bin/stack test --fast --ta '-m "Skill.Registry"'`
Expected: all `Skill.Registry` examples pass.

- [ ] **Step 6: Lint + full build**

Run: `hlint src test` → `No hints`. Run: `~/.ghcup/bin/stack build --fast --ghc-options -Werror` → clean.

- [ ] **Step 7: Commit**

```bash
git add src/OpenCode/Skill/Registry.hs test/OpenCode/Skill/RegistrySpec.hs package.yaml
git commit -m "M15: Skill.Registry (precedence merge, lookup, match, autocomplete)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 3: Skill.Discovery (filesystem scan)

**Files:**
- Create: `src/OpenCode/Skill/Discovery.hs`
- Create: `test/OpenCode/Skill/DiscoverySpec.hs`
- Modify: `package.yaml`

- [ ] **Step 1: Register the module in `package.yaml`**

In `library.exposed-modules`, after `    - OpenCode.Skill.Registry`, add:

```yaml
    - OpenCode.Skill.Discovery
```

In the test `other-modules`, after `      - OpenCode.Skill.RegistrySpec`, add:

```yaml
      - OpenCode.Skill.DiscoverySpec
```

- [ ] **Step 2: Write the failing test `test/OpenCode/Skill/DiscoverySpec.hs`**

```haskell
{-# LANGUAGE OverloadedStrings #-}
module OpenCode.Skill.DiscoverySpec (spec) where

import Data.Text (Text)
import qualified Data.Text.IO as TIO
import System.Directory (createDirectoryIfMissing)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

import OpenCode.Skill.Discovery
import OpenCode.Skill.Types (Skill (..))

-- | Write @<root>/<name>/SKILL.md@ with the given contents.
writeSkill :: FilePath -> FilePath -> Text -> IO ()
writeSkill root name contents = do
  let dir = root </> name
  createDirectoryIfMissing True dir
  TIO.writeFile (dir </> "SKILL.md") contents

spec :: Spec
spec = describe "discoverSkillsIn" $ do
  it "finds skills in a single root, sorted by directory name" $
    withSystemTempDirectory "skills-one" $ \root -> do
      writeSkill root "beta"  "---\ndescription: b\n---\nB"
      writeSkill root "alpha" "---\ndescription: a\n---\nA"
      (skills, diags) <- discoverSkillsIn [root]
      map skName skills `shouldBe` ["alpha", "beta"]
      diags `shouldBe` []

  it "returns both roots' skills in root order (project first)" $
    withSystemTempDirectory "skills-proj" $ \proj ->
      withSystemTempDirectory "skills-user" $ \user -> do
        writeSkill proj "greet" "---\ndescription: project\n---\nP"
        writeSkill user "greet" "---\ndescription: user\n---\nU"
        (skills, _) <- discoverSkillsIn [proj, user]
        map skDescription skills `shouldBe` ["project", "user"]

  it "collects a diagnostic for a malformed SKILL.md and keeps the good ones" $
    withSystemTempDirectory "skills-bad" $ \root -> do
      writeSkill root "good" "---\ndescription: ok\n---\nbody"
      writeSkill root "bad"  "---\nnot an object\n---\nbody"
      (skills, diags) <- discoverSkillsIn [root]
      map skName skills `shouldBe` ["good"]
      map sdSkill diags `shouldBe` ["bad"]

  it "ignores a directory without a SKILL.md" $
    withSystemTempDirectory "skills-empty" $ \root -> do
      createDirectoryIfMissing True (root </> "notaskill")
      (skills, diags) <- discoverSkillsIn [root]
      skills `shouldBe` []
      diags  `shouldBe` []

  it "returns nothing for a non-existent root" $ do
    (skills, diags) <- discoverSkillsIn ["/no/such/path/skills"]
    skills `shouldBe` []
    diags  `shouldBe` []
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `~/.ghcup/bin/stack test --fast --ta '-m "discoverSkillsIn"'`
Expected: compile failure — `OpenCode.Skill.Discovery` not found.

- [ ] **Step 4: Implement `src/OpenCode/Skill/Discovery.hs`**

```haskell
{-# LANGUAGE OverloadedStrings #-}

-- | Filesystem discovery of local skills. Scans skill roots in precedence order,
-- parses each @<root>/<name>/SKILL.md@, and collects a diagnostic for any skill
-- that cannot be read or parsed. Never throws.
module OpenCode.Skill.Discovery
  ( SkillDiagnostic (..)
  , discoverSkillsIn
  , defaultSkillRoots
  , discoverSkills
  ) where

import Control.Exception (IOException, try)
import Data.Either (partitionEithers)
import Data.List (sort)
import Data.Maybe (catMaybes)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import System.Directory
  ( doesDirectoryExist, doesFileExist, getCurrentDirectory
  , getHomeDirectory, listDirectory )
import System.FilePath ((</>))

import OpenCode.Skill.Parse (parseSkillFile)
import OpenCode.Skill.Types (Skill)

-- | One skill that was skipped, and why.
data SkillDiagnostic = SkillDiagnostic
  { sdSkill :: Text, sdReason :: Text }
  deriving stock (Show, Eq)

-- | Scan the given roots (in precedence order) for local skills. Within a root,
-- skills are returned sorted by directory name.
discoverSkillsIn :: [FilePath] -> IO ([Skill], [SkillDiagnostic])
discoverSkillsIn roots = do
  perRoot <- mapM scanRoot roots
  let (diags, skills) = partitionEithers (concat perRoot)
  pure (skills, diags)

-- | The default roots: project (@<cwd>/.opencode-hs/skills@) then user
-- (@<home>/.config/opencode-hs/skills@).
defaultSkillRoots :: IO [FilePath]
defaultSkillRoots = do
  cwd  <- getCurrentDirectory
  home <- getHomeDirectory
  pure [ cwd  </> ".opencode-hs" </> "skills"
       , home </> ".config" </> "opencode-hs" </> "skills" ]

-- | Discover skills under the default roots.
discoverSkills :: IO ([Skill], [SkillDiagnostic])
discoverSkills = defaultSkillRoots >>= discoverSkillsIn

-- | One root → results (errors 'Left', skills 'Right'); [] if the root is absent.
scanRoot :: FilePath -> IO [Either SkillDiagnostic Skill]
scanRoot root = do
  exists <- doesDirectoryExist root
  if not exists
    then pure []
    else do
      names   <- sort <$> listDirectory root
      results <- mapM (loadSkill root) names
      pure (catMaybes results)

-- | Load one @<root>/<name>/SKILL.md@. 'Nothing' for entries that are not a
-- directory or lack a SKILL.md (silently ignored, not a diagnostic).
loadSkill :: FilePath -> FilePath -> IO (Maybe (Either SkillDiagnostic Skill))
loadSkill root name = do
  let dir  = root </> name
      file = dir </> "SKILL.md"
  isDir   <- doesDirectoryExist dir
  hasFile <- doesFileExist file
  if not (isDir && hasFile)
    then pure Nothing
    else do
      r <- try (TIO.readFile file) :: IO (Either IOException Text)
      pure . Just $ case r of
        Left e        -> Left (SkillDiagnostic (T.pack name) (T.pack (show e)))
        Right content -> case parseSkillFile (T.pack name) content of
          Left err -> Left (SkillDiagnostic (T.pack name) err)
          Right sk -> Right sk
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `~/.ghcup/bin/stack test --fast --ta '-m "discoverSkillsIn"'`
Expected: all `discoverSkillsIn` examples pass.

- [ ] **Step 6: Lint + full build**

Run: `hlint src test` → `No hints`. Run: `~/.ghcup/bin/stack build --fast --ghc-options -Werror` → clean.

- [ ] **Step 7: Commit**

```bash
git add src/OpenCode/Skill/Discovery.hs test/OpenCode/Skill/DiscoverySpec.hs package.yaml
git commit -m "M15: Skill.Discovery (scan project + user skill roots, never throws)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 4: AppEnv.envSkills (wire the field through, default [])

This task adds the field and sets it to `[]` everywhere so the tree stays green. Task 6 replaces the production `[]` with the discovered list.

**Files:**
- Modify: `src/OpenCode/App/Types.hs`
- Modify: `src/OpenCode/Run.hs:126-133` (the `AppEnv` literal)
- Modify: every test `AppEnv` literal (13 across 10 files; see Step 3)

- [ ] **Step 1: Add the field to `AppEnv`**

In `src/OpenCode/App/Types.hs`, add the import (after the existing `import OpenCode.MCP.Client (McpClient)` line):

```haskell
import OpenCode.Skill.Types (Skill)
```

Add the field to the `AppEnv` record — change:

```haskell
  , envMcp       :: [McpClient]
  }
```

to:

```haskell
  , envMcp       :: [McpClient]
  , envSkills    :: [Skill]
  }
```

- [ ] **Step 2: Set the field in the production literal**

In `src/OpenCode/Run.hs`, in the `AppEnv { … }` record inside `withAppEnv`, add `envSkills = []` after the `envMcp = clients` line:

```haskell
              , envMcp       = clients
              , envSkills    = []
              }
```

- [ ] **Step 3: Build to find every test literal, then add `envSkills = []`**

Run: `~/.ghcup/bin/stack build --fast --ghc-options -Werror`
Expected: `-Wmissing-fields` errors (one per `AppEnv` literal lacking `envSkills`). They are in:

- `test/OpenCode/TestEnv.hs` (two literals: `withTestEnv`, `mkDummyEnv`)
- `test/OpenCode/SessionSpec.hs`
- `test/OpenCode/Tool/BashSpec.hs`
- `test/OpenCode/Tool/EditFileSpec.hs`
- `test/OpenCode/Tool/GlobSpec.hs`
- `test/OpenCode/Tool/GrepSpec.hs`
- `test/OpenCode/Tool/ReadFileSpec.hs`
- `test/OpenCode/Tool/RegistrySpec.hs`
- `test/OpenCode/Tool/TypesSpec.hs`
- `test/OpenCode/Tool/WriteFileSpec.hs`

In each `AppEnv { … }` record, add `envSkills = []` directly after the `envMcp = []` (or `envMcp = …`) line. Re-run the build until there are no `-Wmissing-fields` errors. (The compiler enumerates every site, so use its output as the checklist.)

- [ ] **Step 4: Run the full suite**

Run: `~/.ghcup/bin/stack test --fast`
Expected: all examples pass (no behavior change yet).

- [ ] **Step 5: Lint + build**

Run: `hlint src test` → `No hints`. Run: `~/.ghcup/bin/stack build --fast --ghc-options -Werror` → clean.

- [ ] **Step 6: Commit**

```bash
git add src/OpenCode/App/Types.hs src/OpenCode/Run.hs test/
git commit -m "M15: add AppEnv.envSkills (defaulted to [] across the tree)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 5: TUI surface — rename /prompts to /skills, retarget overlay + routing

This is one atomic change: `Command`, `Types`, `Overlay`, `App`, `Render` and their specs all reference the same constructors, so they change together. `envSkills` is still `[]` after this task (Task 6 fills it), so `openSkills` shows "no skills available" until then — tests construct skills directly and do not depend on Run.

**Files:**
- Modify: `src/OpenCode/TUI/Command.hs`
- Modify: `src/OpenCode/TUI/Types.hs`
- Modify: `src/OpenCode/TUI/Overlay.hs`
- Modify: `src/OpenCode/TUI/App.hs`
- Modify: `src/OpenCode/TUI/Render.hs`
- Modify: `test/OpenCode/TUI/CommandSpec.hs`
- Modify: `test/OpenCode/TUI/OverlaySpec.hs`
- Modify: `test/OpenCode/TUI/RenderSpec.hs`

- [ ] **Step 1: Update the TUI spec expectations (the failing tests)**

In `test/OpenCode/TUI/CommandSpec.hs`:
- Replace line 23 `it "parses /prompts" $ parseCommand "/prompts" \`shouldBe\` Just CmdPrompts` with:

```haskell
    it "parses /skills" $ parseCommand "/skills" `shouldBe` Just CmdSkills
```

- In the bare-slash catalog-order assertion (currently line ~46), replace `"/prompts"` with `"/skills"`:

```haskell
        ["/new", "/sessions", "/model", "/skills", "/help", "/quit"]
```

- In the "includes prompts after built-ins for a bare slash" assertion (currently line ~78), replace `"/prompts"` with `"/skills"`:

```haskell
        `shouldBe` ["/new", "/sessions", "/model", "/skills", "/help", "/quit", "/srv_greet", "/srv_bye"]
```

In `test/OpenCode/TUI/OverlaySpec.hs`:
- Change the import line `  ( helpOverlay, modelsOverlay, overlayCount, overlayLabels, overlayMove` / `  , overlaySelected, promptsOverlay, sessionsOverlay )` so `promptsOverlay` becomes `skillsOverlay`.
- Replace the import `import OpenCode.MCP.Adapters (PromptEntry (..))` with:

```haskell
import OpenCode.Skill.Types (Skill (..), SkillSource (..))
```

- Replace the entire `describe "promptsOverlay"` block (currently lines 49-55) with:

```haskell
  describe "skillsOverlay" $ do
    it "labels rows by name, description, and source tag" $ do
      let ss = [ Skill "greet" "say hi" [] (LocalSkill "b")
               , Skill "srv_bye" "" ["x"] (McpPromptSkill "srv" "bye") ]
          ov = skillsOverlay ss
      overlayLabels (ovKind ov) `shouldBe` ["greet  say hi", "srv_bye  (mcp:srv)"]
      overlayCount (ovKind ov)  `shouldBe` 2
```

In `test/OpenCode/TUI/RenderSpec.hs`:
- In the "shows all six commands for a bare '/'" test, replace the `/prompts` line (currently line 194):

```haskell
      show pic `shouldContain` "run a skill"            -- /skills
```

- [ ] **Step 2: Run the TUI specs to verify they fail**

Run: `~/.ghcup/bin/stack test --fast --ta '-m "Command"'`
Expected: compile failure — `CmdSkills` / `skillsOverlay` not in scope.

- [ ] **Step 3: Update `src/OpenCode/TUI/Command.hs`**

- In the `Command` data type, replace the `CmdPrompts` constructor line:

```haskell
  | CmdSkills         -- ^ @/skills@ — pick a skill (local or MCP prompt) to run
```

- In `classify`, replace the `"/prompts"  -> CmdPrompts` line:

```haskell
      "/skills"   -> CmdSkills
```

- In `commandCatalog`, replace the `(CmdPrompts,  "/prompts",  "run an MCP prompt")` row:

```haskell
  , (CmdSkills,   "/skills",   "run a skill")
```

- [ ] **Step 4: Update `src/OpenCode/TUI/Types.hs`**

- Replace the import `import OpenCode.MCP.Adapters (PromptEntry)` with:

```haskell
import OpenCode.Skill.Types (Skill)
```

- In `OverlayKind`, replace the `OverlayPrompts [PromptEntry]` constructor line:

```haskell
  | OverlaySkills   [Skill]                -- ^ discovered skills (pick to run)
```

- [ ] **Step 5: Update `src/OpenCode/TUI/Overlay.hs`**

- In the export list, replace `promptsOverlay` with `skillsOverlay`.
- Replace the import `import OpenCode.MCP.Adapters (PromptEntry (..))` with:

```haskell
import OpenCode.Skill.Types (Skill (..), SkillSource (..))
```

- In `overlayCount`, replace `OverlayPrompts es -> length es`:

```haskell
  OverlaySkills   ss   -> length ss
```

- In `overlayLabels`, replace `OverlayPrompts es -> map promptRow es`:

```haskell
  OverlaySkills   ss     -> map skillRow ss
```

- In the `where` block of `overlayLabels`, replace the `promptRow` definition with `skillRow` (place it alongside `modelRow`):

```haskell
    skillRow s = skName s <> descPart (skDescription s) <> srcTag (skSource s)
    descPart d | T.null d  = ""
               | otherwise = "  " <> d
    srcTag (LocalSkill _)         = ""
    srcTag (McpPromptSkill srv _) = "  (mcp:" <> srv <> ")"
```

- Replace the `promptsOverlay` smart constructor (and its Haddock) with:

```haskell
-- | A picker over the discovered skills (local + MCP prompts).
skillsOverlay :: [Skill] -> Overlay
skillsOverlay ss = Overlay
  { ovTitle = "skills"
  , ovSel   = 0
  , ovKind  = OverlaySkills ss
  }
```

- [ ] **Step 6: Update `src/OpenCode/TUI/App.hs`**

- **Imports.** Remove the MCP.Adapters import block:

```haskell
import OpenCode.MCP.Adapters
  ( PromptEntry (..), promptEntries, promptSuggestEntries
  , parsePromptInvocation, missingArgs )
```

  Keep the existing `import OpenCode.MCP.Client (McpClient (..), McpError, getPrompt, renderMcpError)` and `import OpenCode.MCP.Protocol (GetPromptResult (..), PromptMessage (..))`. Add:

```haskell
import OpenCode.Skill.Types (Skill (..), SkillSource (..))
import OpenCode.Skill.Parse (substituteArgs, parseArgs, missingArgs)
import OpenCode.Skill.Registry (matchSkill, skillSuggestEntries)
```

  In the `OpenCode.TUI.Overlay` import list, change `promptsOverlay` to `skillsOverlay`.

- **`suggestEntries`** — replace the body:

```haskell
-- | Autocomplete entries for the current state: built-ins + skills.
suggestEntries :: AppState -> [(Text, Text)]
suggestEntries st =
  commandSuggestions (skillSuggestEntries (envSkills (asEnv st))) (currentInput st)
```

- **`runHighlighted`** — update the Haddock to mention skills (replace "MCP prompt" / "matchPrompt" wording); the body is unchanged:

```haskell
-- | Enter while the panel is open: set the input to the highlighted name and
-- reuse 'onEnter', so a highlighted skill flows through the skill path (via
-- 'matchSkill') and a built-in through 'parseCommand'. Falls back to the normal
-- submit path if, defensively, there is no highlight.
```

- **`onEnter`** — replace the whole function with:

```haskell
-- | The Enter action in normal mode. A non-slash line is submitted to the LLM.
-- A slash line that names a built-in dispatches that command (built-ins win). An
-- unrecognized slash word is tried as a skill invocation (gated to Idle like the
-- context commands, so a skill can't start a second concurrent run); if no skill
-- matches it falls back to the unknown-command notice. NB: 'invokeSkill' clears
-- the input itself — do not clear it on that path.
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
    Just cmd@(CmdUnknown _) -> case matchSkill (envSkills (asEnv st)) body of
      Just (skill, rest)
        | asRunState st == Idle -> invokeSkill skill rest st
        | otherwise -> put st { asNotice = Just "press Esc to abort the run first" }
      Nothing -> do
        put st { asInput = emptyEditor, asNotice = Nothing }
        dispatchCommand cmd
    Just cmd -> do
      put st { asInput = emptyEditor, asNotice = Nothing }
      dispatchCommand cmd
```

- **`dispatchCommand`** — replace the `CmdPrompts` arm:

```haskell
    CmdSkills    -> whenIdle st (openSkills st)
```

- **`commitOverlay`** — replace the `OverlayPrompts` arm:

```haskell
      OverlaySkills ss     -> maybe (put st { asMode = ModeNormal })
                                    (\s -> selectSkill s st { asMode = ModeNormal, asNotice = Nothing })
                                    (safeIndex ss i)
```

- **Replace `openPrompts`** with:

```haskell
-- | /skills: open a picker of all discovered skills (local + MCP prompts).
openSkills :: AppState -> EventM ResourceName AppState ()
openSkills st = case envSkills (asEnv st) of
  [] -> put st { asNotice = Just "no skills available" }
  ss -> put st { asMode = ModeOverlay (skillsOverlay ss) }
```

- **Replace `selectPrompt`** with:

```haskell
-- | Commit a skill selection from the overlay. No required args -> run now;
-- otherwise close the overlay and prefill @\/<name> @ for the user to add
-- key=value arguments (MCP prompts only — local skills have no required args).
selectSkill :: Skill -> AppState -> EventM ResourceName AppState ()
selectSkill s st
  | null (skRequiredArgs s) = invokeSkill s "" st { asMode = ModeNormal }
  | otherwise = put st
      { asMode  = ModeNormal
      , asInput = E.editorText InputEditor (Just 1) ("/" <> skName s <> " ")
      }
```

- **Delete `matchPrompt` and `allPromptEntries`** entirely (matching now lives in `matchSkill`).

- **Replace `invokePrompt`** with `invokeSkill` plus a shared `runText` helper:

```haskell
-- | Run a skill. Local skills render their body with the trailing free text
-- substituted for @$ARGUMENTS@; MCP-prompt skills validate required args and
-- fetch via 'getPrompt'. Either way the resulting text is injected as a user
-- turn and run. 'invokeSkill' clears the input on every branch.
invokeSkill :: Skill -> Text -> AppState -> EventM ResourceName AppState ()
invokeSkill skill rest st = case skSource skill of
  LocalSkill body ->
    let rendered = substituteArgs body (T.strip rest)
    in if T.null (T.strip rendered)
         then put st { asInput = emptyEditor, asNotice = Just "skill produced no content" }
         else runText rendered st
  McpPromptSkill server prompt -> case missingArgs (skRequiredArgs skill) args of
    (m : _) -> put st { asInput = emptyEditor, asNotice = Just ("missing required arg: " <> m) }
    []      -> case find ((== server) . mcName) (envMcp (asEnv st)) of
      Nothing -> put st { asInput = emptyEditor, asNotice = Just "prompt server unavailable" }
      Just c  -> do
        result <- liftIO (try (getPrompt c prompt args)
                            :: IO (Either SomeException (Either McpError GetPromptResult)))
        case result of
          Left ex        -> put st { asInput = emptyEditor
                                   , asNotice = Just ("prompt error: " <> T.pack (displayException ex)) }
          Right (Left e) -> put st { asInput = emptyEditor
                                   , asNotice = Just ("prompt error: " <> renderMcpError e) }
          Right (Right gp) ->
            let promptText = T.intercalate "\n\n" (map pmText (gprMessages gp))
            in if T.null (T.strip promptText)
                 then put st { asInput = emptyEditor, asNotice = Just "prompt returned no content" }
                 else runText promptText st
  where args = parseArgs rest

-- | Inject text as a user turn, clear the input, and start the run. Shared by
-- both skill sources. Uses 'appendUserMessage' (unconditional append + clear)
-- rather than 'applyEnter' (whose 'shouldSubmit' guard would reject the input).
runText :: Text -> AppState -> EventM ResourceName AppState ()
runText body st = do
  msg <- liftIO (mkUserMessage body)
  put ((appendUserMessage msg st)
         { asRunState = RunningLLM, asNotice = Nothing, asSuggestSel = 0 })
  liftIO (startRun (asEnv st) (asSessionId st) body)
  M.vScrollToEnd chatScroll
```

- [ ] **Step 7: Update `src/OpenCode/TUI/Render.hs`**

- Replace the import `import OpenCode.MCP.Adapters (promptSuggestEntries)` with:

```haskell
import OpenCode.Skill.Registry (skillSuggestEntries)
```

- In `suggestBox`, replace `commandSuggestions (promptSuggestEntries (envMcp (asEnv st))) (currentInputText st)` with:

```haskell
  case commandSuggestions (skillSuggestEntries (envSkills (asEnv st))) (currentInputText st) of
```

  `Render` imports `OpenCode.App.Types (AppEnv (..))` (a wildcard), so `envSkills` is already in scope and the now-unused `envMcp` accessor raises no `-Wunused-imports` warning — no import line beyond the `promptSuggestEntries` → `skillSuggestEntries` swap needs to change.

- [ ] **Step 8: Run the TUI specs, then the full suite**

Run: `~/.ghcup/bin/stack test --fast --ta '-m "Command"'` then `--ta '-m "Overlay"'` then `--ta '-m "Render"'`
Expected: pass. Then run `~/.ghcup/bin/stack test --fast` — all pass. (`AppSpec` uses only the exported pure reducers and `newDummyEnv`, so it needs no changes; confirm it still builds.)

- [ ] **Step 9: Lint + build**

Run: `hlint src test` → `No hints`. Run: `~/.ghcup/bin/stack build --fast --ghc-options -Werror` → clean.

- [ ] **Step 10: Commit**

```bash
git add src/OpenCode/TUI/ test/OpenCode/TUI/
git commit -m "M15: TUI skills surface (/skills overlay + autocomplete + invocation routing)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 6: Run wiring — discover skills, fold MCP prompts in, populate envSkills

**Files:**
- Modify: `src/OpenCode/Run.hs`

- [ ] **Step 1: Add imports to `src/OpenCode/Run.hs`**

After the existing `import OpenCode.MCP.Startup ( … )` block, add:

```haskell
import OpenCode.MCP.Adapters (PromptEntry (..), promptEntries)
import OpenCode.Skill.Discovery (SkillDiagnostic (..), discoverSkills)
import OpenCode.Skill.Registry (buildSkillRegistry)
import OpenCode.Skill.Types (Skill (..), SkillSource (McpPromptSkill))
import OpenCode.TUI.Command (commandCatalog)
```

- [ ] **Step 2: Discover + build skills inside `withAppEnv`**

In `withAppEnv`, inside the `bracket … $ \(clients, diags) -> do` block, after `reportMcpDiagnostics diags`, insert:

```haskell
        (localSkills, skillDiags) <- if spawnMcp then discoverSkills else pure ([], [])
        reportSkillDiagnostics skillDiags
        let reserved  = [ T.drop 1 name | (_, name, _) <- commandCatalog ]
            mcpSkills =
              [ Skill { skName         = peFullName e
                      , skDescription  = peDescription e
                      , skRequiredArgs = peRequiredArgs e
                      , skSource       = McpPromptSkill (peServer e) (peName e)
                      }
              | c <- clients, e <- promptEntries c ]
            skills = buildSkillRegistry reserved (localSkills ++ mcpSkills)
```

- [ ] **Step 3: Use `skills` in the `AppEnv` literal**

Replace the `envSkills = []` line added in Task 4 with:

```haskell
              , envSkills    = skills
              }
```

- [ ] **Step 4: Add the diagnostic reporter**

Next to `reportMcpDiagnostics`, add:

```haskell
-- | Skill-discovery diagnostics go to stderr, like the MCP ones.
reportSkillDiagnostics :: [SkillDiagnostic] -> IO ()
reportSkillDiagnostics =
  mapM_ (\d -> TIO.hPutStrLn stderr
    ("opencode-hs: skill '" <> sdSkill d <> "' skipped: " <> sdReason d))
```

- [ ] **Step 5: Update the `withAppEnv` Haddock**

Extend the comment on `withAppEnv` to note that, under the same `spawnMcp` gate, local skills are discovered and merged with MCP prompts into `envSkills`.

- [ ] **Step 6: Build + full suite**

Run: `~/.ghcup/bin/stack build --fast --ghc-options -Werror` → clean (watch for `-Wunused-imports`: if `Skill (..)` brings in unused field selectors, GHC does not warn on those; the import is used by the record construction).
Run: `~/.ghcup/bin/stack test --fast` — all pass (`RunSpec` only tests `armOnce`/`onSigInt`/`renderDbError`, unaffected).

- [ ] **Step 7: Lint**

Run: `hlint src test` → `No hints`.

- [ ] **Step 8: Commit**

```bash
git add src/OpenCode/Run.hs
git commit -m "M15: discover local skills + fold MCP prompts into AppEnv.envSkills

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 7: MCP.Adapters cleanup — remove the centralized prompt helpers

The invocation grammar now lives in `Skill.Parse`/`Skill.Registry`, and the app no longer imports these. Remove them to avoid dead/duplicated code.

**Files:**
- Modify: `src/OpenCode/MCP/Adapters.hs`
- Modify: `test/OpenCode/MCP/AdaptersSpec.hs`

- [ ] **Step 1: Remove the three functions from `src/OpenCode/MCP/Adapters.hs`**

- From the module export list, delete `parsePromptInvocation`, `missingArgs`, and `promptSuggestEntries`.
- Delete the definitions of `promptSuggestEntries`, `parsePromptInvocation`, and `missingArgs` (and their Haddock).
- Keep `PromptEntry (..)`, `mcpToolName`, the tool-synthesis functions, `resourceReadSchema`, `promptEntryOf`, and `promptEntries`.
- Remove any import that is now unused (run the build; fix whatever `-Wunused-imports` reports — likely none, since `T.*` helpers remain used by tool synthesis).

- [ ] **Step 2: Update `test/OpenCode/MCP/AdaptersSpec.hs`**

- Delete the entire `describe "parsePromptInvocation"` block (currently lines 16-38).
- Delete the entire `describe "missingArgs"` block (currently lines 50-54).
- Keep the `mcpToolName`, `promptEntryOf`, and `resourceReadSchema` blocks.

- [ ] **Step 3: Build + full suite**

Run: `~/.ghcup/bin/stack build --fast --ghc-options -Werror` → clean.
Run: `~/.ghcup/bin/stack test --fast` — all pass.

- [ ] **Step 4: Lint**

Run: `hlint src test` → `No hints`.

- [ ] **Step 5: Commit**

```bash
git add src/OpenCode/MCP/Adapters.hs test/OpenCode/MCP/AdaptersSpec.hs
git commit -m "M15: drop MCP.Adapters prompt helpers now centralized in Skill.*

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 8: Documentation + milestone bookkeeping

**Files:**
- Modify: `README.md`
- Modify: `MILESTONES.md`

- [ ] **Step 1: Update the README slash-commands table**

In `README.md`, replace the `/prompts` row (currently line 137):

```markdown
| `/skills`   | Open a picker to run a skill (local SKILL.md or MCP prompt)|
```

- [ ] **Step 2: Update the README MCP "Prompts" bullet**

Replace the bullet (currently lines 170-171) under "## MCP servers":

```markdown
- **Prompts** appear in the `/` autocomplete and the `/skills` picker (see the
  Skills section); invoke one with `/<server>_<prompt>` plus `key=value` args.
```

- [ ] **Step 3: Add a "## Skills" section**

Insert this section in `README.md` immediately before `## MCP servers`:

```markdown
## Skills

A **skill** is a named instruction bundle you invoke as `/<name> [text]`. Running
a skill injects its rendered text as your next message and starts a run. Skills
come from two sources, listed together under the `/skills` picker and the `/`
autocomplete: local `SKILL.md` files and MCP server prompts.

Local skills live in a directory per skill:

```
~/.config/opencode-hs/skills/<name>/SKILL.md   # user-level
./.opencode-hs/skills/<name>/SKILL.md           # project-level (per repo)
```

```markdown
---
name: explain          # optional; defaults to the directory name
description: Explain a file in plain language
---
Explain what this code does, step by step: $ARGUMENTS
```

- Text typed after `/<name>` replaces `$ARGUMENTS` (or is appended if the body
  has no `$ARGUMENTS`).
- Precedence on a name clash: built-in command > project skill > user skill >
  MCP prompt. Built-ins like `/help` can't be shadowed.
- Skills are loaded once at startup; add one and restart to pick it up. A
  malformed `SKILL.md` is skipped with a message on stderr.
```

(Note: keep the literal triple-backtick fences in the final README; the inner
code blocks above show the directory layout and an example `SKILL.md`.)

- [ ] **Step 4: Update `MILESTONES.md`**

- In the milestone table, change the M15 row status from `planned` / `—` to `done` and fill in the commit range (use the first commit of this work through the latest; e.g. `4965a44..`).
- Update the M15 prose/section to past tense describing what shipped (local SKILL.md discovery + MCP-prompt folding, unified `/skills` surface, `$ARGUMENTS`, precedence, startup snapshot, no new deps).

- [ ] **Step 5: Commit**

```bash
git add README.md MILESTONES.md
git commit -m "M15: document the skill system (README + MILESTONES)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Final verification (after all tasks)

- [ ] `~/.ghcup/bin/stack build --fast --ghc-options -Werror` — clean.
- [ ] `~/.ghcup/bin/stack test --fast` — all examples pass (expect ~395+).
- [ ] `hlint src test` — `No hints`.
- [ ] Spot-check every spec acceptance criterion in `docs/superpowers/specs/2026-06-08-skill-system-design.md` §8 against the implementation.
- [ ] Dispatch the final holistic code review, then run `superpowers:finishing-a-development-branch`.
