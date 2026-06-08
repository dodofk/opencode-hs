# M15 — Skill System Design

**Status:** approved (2026-06-08)

## 1. Goal

Add a **skill system**: named, reusable instruction bundles the user invokes as
`/<name> [free text]`. Invoking a skill produces a body of text that is injected
as a **user-turn message** and starts a run — exactly the path M14 uses for MCP
prompts. Skills come from two **sources**, presented through one unified surface:

- **Local skills** — `SKILL.md` files in skill directories on disk.
- **MCP prompts** — discovered from connected MCP servers (M14), folded in as a
  second source.

Both list under one `/skills` overlay and one autocomplete namespace. The M14
`/prompts` command is **removed** (its prompts now appear under `/skills`).

## 2. Conceptual model

A skill is a **prompt template**. There is no progressive disclosure and no
persistent "mode": invocation is a one-shot injection of rendered text as a user
message, which kicks off the normal agentic loop. This reuses the existing
`appendUserMessage → startRun` machinery (see `OpenCode.TUI.App.invokePrompt`).

## 3. On-disk format (local skills)

A skill is a **directory** containing a `SKILL.md` file:

```
~/.config/opencode-hs/skills/<name>/SKILL.md      (user-level)
./.opencode-hs/skills/<name>/SKILL.md             (project-level, CWD-relative)
```

`SKILL.md`:

```markdown
---
name: greet                  # optional; defaults to the directory name
description: Greeting helper  # optional; "" if omitted; shown in the listing
---
You are greeting someone. $ARGUMENTS
```

- **Frontmatter** is YAML between `---` fences at the very top of the file. Both
  fields are optional. If there is no opening `---` line, the whole file is the
  body (name = directory name, description = "").
- **Body** is everything after the closing `---`. It is `strip`ped of leading and
  trailing whitespace before use.
- **`$ARGUMENTS`**: the trailing text typed after `/<name>` is substituted for
  every occurrence of the literal token `$ARGUMENTS`. If the body has no
  `$ARGUMENTS` token and there is trailing text, the text is appended after a
  blank line. If there is no trailing text, the body is used as-is.
- **Supporting files** in the directory are *not* auto-loaded in M15. The agent
  can read them via the existing `read`/`glob`/`grep` tools; the directory format
  exists only to leave headroom for future bundled resources.

## 4. Discovery and precedence

- Two roots are scanned, **project first, then user**:
  - project: `<cwd>/.opencode-hs/skills`
  - user: `<home>/.config/opencode-hs/skills` (mirrors the config-file location)
- Skills are loaded **once at startup** and snapshotted into `AppEnv` (matching
  the MCP lifecycle). Adding a skill file requires a restart.
- Discovery is gated to **interactive/agent-running commands** (`run`, including
  the no-args TUI and `run --no-tui`), the same gate MCP uses. Admin commands
  (`list`, `export`, `config check`, `version`) load nothing.
- **Name-clash precedence:** built-in command > project skill > user skill > MCP
  prompt. Built-ins like `/help` and `/quit` can never be shadowed by a skill.
  MCP prompt names are namespaced `<server>_<prompt>`, so real clashes are rare.
- A malformed or unreadable `SKILL.md` is **skipped with a stderr diagnostic**
  (reusing the M14 diagnostic-reporting pattern). A missing root yields no
  skills and no error. Discovery never throws.

## 5. Module layout

New modules (pure unless noted), layered so `Skill.*` never imports `MCP.*` or
`TUI.*` — the unification (folding MCP prompts in) happens **above** them, in
`OpenCode.Run`:

- **`OpenCode.Skill.Types`** — `Skill` and `SkillSource`. Pure data; imports only
  `base` + `text` (the MCP variant holds plain `Text`, so there is **no
  Skill→MCP dependency**).

  ```haskell
  data SkillSource
    = LocalSkill Text            -- ^ the SKILL.md body (may contain $ARGUMENTS)
    | McpPromptSkill Text Text   -- ^ server name, raw prompt name
    deriving stock (Show, Eq)

  data Skill = Skill
    { skName         :: Text     -- ^ invocation name, no leading slash
    , skDescription  :: Text
    , skRequiredArgs :: [Text]   -- ^ [] for local skills
    , skSource       :: SkillSource
    }
    deriving stock (Show, Eq)
  ```

- **`OpenCode.Skill.Parse`** — pure parsing/rendering and the single source of
  truth for invocation-line parsing:
  - `splitFrontmatter :: Text -> (Maybe Text, Text)`
  - `parseSkillFile :: Text -> Text -> Either Text Skill` (default name, content)
  - `substituteArgs :: Text -> Text -> Text` (body, args → rendered)
  - `splitInvocation :: Text -> Maybe (Text, Text)` (`/word rest` → (name, rest))
  - `parseArgs :: Text -> [(Text, Text)]` (`key=value` pairs; first `=` splits;
    tokens without `=` ignored; empty value passes through)
  - `missingArgs :: [Text] -> [(Text, Text)] -> [Text]`

- **`OpenCode.Skill.Registry`** — pure merge / lookup / autocomplete:
  - `buildSkillRegistry :: [Text] -> [Skill] -> [Skill]` (reserved built-in
    names, then candidates in precedence order; drops names that collide with a
    reserved name or an already-kept skill — first wins)
  - `lookupSkill :: Text -> [Skill] -> Maybe Skill`
  - `matchSkill :: [Skill] -> Text -> Maybe (Skill, Text)` (split invocation +
    lookup; returns the skill and the raw trailing text)
  - `skillSuggestEntries :: [Skill] -> [(Text, Text)]` (`("/" <> name, desc)`)

