# M14 — MCP Client Design

> Sub-project B of the post-v1 roadmap (A = M13 TUI interaction layer, B = M14
> MCP client, C = M15 skill system). MCP was removed from v1 in M12 and is now
> reimplemented from scratch.

**Goal:** Connect to external MCP (Model Context Protocol) servers over stdio and
expose their **tools**, **resources**, and **prompts** to the agent — tools and
resources via the agent's tool layer, prompts via the TUI's slash-command surface
— so the agent can use capabilities it does not ship with.

## Decisions (from brainstorming)

- **Protocol implementation:** hand-roll a minimal JSON-RPC-over-stdio client
  using `process` (already a dependency) + `aeson`. **No new dependencies.** The
  `mcp-server` Hackage package is *not* used (it is server-side and was commented
  out over an aeson-compat issue).
- **Lifecycle:** spawn configured servers once at **agent-run startup** (the
  interactive TUI and headless `run`), keep them alive for the process, tear them
  down on exit. Pure DB/admin commands (`list`, `export`, `config check`) spawn
  nothing.
- **Naming:** MCP tools are namespaced `<server>_<tool>` (e.g.
  `filesystem_read_file`). `_` is used because OpenAI/Anthropic function names must
  match `^[a-zA-Z0-9_-]+$` (dots are not allowed). Built-in tool names are
  untouched.
- **Scope:** tools **and** resources **and** prompts, all in this milestone
  (Approach A — reuse existing substrate everywhere).

## Solution overview (Approach A)

MCP capabilities are adapted onto layers that already exist:

- **Tools** → the **dynamic-tool path**. `executeTool` and `someToolDefinition`
  never inspect the `ToolDef` GADT tag — they use only
  `toolName`/`toolDesc`/`toolSchema`/`toolExecute`/`toolRender`. So one new GADT
  tag `DynamicTool :: ToolDef Value Text` lets an MCP tool be an ordinary
  `SomeTool` whose executor closes over the server connection. It auto-flows into
  the LLM request tool list and the system prompt with **no session-loop
  changes**.
- **Resources** → **two synthesized tools per server**
  (`<server>_list_resources`, `<server>_read_resource`) through the same
  dynamic-tool path. Backend only, no new UI.
