# Model-Invoked Skills (M16) — Design

**Date:** 2026-06-10
**Status:** Approved design, pre-implementation
**Depends on:** M14 (MCP client), M15 (skill system)

## Goal

Make skills invokable by the *model*, not just the user. Today a skill fires
only when the user types `/<name>`. After this milestone the agent can decide,
mid-run, to pull a skill's instructions into context — Claude Code's "Agent
Skills" behavior (progressive disclosure: skill descriptions are always
visible to the model; a skill's full body enters context only when invoked).

This is Sub-project A of the "Claude Code-like skill system" effort.
Sub-project B (management UX: scaffold / edit / remove / reload) is a separate
follow-up milestone and out of scope here.

## Decisions (settled during brainstorming)

1. **Tool shape:** one umbrella `skill` tool (not one tool per skill, not
   eager system-prompt injection).
2. **Exposure:** every discovered skill is model-invokable. No new
   frontmatter field; user-typed `/<name>` continues to work unchanged.
3. **Reach:** both skill sources participate — local `SKILL.md` skills *and*
   MCP-server prompts — through the one tool.
4. **Layering:** the MCP-aware wiring lives in a new top-level module
   `OpenCode.SkillTool`; the `OpenCode.Skill.*` namespace stays pure and
   MCP-free (the M15 invariant).

## Architecture

### The `skill` tool

A single `SomeTool` built on the existing `DynamicTool :: ToolDef Value Text`
GADT tag (no new constructor), exactly as `MCP.Adapters.toolToSomeTool` does.
Registered into the run registry **only when at least one skill exists**.

Input schema (the `name` enum makes invalid skills unrepresentable at the
wire level):

```json
{ "type": "object",
  "properties": {
    "name":      { "type": "string", "enum": ["<skill1>", "<skill2>", ...] },
    "arguments": { "type": "string" }
  },
  "required": ["name"] }
```

Tool description enumerates every skill, one line each:

```
Invoke a named skill: a reusable instruction bundle. The result is the
skill's instructions; follow them. Available skills:
  - code-review: audit a diff for bugs
  - jira_summarize: summarize a ticket (needs: ticket_id)
```

Required args (MCP prompts only) are listed as `(needs: a, b)` so the model
knows to supply `key=value` pairs in `arguments`.

Executor flow: decode `{name, arguments}` → look up the skill in the
closed-over registry snapshot → render (below) → return the rendered text as
the tool result. The model reads the instructions and continues the run.

### Shared render core

One function used by *both* the user-typed path and the model path, so the
two can never drift:

```haskell
-- in OpenCode.SkillTool
renderSkill :: [McpClient] -> Skill -> Text -> IO (Either Text Text)
```

- `LocalSkill body` → `Right (substituteArgs body args)` (pure; never Left).
- `McpPromptSkill server prompt` →
  `parseArgs` the trailing text → `missingArgs` check (`Left` with guidance
  naming the missing args) → find the owning client by `mcName`
  (`Left` if the server is gone) → `getPrompt` (exception-wrapped, like the
  current TUI path) → flatten `GetPromptResult` messages to text → `Right`.

`TUI.App.renderInvocation` is refactored to delegate to `renderSkill`,
deleting its inline copy of this logic. A `Left` becomes a TUI notice on the
user path and an error-text tool result on the model path (M14 already
established that error-ish tool results are fed to the model as plain text,
so the model can self-correct, e.g. by supplying the missing args).

### Module layout & layering

- **`OpenCode.Skill.Registry`** (pure, existing) gains:
  - `skillToolSchema :: [Skill] -> Value` — the input schema with the
    name enum.
  - `skillToolDescription :: [Skill] -> Text` — the enumerated description.

  Same family as the existing `skillSuggestEntries`; no new imports.

