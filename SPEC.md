# opencode-hs — Specification

A Haskell reimplementation of [OpenCode](https://github.com/sst/opencode), a terminal-based AI coding agent.
Fully functional-programming style: no mutable state outside STM/IORef, effect-typed boundaries, ADT-first design.

---

## 1. Scope

### In scope (v1.0)
- Streaming LLM calls to **OpenAI** and **Anthropic**
- Tool system: read, write, edit, bash, glob, grep
- MCP client (stdio transport, using `mcp-server` Hackage package)
- SQLite-backed session + message persistence
- `brick`-based TUI: scrollable chat, inline tool results, status bar
- YAML config file (`~/.config/opencode-hs/config.yaml`)
- `optparse-applicative` CLI with `run`, `list`, `export` subcommands

### Out of scope (v1.0)
- LSP integration
- Multi-provider beyond OpenAI + Anthropic
- GitHub/web search tools
- Multi-tenant / ACP remote sessions
- Plugin / skill system

---

## 2. Architecture Overview

```
┌─────────────────────────────────────────────────────┐
│                    CLI (optparse)                    │
│          run | list | export | config                │
└────────────────────┬────────────────────────────────┘
                     │
┌────────────────────▼────────────────────────────────┐
│               App Monad (AppM)                       │
│   ReaderT AppEnv (ExceptT AppError IO)               │
│   AppEnv = { config, db, eventBus, mcpClients }      │
└───┬──────────────┬───────────────┬──────────────────┘
    │              │               │
┌───▼───┐   ┌──────▼──────┐  ┌────▼──────────┐
│Session│   │  LLM Client │  │  Tool Runner  │
│Manager│   │  (Streaming)│  │  (GADT-based) │
└───┬───┘   └──────┬──────┘  └────┬──────────┘
    │              │               │
┌───▼──────────────▼───────────────▼──────────┐
│           Persistence Layer (SQLite)         │
│           sqlite-simple + migrations         │
└─────────────────────────────────────────────┘
         │
┌────────▼───────────────────────────────────┐
│                TUI (brick)                  │
│  ChatView | InputEditor | StatusBar         │
└────────────────────────────────────────────┘
```

---

## 3. Module Breakdown

### 3.1 `OpenCode.Config`
- Type: `Config { providers :: ProviderConfig, defaultModel :: ModelId }`
- `ProviderConfig { openai :: Maybe ApiKey, anthropic :: Maybe ApiKey }`
- Load from `~/.config/opencode-hs/config.yaml` via `yaml` + `aeson`
- Environment variable overrides (`OPENAI_API_KEY`, `ANTHROPIC_API_KEY`)
- `loadConfig :: IO (Either ConfigError Config)`

### 3.2 `OpenCode.Types`
Core ADTs shared across the application:

```haskell
-- Session
newtype SessionId = SessionId Text
data Session = Session
  { sessionId      :: SessionId
  , sessionTitle   :: Text
  , sessionModel   :: ModelId
  , sessionCreated :: UTCTime
  }

-- Messages
data Role = User | Assistant | Tool
data MessagePart
  = TextPart Text
  | ToolCallPart ToolCall
  | ToolResultPart ToolResult
  | ErrorPart Text

data Message = Message
  { msgId      :: MessageId
  , msgRole    :: Role
  , msgParts   :: NonEmpty MessagePart
  , msgCreated :: UTCTime
  }

-- LLM
data ModelId = ModelId { provider :: ProviderId, model :: Text }
data ProviderId = OpenAI | Anthropic

-- Tool call/result
data ToolCall = ToolCall
  { callId    :: Text
  , toolName  :: Text
  , arguments :: Aeson.Value
  }

data ToolResult = ToolResult
  { resultCallId :: Text
  , content      :: Text
  , isError      :: Bool
  }

-- Streaming events
data StreamEvent
  = TextDelta Text
  | ToolCallStart Text Text           -- callId toolName
  | ToolCallArgDelta Text Text        -- callId argFragment
  | ToolCallEnd Text                  -- callId
  | StreamDone Usage
  | StreamError Text

data Usage = Usage
  { inputTokens  :: Int
  , outputTokens :: Int
  , cacheRead    :: Maybe Int
  , cacheWrite   :: Maybe Int
  }
```

### 3.3 `OpenCode.LLM`
Streaming LLM calls using `http-conduit` + `conduit`.

```haskell
class LLMProvider p where
  streamCompletion
    :: p
    -> [Message]
    -> [ToolDefinition]
    -> ConduitT () StreamEvent IO ()

data OpenAIProvider  = OpenAIProvider  { apiKey :: Text, baseUrl :: Text }
data AnthropicProvider = AnthropicProvider { apiKey :: Text }
```

Key implementation notes:
- **OpenAI**: Server-Sent Events stream via `data: {...}\n\n` lines; parse `delta.content` and `delta.tool_calls`
- **Anthropic**: SSE stream; parse `content_block_start/delta/stop` events
- Use `http-conduit` for the HTTP layer, `conduit` for stream processing
- Parse SSE lines with `Data.Conduit.Text.lines` + JSON decode
- Thread an `STM TVar` for buffering in-progress tool call argument fragments
- `systemPrompt :: [Message] -> Text` constructs the system prompt

#### Sub-modules
- `OpenCode.LLM.OpenAI` — OpenAI-specific SSE parsing
- `OpenCode.LLM.Anthropic` — Anthropic-specific SSE parsing
- `OpenCode.LLM.Request` — shared request-building helpers

### 3.4 `OpenCode.Tool`
Type-safe tool system using GADTs.

```haskell
data ToolDef (input :: Type) (output :: Type) where
  ReadFileTool  :: ToolDef ReadFileInput  Text
  WriteFileTool :: ToolDef WriteFileInput Text
  EditFileTool  :: ToolDef EditFileInput  Text
  BashTool      :: ToolDef BashInput      BashOutput
  GlobTool      :: ToolDef GlobInput      [FilePath]
  GrepTool      :: ToolDef GrepInput      [GrepMatch]

-- Existential wrapper for the registry
data SomeTool = forall i o. (FromJSON i, ToJSON o) =>
  SomeTool (ToolDef i o) (i -> AppM o)

data ToolRegistry = ToolRegistry { tools :: Map Text SomeTool }

-- Each tool carries its JSON schema for the LLM
toolDefinition :: SomeTool -> ToolDefinition
```

#### Tool implementations
- **ReadFile**: read up to N bytes with line range support
- **WriteFile**: write with parent dir creation
- **EditFile**: old-string → new-string replacement with unified diff output
- **Bash**: `System.Process` with 30s timeout, captured stdout+stderr
- **Glob**: `System.FilePath.Glob` pattern matching
- **Grep**: ripgrep subprocess or `Data.Text` fallback

### 3.5 `OpenCode.Session`
Conversation loop orchestrator.

```haskell
data SessionState = SessionState
  { stSession  :: Session
  , stMessages :: Seq Message
  , stRunState :: RunState
  }

data RunState
  = Idle
  | RunningLLM
  | RunningTool Text    -- tool name
  | AwaitingInput

-- Main loop
runSession
  :: SessionId
  -> AppM ()              -- blocks until user quits

processUserMessage
  :: SessionId
  -> Text                 -- user prompt
  -> AppM ()

-- Internal: consume one LLM stream, execute any tool calls, loop
agentic
  :: SessionId
  -> [Message]
  -> AppM [Message]       -- returns updated message list
```

Flow:
1. Build message list from DB
2. Call `streamCompletion` → consume `StreamEvent`s
3. Accumulate text deltas → `TextPart`
4. On `ToolCallEnd`: look up tool in registry, execute, append `ToolResultPart`
5. If any tool calls were executed, recurse (up to `maxToolRounds = 10`)
6. Persist messages to DB
7. Emit `SessionEvent`s to TUI via STM `TChan`

### 3.6 `OpenCode.DB`
SQLite persistence via `sqlite-simple`.

```haskell
-- Schema (run at startup)
createSchema :: Connection -> IO ()

-- Sessions
insertSession :: Connection -> Session -> IO ()
getSession    :: Connection -> SessionId -> IO (Maybe Session)
listSessions  :: Connection -> IO [Session]

-- Messages
insertMessage :: Connection -> SessionId -> Message -> IO ()
getMessages   :: Connection -> SessionId -> IO [Message]
```

Schema:

```sql
CREATE TABLE sessions (
  id         TEXT PRIMARY KEY,
  title      TEXT NOT NULL,
  model_id   TEXT NOT NULL,
  created_at TEXT NOT NULL
);

CREATE TABLE messages (
  id         TEXT PRIMARY KEY,
  session_id TEXT NOT NULL REFERENCES sessions(id),
  role       TEXT NOT NULL,
  parts      TEXT NOT NULL,  -- JSON-encoded [MessagePart]
  created_at TEXT NOT NULL
);
```

### 3.7 `OpenCode.MCP`
MCP client wrapping the `mcp-server` Hackage package.

```haskell
data McpClient = McpClient
  { listTools :: IO [ToolDefinition]
  , callTool  :: Text -> Aeson.Value -> IO ToolResult
  }

connectMcpStdio :: FilePath -> [Text] -> IO McpClient
```

MCP tools are merged into `ToolRegistry` at session start.

### 3.8 `OpenCode.TUI`
`brick`-based terminal UI.

```haskell
data AppState = AppState
  { messages   :: Seq RenderedMessage
  , inputBuf   :: Editor Text ResourceName
  , runState   :: RunState
  , scrollPos  :: ViewportScroll ResourceName
  , statusLine :: Text
  }

data ResourceName = ChatViewport | InputEditor | StatusBar

-- brick App definition
app :: App AppState SessionEvent ResourceName

-- Custom events fed from the session loop via BChan
data SessionEvent
  = MessageAppended Message
  | PartialText Text         -- streaming text delta
  | ToolStarted Text
  | ToolFinished Text Text   -- name result
  | RunStateChanged RunState
  | ErrorOccurred Text
```

Layout:
```
┌─────────────────────────────┐
│  Chat history (scrollable)  │  ← Viewport
│  [User] prompt text         │
│  [Assistant] response text  │
│    ⚙ bash: ls -la           │  ← tool call inline
│    > file1.txt ...          │  ← tool result
│─────────────────────────────│
│  Status: Running... [ESC]   │  ← status bar
│> user input here            │  ← Editor
└─────────────────────────────┘
```

Keybindings:
- `Enter` / `Ctrl+Enter` — submit
- `Esc` — abort running LLM/tool
- `PgUp/PgDn` / `Ctrl+U/D` — scroll history
- `Ctrl+C` — quit

### 3.9 `OpenCode.App`
Application monad and environment.

```haskell
data AppEnv = AppEnv
  { envConfig    :: Config
  , envDb        :: Connection
  , envRegistry  :: ToolRegistry
  , envEventChan :: BChan SessionEvent
  , envAbort     :: TVar Bool
  }

type AppM = ReaderT AppEnv (ExceptT AppError IO)

data AppError
  = ConfigError Text
  | LLMError Text
  | ToolError Text Text     -- tool name, message
  | DatabaseError Text
  | MCPError Text

runAppM :: AppEnv -> AppM a -> IO (Either AppError a)
```

---

## 4. Data Flow

```
User types prompt → InputEditor
  → Enter key → handleEvent → enqueue in BChan
    → background thread: processUserMessage
      → build Message, persist, emit MessageAppended
      → call agentic loop:
          → streamCompletion → ConduitT StreamEvent
            → on TextDelta: emit PartialText to BChan → TUI renders
            → on ToolCallEnd: execute tool
              → emit ToolStarted / ToolFinished
              → append ToolResultPart, persist
          → recurse until no tool calls or maxRounds
      → emit RunStateChanged Idle
    → TUI re-renders from final state
```

---

## 5. Key Dependencies

| Purpose | Package |
|---|---|
| HTTP client | `http-conduit` |
| Streaming | `conduit`, `conduit-extra` |
| JSON | `aeson` |
| YAML config | `yaml` |
| SQLite | `sqlite-simple` |
| TUI | `brick`, `vty` |
| Text editor widget | `brick` (built-in `Editor`) |
| MCP client | `mcp-server` (v0.1.0.19) |
| CLI parsing | `optparse-applicative` |
| UUID/ULID | `uuid` |
| Time | `time` |
| Async/STM | `async`, `stm` |
| Logging | `fast-logger` |
| Process | `process` |
| File glob | `Glob` |

---

## 6. File Structure

```
opencode-hs/
├── package.yaml              (hpack)
├── stack.yaml
├── app/
│   └── Main.hs               (CLI entry point)
├── src/
│   ├── OpenCode/
│   │   ├── App.hs            (AppM, AppEnv, AppError)
│   │   ├── Config.hs         (Config, loadConfig)
│   │   ├── Types.hs          (all core ADTs)
│   │   ├── DB.hs             (SQLite layer)
│   │   ├── LLM/
│   │   │   ├── Types.hs      (StreamEvent, ToolDefinition)
│   │   │   ├── OpenAI.hs     (OpenAI SSE parsing)
│   │   │   ├── Anthropic.hs  (Anthropic SSE parsing)
│   │   │   └── Request.hs    (shared request helpers)
│   │   ├── Tool/
│   │   │   ├── Types.hs      (ToolDef GADT, SomeTool, Registry)
│   │   │   ├── ReadFile.hs
│   │   │   ├── WriteFile.hs
│   │   │   ├── EditFile.hs
│   │   │   ├── Bash.hs
│   │   │   ├── Glob.hs
│   │   │   └── Grep.hs
│   │   ├── Session.hs        (conversation loop)
│   │   ├── MCP.hs            (MCP client adapter)
│   │   └── TUI/
│   │       ├── App.hs        (brick App, event loop)
│   │       ├── Render.hs     (draw functions)
│   │       └── Types.hs      (AppState, ResourceName, SessionEvent)
└── test/
    ├── OpenCode/
    │   ├── LLMSpec.hs
    │   ├── ToolSpec.hs
    │   └── SessionSpec.hs
    └── Spec.hs
```

---

## 7. Error Handling Philosophy

- All `AppM` errors are typed via `AppError` ADT — no partial functions
- `ExceptT AppError IO` at the boundary; internal helpers return `Either` or `Maybe`
- Streaming errors (network drop, rate limit) convert to `StreamError` events, shown inline in TUI
- Tool execution errors are non-fatal: produce `ToolResultPart { isError = True }` and continue
- Fatal errors (bad config, DB failure) propagate to `main` and print with exit code 1

---

## 8. Functional Programming Principles

| Principle | How applied |
|---|---|
| Immutable data | All state in `TVar`/`TChan`; ADTs everywhere |
| Effect typing | `AppM = ReaderT AppEnv (ExceptT AppError IO)` |
| GADTs | Tool system — type-safe input/output per tool |
| Typeclasses | `LLMProvider` for provider abstraction |
| Conduit streaming | LLM responses as `ConduitT () StreamEvent IO ()` |
| STM | Abort signal, run state, event channel |
| Avoid partial functions | `NonEmpty` for message parts, exhaustive pattern matching |
| Newtype wrappers | `SessionId`, `MessageId`, `ApiKey` — no stringly typed IDs |