- **Prompts** → discovered prompt names become **dynamic slash commands**:
  surfaced in the M13.1 `/` autocomplete and a `/prompts` overlay picker (reusing
  M13's modal), invoked from the input line as `/<server>_<prompt> key=value …`.
  On invoke → `prompts/get` → the returned messages are injected into the
  transcript and an agentic run starts.

```
config.yaml (mcpServers)
        │
        ▼
Run.hs startup ── for each enabled server ──► MCP.Client.connect
        │                                       (spawn, initialize handshake,
        │                                        cache tools/resources/prompts)
        │            ┌──────────────────────────────┼───────────────────────────┐
        │            ▼                               ▼                            ▼
        │   tools → SomeTool            resources → 2 SomeTool          prompts → entries
        │            └────────────► merged into ToolRegistry            (kept on McpClient)
        ▼                                                                        │
  AppEnv { envRegistry (+MCP tools), envMcp = [McpClient] } ◄────────────────────┘
        │                                          │
   session loop                              TUI dispatcher
   (LLM calls tools/resources                (/prompts picker + /<server>_<prompt>
    via executeTool — unchanged)              autocomplete & invocation)
```

## Components

### 1. `OpenCode.Config` (extend) — `mcpServers` section

```yaml
mcpServers:
  filesystem:
    command: npx
    args: ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"]
    env: { FOO: bar }     # optional; merged OVER the inherited environment
    enabled: true         # optional, default true
```

New public types:

```haskell
data McpServerConfig = McpServerConfig
  { mcsCommand :: FilePath
  , mcsArgs    :: [Text]
  , mcsEnv     :: [(Text, Text)]   -- merged over inherited env at spawn time
  , mcsEnabled :: Bool             -- default True
  }
  deriving stock (Show, Eq)

-- on Config:
data Config = Config
  { providers    :: ProviderConfig
  , defaultModel :: ModelId
  , mcpServers   :: [(Text, McpServerConfig)]   -- name -> config, in file order
  }
```

`mcpServers` is independent of the API-key check: a config with only
`mcpServers` and no keys still fails the existing `ConfigMissingKey` check
(unchanged). Absent section → `[]`. `enabled: false` servers are parsed but
skipped at startup.

### 2. `OpenCode.MCP.Protocol` (pure, leaf — depends on aeson/text only)

JSON-RPC 2.0 + MCP message types and codecs. No IO.

```haskell
data JsonRpcRequest = JsonRpcRequest
  { reqId :: Int, reqMethod :: Text, reqParams :: Value }   -- encoded with jsonrpc:"2.0"
data JsonRpcNotification = JsonRpcNotification
  { ntfMethod :: Text, ntfParams :: Value }                 -- no id
data JsonRpcResponse = JsonRpcResponse
  { respId :: Int, respResult :: Either JsonRpcError Value }
data JsonRpcError = JsonRpcError { errCode :: Int, errMessage :: Text }

data McpCapabilities = McpCapabilities
  { capTools :: Bool, capResources :: Bool, capPrompts :: Bool }
data InitializeResult = InitializeResult
  { initProtocolVersion :: Text, initCapabilities :: McpCapabilities }

data McpToolDef  = McpToolDef  { mtName :: Text, mtDescription :: Text, mtInputSchema :: Value }
data McpResource = McpResource { mrUri :: Text, mrName :: Text, mrDescription :: Maybe Text, mrMimeType :: Maybe Text }
data McpPromptArg = McpPromptArg { mpaName :: Text, mpaDescription :: Maybe Text, mpaRequired :: Bool }
data McpPrompt   = McpPrompt   { mpName :: Text, mpDescription :: Maybe Text, mpArguments :: [McpPromptArg] }

data ContentBlock = TextContent Text | OtherContent   -- image/resource/etc.
data CallToolResult     = CallToolResult     { ctrContent :: [ContentBlock], ctrIsError :: Bool }
data ReadResourceResult = ReadResourceResult { rrContents :: [ContentBlock] }
data PromptMessage      = PromptMessage      { pmRole :: Text, pmText :: Text }
data GetPromptResult    = GetPromptResult    { gprMessages :: [PromptMessage] }

-- Pure helpers
encodeRequest      :: JsonRpcRequest -> ByteString          -- single line, no embedded newline
encodeNotification :: JsonRpcNotification -> ByteString
parseResponse      :: ByteString -> Either Text (Either JsonRpcNotification JsonRpcResponse)
renderContent      :: [ContentBlock] -> Text                -- join TextContent; OtherContent -> "[non-text content omitted]"
```

`renderContent` joins `TextContent` blocks with `\n`; any `OtherContent` becomes
the literal placeholder `[non-text content omitted]`. Decoders are tolerant of
unknown fields (servers add their own) and of missing optional fields.

### 3. `OpenCode.MCP.Client` (IO — depends on Protocol + `process`)

```haskell
data McpError
  = SpawnFailed Text         -- could not start the process
  | HandshakeFailed Text     -- initialize failed / bad protocol
  | CallTimeout Text         -- request exceeded the per-call timeout
  | CallFailed Text          -- JSON-RPC error / transport error / decode error
  deriving stock (Show, Eq)

data McpClient = McpClient
  { mcName      :: Text
  , mcCaps      :: McpCapabilities
  , mcTools     :: [McpToolDef]
  , mcResources :: [McpResource]
  , mcPrompts   :: [McpPrompt]
  , mcIn        :: Handle
  , mcOut       :: Handle
  , mcProc      :: ProcessHandle
  , mcLock      :: MVar ()           -- serializes request/response per server
  , mcNextId    :: IORef Int
  }

connect      :: Text -> McpServerConfig -> IO (Either McpError McpClient)
callTool     :: McpClient -> Text -> Value -> IO (Either McpError CallToolResult)
readResource :: McpClient -> Text -> IO (Either McpError ReadResourceResult)
getPrompt    :: McpClient -> Text -> [(Text, Text)] -> IO (Either McpError GetPromptResult)
shutdown     :: McpClient -> IO ()
```

- **Framing:** newline-delimited JSON (the MCP stdio convention — *not* LSP
  `Content-Length`). Each message is one line.
- **Handshake (`connect`):** `createProcess` with piped stdin/stdout/stderr and
  `env` merged over the inherited environment → send `initialize` → parse
  `InitializeResult` → send the `notifications/initialized` notification →
  `tools/list` / `resources/list` / `prompts/list` for each advertised
  capability → cache. Any failure → `Left` (process is killed).
- **Request/response (internal `call`):** take `mcLock`, bump `mcNextId`, write
  the request line, then read lines until a `JsonRpcResponse` with the matching
  id arrives (notifications and non-matching ids are skipped). Wrapped in
  `System.Timeout.timeout` (per-call, **30s default**) → `CallTimeout` on
  expiry. A JSON-RPC error result → `CallFailed`.
- **stderr:** piped and drained by a background thread (`forkIO`, output
  discarded) so it never corrupts the TUI or blocks the server on a full pipe.
- **`shutdown`:** close stdin (asks the server to exit), `terminateProcess`,
  `waitForProcess`. Best-effort; never throws.

### 4. `OpenCode.MCP.Adapters` (converters)

```haskell
data PromptEntry = PromptEntry
  { peFullName :: Text          -- "<server>_<prompt>"
  , peDescription :: Text
  , peRequiredArgs :: [Text]    -- names of required arguments
  }

mcpToolName     :: Text -> Text -> Text                      -- server -> tool -> "<server>_<tool>"
toolToSomeTool  :: McpClient -> McpToolDef -> SomeTool
resourceTools   :: McpClient -> [SomeTool]                   -- [] unless resources advertised; else 2 tools
promptEntries   :: McpClient -> [PromptEntry]
clientSomeTools :: McpClient -> [SomeTool]                   -- tools ++ resourceTools
parsePromptInvocation :: Text -> Maybe (Text, [(Text, Text)])  -- "/name k=v k=v" -> (name, args)
```

- `toolToSomeTool` builds `SomeTool { toolDef = DynamicTool, toolName =
  mcpToolName (mcName c) (mtName t), toolDesc = mtDescription t, toolSchema =
  mtInputSchema t, toolExecute = \v -> liftIO (callTool c (mtName t) v) >>=
  either (throwError . ToolError name . renderMcpError) (pure . renderContent .
  ctrContent), toolRender = id }`. An `isError` result is rendered through
  `renderContent` like any other (the LLM sees the server's error text).
- `resourceTools` (only when `capResources`):
  - `<server>_list_resources` — empty-object schema; executor returns a text
    listing of `uri  name — description` for `mcResources`.
  - `<server>_read_resource` — schema `{ "type":"object", "properties":{ "uri":
    {"type":"string"} }, "required":["uri"] }`; executor reads the `uri` argument
    and returns `renderContent . rrContents`.
- `parsePromptInvocation` parses the first whitespace token (the `/name`) and any
  following `key=value` tokens. Returns `Nothing` for input that is not a single
  `/word …`. Pure and tested.

One new GADT tag in `OpenCode.Tool.Types`:

```haskell
data ToolDef input output where
  ...
  DynamicTool :: ToolDef Value Text   -- MCP / runtime-discovered tools
```

`Value` already has `FromJSON` (the `SomeTool` constraint), and `toolDef` is
never inspected, so this tag exists only to satisfy the existential.

### 5. Wiring — `OpenCode.MCP.Startup`, `AppEnv`, `Run.hs`

`AppEnv` gains one field:

```haskell
data AppEnv = AppEnv
  { ... , envMcp :: [McpClient] }
```

No import cycle: `App.Types → MCP.Client → Protocol`; `MCP.Client` never imports
`App.Types`. (`MCP.Adapters` imports `App.Types` for `AppM`, but nothing imports
`Adapters` except `Startup`/`Run`/TUI.)

```haskell
-- OpenCode.MCP.Startup
data McpDiagnostic = McpDiagnostic { mdServer :: Text, mdReason :: Text }
startMcp :: Config -> IO ([McpClient], [McpDiagnostic])
mcpRegistryAdditions :: [McpClient] -> ToolRegistry -> ToolRegistry  -- folds clientSomeTools in
```

`startMcp` connects each `enabled` server; successes yield clients, failures
yield diagnostics (server skipped). `Run.hs`:

1. After building `Config` + `defaultBuiltinRegistry`, call `startMcp config`
   **only for agent-run entry points** (TUI launch + headless `run`).
2. `registry' = mcpRegistryAdditions clients defaultBuiltinRegistry`.
3. Build `AppEnv { envRegistry = registry', envMcp = clients, … }`.
4. Wrap the run body in `bracket (pure clients) (mapM_ shutdown) (const …)` so
   every client is shut down on exit (normal or exception).
5. Surface diagnostics: write each to **stderr** (printed before the TUI takes
   the screen; visible in headless mode), e.g.
   `MCP server 'foo' unavailable: <reason>`. An in-chat startup banner for the
   TUI is a future enhancement (out of scope for v1).

### 6. TUI surface for prompts

- **Autocomplete (M13.1):** `commandSuggestions` gains a leading parameter for
  dynamic prompt entries so `OpenCode.TUI.Command` stays a leaf (caller passes
  the list, derived from `asEnv`):

  ```haskell
  commandSuggestions :: [(Text, Text)] -> Text -> [(Text, Text)]
  --                    ^ dynamic prompt (name, desc) entries
  ```

  Built-ins and prompt commands both appear under `/`, matched by the same
  case-insensitive prefix rule. Render's `suggestBox` and App's reducers build
  the prompt `[(Text,Text)]` from `asEnv st` (via `promptEntries` over
  `envMcp`) and pass it in.

- **`/prompts` command:** new `CmdPrompts` in `OpenCode.TUI.Command`
  (catalog: `"/prompts"`, `"run an MCP prompt"`) and a new `PromptsList`
  `OverlayKind` listing `peFullName — peDescription`. Selecting a row:
  - **no required args** → invoke the prompt immediately;
  - **has required args** → prefill the input line with `/<fullName> ` (cursor at
    end) so the user types `key=value` arguments (reusing the M13.1 completion
    mechanic). Does not run.

- **Invocation (enter handler):** when the first input token (minus `/`) matches
  a known `peFullName`, route to prompt invocation instead of `parseCommand`:
  `parsePromptInvocation` → check required args present → `liftIO (getPrompt …)`
  → **combine the returned messages' text into a single user turn** and submit it
  through the existing typed-message path (`startRun`), which persists the user
  message and starts the agentic loop. (v1 ignores per-message roles — MCP
  prompts almost always return user content.) Missing required args, or a
  `getPrompt` `Left`, → `asNotice` error (no run).

## Data flow

```
LLM tool call (name, args)
   └─ executeTool registry name args                       (unchanged dispatch)
        └─ SomeTool.toolExecute (closes over McpClient)
             └─ liftIO (callTool / readResource)           (MVar-serialized, timeout)
                  └─ renderContent → Text → ToolResultPart

User: "/filesystem_summarize path=/tmp/a"  ──▶ enter handler
   firstToken matches a PromptEntry?
     ├─ yes ─▶ parsePromptInvocation ─▶ required args present?
     │            ├─ yes ─▶ liftIO (getPrompt) ─▶ inject messages ─▶ run
     │            └─ no  ─▶ asNotice "missing required arg: <name>"
     └─ no  ─▶ parseCommand ─▶ dispatchCommand              (M13/M13.1 path)
```

## Error handling

| Failure | Behavior |
|---|---|
| Server won't spawn / handshake fails | `McpDiagnostic` recorded, server skipped, app continues. Reported to stderr (in-chat TUI banner is a future enhancement). |
| Tool/resource call: timeout / crash / JSON-RPC error / decode error | Executor returns `Left` → `ToolError` → rendered as a `ToolResultPart`/`ErrorPart`; the session continues. |
| Tool result with `isError = true` | Rendered as normal text (server's error message reaches the LLM). |
| `prompts/get` failure or missing required arg | `asNotice` error; no run started. |
| Program exit (normal or exception) | Best-effort `shutdown` of every client via `bracket`. |

No MCP failure ever takes down the session.

## Testing

The repo's testable-core pattern: pure logic is unit-tested; the one live
key→action path stays untested (brick 2.x has no pure `EventM` runner).

- **`Protocol`:** encode a request/notification (assert single-line, correct
  `jsonrpc`/`id`/`method`); decode fixtures for `initialize`, `tools/list`,
  `tools/call` (text **and** non-text content, and `isError`), `resources/list`,
  `resources/read`, `prompts/list`, `prompts/get`, and a JSON-RPC error; unknown
  extra fields tolerated; `renderContent` joins text and substitutes the
  placeholder.
- **`Adapters`:** `mcpToolName` namespacing; `toolToSomeTool` sets name/desc/
  schema correctly; `resourceTools` yields exactly two tools when resources are
  advertised and `[]` otherwise; `promptEntries` full-name + required-arg
  extraction; `parsePromptInvocation` (`/x` → `("/x",[])`, `/x a=1 b=2` →
  args parsed, non-command input → `Nothing`).
- **Autocomplete merge:** `commandSuggestions` with prompt entries — built-ins +
  prompts both match by prefix; prompt-only prefix returns just prompts; existing
  built-in-only cases still pass.
- **Config:** `mcpServers` parsing (full entry, defaults for `env`/`enabled`,
  absent section → `[]`, `enabled:false` preserved).
- **Integration:** a small in-repo **mock MCP server** as a stack executable
  (`opencode-mcp-mock`) speaking newline JSON-RPC — implements `initialize`
  (advertising all three capabilities), `tools/list` (one `echo` tool),
  `tools/call` (echoes its arguments as text), `resources/list` + `resources/read`
  (one fixed resource), `prompts/list` + `prompts/get` (one prompt returning a
  user message). Hspec tests spawn it through the real `MCP.Client` and assert:
  handshake succeeds and caches the three lists; `callTool` round-trips; a
  resource reads; a prompt gets; an unknown method yields a clean `Left`
  (graceful failure); `shutdown` terminates the process. No Node/Python in CI.

All under the existing `-Wall -Werror` + hlint-clean bars.

## Acceptance criteria

1. A configured, reachable MCP server's tools appear in the LLM tool list and
   system prompt, namespaced `<server>_<tool>`, and are callable; a round that
   calls one returns the server's result as a `ToolResultPart`.
2. When a server advertises resources, `<server>_list_resources` and
   `<server>_read_resource` tools exist and work.
3. When a server advertises prompts, each prompt appears in the `/` autocomplete
   and the `/prompts` picker; invoking one (no-arg, or with `key=value` args)
   injects its messages and starts a run.
4. A misconfigured/missing/crashing server logs a clear diagnostic and the rest
   of the app runs normally; a failing tool call surfaces as an error part
   without crashing the session.
5. Pure DB/admin commands (`list`, `export`, `config check`) spawn no MCP
   servers. All servers are shut down on exit.
6. New code adds **no new dependencies**, builds `-Wall -Werror` clean, and is
   hlint-clean; the integration test passes against the in-repo mock server.

## Out of scope (YAGNI)

- HTTP / SSE transports (stdio only).
- MCP sampling, roots, logging, and progress notifications (drained/ignored).
- Non-text tool/resource content (rendered as a placeholder).
- Server-initiated requests (we only do request→response + send `initialized`).
- An argument-collection *form* UI for prompts (args are typed `key=value` or the
  picker prefills the line).
- Hot reload / reconnection of servers mid-run.
- A `/mcp` status command (diagnostics go to the startup banner / stderr).