- **`OpenCode.SkillTool`** (new, top-level — sibling of `Run`, analogous in
  spirit to `MCP.Startup`) may import both `Skill.*` and `MCP.Client`:
  - `renderSkill` (above).
  - `skillTool :: [McpClient] -> [Skill] -> Maybe SomeTool` — `Nothing` for
    an empty skill list; otherwise the umbrella tool whose executor closes
    over the clients and skills.

  Imports: `Skill.{Types,Parse,Registry}`, `MCP.Client`, `MCP.Protocol`,
  `Tool.Types`, `App.Error`. It must NOT import `TUI.*` or `Run`.

- **`OpenCode.Run`**: in `withAppEnv`, after the existing skill registry is
  built, merge `skillTool clients skills` into `envRegistry` (next to
  `mcpRegistryAdditions`). Same `spawnMcp`/interactive gating as today —
  `list`/`export`/`config check` never build it.

- **`OpenCode.TUI.App`**: replace the inline `LocalSkill`/`McpPromptSkill`
  dispatch in `renderInvocation` with a call to `renderSkill`; behavior of
  the user-typed path is unchanged (rendered text still injected as a user
  turn, still Idle-gated).

New dependency edges: `SkillTool → {Skill.*, MCP.Client, MCP.Protocol,
Tool.Types}`, `Run → SkillTool`, `TUI.App → SkillTool`. The `Skill.*`
namespace remains leaf-pure.

### Tool name reservation

`skill` joins the reserved-names list passed to `buildSkillRegistry`, so a
local skill named `skill` cannot shadow or collide with the umbrella tool.
(The registry already drops reserved names; this is one more entry.)

## Data flow (model path)

1. `withAppEnv` discovers skills (M15) and MCP clients (M14), builds the
   skill registry, then `skillTool clients skills` → merged into
   `envRegistry`.
2. The agentic loop sends the tool list as usual; the model sees `skill`
   with all skill names/descriptions in its schema + description.
3. Model calls `skill {name, arguments}` → `executeTool` dispatches to the
   umbrella executor → `renderSkill` → rendered body returned as the tool
   result.
4. Model follows the instructions; loop continues under the existing
   iteration cap. No Idle-gating needed (the call happens mid-run, inside
   the loop, unlike the user-typed path which *starts* runs).

Because the tool lives in `envRegistry`, headless `run --no-tui --prompt`
gets model-invoked skills for free (it has no slash-command UI today).

## Error handling

| Case | Behavior |
|---|---|
| Zero skills discovered | `skillTool` returns `Nothing`; tool not registered. |
| Model sends unknown `name` (defensive; enum should prevent) | Tool result: guidance text listing the valid names. Not a thrown `ToolError` — let the model retry. |
| MCP prompt missing required args | Tool result: guidance naming the missing args (from `missingArgs`). |
| MCP `getPrompt` failure / server gone | Tool result: rendered error text (via `renderMcpError` / exception text). |
| Malformed tool input JSON | Existing `executeTool` path → `ToolError` (unchanged). |

The executor itself never throws for skill-level problems; it returns
guidance text so the run survives and the model can self-correct. This
matches the M14 decision to render `isError` tool results as normal text.

## Testing

All via the existing harnesses; no new deps.

- **Pure (Registry):** `skillToolSchema` enum contents/shape;
  `skillToolDescription` line-per-skill incl. `(needs: …)` for required
  args; empty-list behavior.
- **SkillTool unit:** `skillTool _ [] == Nothing`; local-skill executor
  renders `substituteArgs` output; unknown-name guidance; missing-args
  guidance (no live server needed — fails before `getPrompt`).
- **SkillTool integration:** MCP-prompt path via the `opencode-mcp-mock`
  exe + `ClientSpec`-style harness (M14 pattern, `Paths_opencode_hs`).
- **Parity:** for a shared example, the TUI path (`renderInvocation`) and
  the tool executor produce identical rendered text — guards against drift
  since both go through `renderSkill`.
- **Run wiring:** registry contains `skill` iff skills exist; reserved-name
  test that a local skill named `skill` is dropped.

## Out of scope

- Management UX (scaffold/edit/remove/reload) — Sub-project B.
- Distribution/marketplace.
- Mid-session skill reload (still a startup snapshot).
- Per-skill opt-out of model invocation (decided against for v1).