- **`OpenCode.Skill.Discovery`** — IO scan:
  - `data SkillDiagnostic = SkillDiagnostic { sdSkill :: Text, sdReason :: Text }`
  - `discoverSkillsIn :: [FilePath] -> IO ([Skill], [SkillDiagnostic])` (roots in
    precedence order; testable with explicit temp dirs)
  - `defaultSkillRoots :: IO [FilePath]` ( `[project, user]` )
  - `discoverSkills :: IO ([Skill], [SkillDiagnostic])`

**Touched modules:**

- `OpenCode.App.Types` — add `envSkills :: [Skill]` to `AppEnv`.
- `OpenCode.Run` — discover skills (under the existing interactive gate), map each
  MCP `PromptEntry` to a `Skill` (`McpPromptSkill`), `buildSkillRegistry` with the
  built-in command names reserved, set `envSkills`, report skill diagnostics.
- `OpenCode.TUI.Command` — `CmdPrompts`→`CmdSkills`; `/prompts`→`/skills`
  ("run a skill"). `commandSuggestions` is unchanged (callers pass skill entries
  as the dynamic list).
- `OpenCode.TUI.Types` — `OverlayPrompts [PromptEntry]`→`OverlaySkills [Skill]`.
- `OpenCode.TUI.Overlay` — `promptsOverlay`→`skillsOverlay`; rows tagged by source.
- `OpenCode.TUI.App` — `openPrompts/matchPrompt/allPromptEntries/invokePrompt/
  selectPrompt`→`openSkills/matchSkill(use)/invokeSkill/selectSkill`; `onEnter`
  routing; `suggestEntries` and `commitOverlay` retargeted. Keep the M14 Task-10
  Idle gate on every run-starting path.
- `OpenCode.TUI.Render` — `suggestBox` draws its dynamic entries from
  `skillSuggestEntries (envSkills …)`.
- `OpenCode.MCP.Adapters` — remove `parsePromptInvocation`, `missingArgs`,
  `promptSuggestEntries` (now centralized in `Skill.Parse`/`Skill.Registry`);
  keep `PromptEntry`, `promptEntryOf`, `promptEntries`, and the tool synthesis.

## 6. Invocation flow

Because a skill invocation is slash-prefixed, `parseCommand` classifies it as
`CmdUnknown`. `onEnter` therefore routes:

1. `parseCommand body == Nothing` → plain text → submit to the LLM (unchanged).
2. `parseCommand body == Just (CmdUnknown _)` → try `matchSkill (envSkills) body`:
   - match, run state `Idle` → `invokeSkill skill rest`
   - match, mid-run → notice "press Esc to abort the run first"
   - no match → unknown-command notice (existing `dispatchCommand` path)
3. `parseCommand body == Just <known builtin>` → `dispatchCommand` (built-ins win).

`invokeSkill skill rest` branches on `skSource`:

- **Local** → `substituteArgs body (strip rest)`; empty rendered body → notice
  "skill produced no content"; else `mkUserMessage` + `appendUserMessage` +
  `startRun`.
- **MCP prompt** → `parseArgs rest`; `missingArgs (skRequiredArgs skill)` non-empty
  → notice; else find the client by server name in `envMcp` and use the existing
  `getPrompt` IO path (with `try`/`Left` handling) to fetch and inject.

The `/skills` overlay routes through `selectSkill`: a skill with no required args
runs immediately; an MCP skill with required args closes the overlay and prefills
the input with `"/<name> "` for the user to add `key=value` arguments.

## 7. Error handling

- Discovery: bad skill skipped + one stderr diagnostic line; never throws.
- Local render: pure and total.
- MCP path: unchanged from M14 (`try` around `getPrompt`, `Left` surfaced as a
  notice; missing required arg → notice; empty content → notice).

## 8. Testing

- **`Skill.Parse`** (pure): frontmatter present / absent / partial / malformed;
  name-defaults-to-directory; `$ARGUMENTS` present / absent+append / no-args;
  `splitInvocation`; `parseArgs` (the M14 key=value cases); `missingArgs`.
- **`Skill.Registry`** (pure): precedence (project > user > mcp via order + dedup);
  built-in names excluded; `lookupSkill`; `matchSkill`; `skillSuggestEntries`.
- **`Skill.Discovery`** (temp dirs via `withSystemTempDirectory`, explicit roots):
  finds skills in both roots; project overrides user; malformed `SKILL.md` →
  diagnostic; missing root → empty; non-directory entry and dir-without-SKILL.md
  ignored.
- **TUI**: update `CommandSpec` (`/skills`), `OverlaySpec` (`skillsOverlay`),
  `RenderSpec` (`/skills` "run a skill"); the EventM wiring
  (`onEnter`/`invokeSkill`) rests on the pure `matchSkill`/`substituteArgs` tests
  + code review, as in M13/M14 (brick 2.x exposes no pure `EventM` runner).
- Add `envSkills = []` to every `AppEnv` record literal in the test tree.
- `-Wall -Werror` clean; `hlint src test` reports no hints; **no new dependencies**
  (frontmatter parses via the existing `yaml`).

## 9. Non-goals (YAGNI)

- No progressive disclosure / model-initiated skill loading.
- No persistent skill "mode" or agent persona.
- No named/`{{placeholder}}` args for local skills (`$ARGUMENTS` free-text only).
- No auto-loading of supporting files in the skill directory.
- No mid-session reload (startup snapshot only).
- No config-file declaration of skills (filesystem discovery only).
