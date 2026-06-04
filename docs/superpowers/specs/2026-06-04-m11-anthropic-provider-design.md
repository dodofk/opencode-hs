# M11 — Anthropic provider — Design

**Status:** Design approved 2026-06-04 (brainstorming). Branch: `main`.
**Scope source:** Expands `MILESTONES.md` §M11 with the decisions resolved during brainstorming.

## Goal

Add Anthropic as a fully-supported streaming provider, reusing the M4 SSE
infrastructure. After this milestone `anthropic:<model>` works end-to-end: real
streaming text, tool calls, `config check`, and the agentic loop — the same as
OpenAI/MiniMax today.

## Current state (verified against code)

- `Request.chunkSSELines` and `Request.sseDataLine` (`OpenCode.LLM.Request`) are
  provider-agnostic SSE plumbing — directly reusable.
- `OpenCode.LLM.OpenAI` is the template: provider record, wire types with
  `FromJSON`, a per-event accumulator (`processChunk :: Accum -> Chunk ->
  ([StreamEvent], Accum)`), a pure `interpretOpenAIStream :: ConduitT ByteString
  StreamEvent m ()`, and `streamOpenAI` (HTTP via `HTTP.httpSource`, 2xx → pipe
  body through the interpreter, non-2xx → drain + one `StreamError`).
- `OpenCode.LLM.Schema` holds the OpenAI *request-body* shapes:
  `toolToOpenAISchema`, `messagesToOpenAI`, `buildOpenAIRequestBody`. Its
  `messageToOpenAI` already handles the M6 tool-round split (an assistant
  message bundling `ToolCallPart` + `ToolResultPart` is emitted as an assistant
  `tool_calls` message followed by `role:"tool"` results).
- `OpenCode.LLM.Anthropic` is a stub: `newtype AnthropicProvider { apiKey }`, an
  `error "…not yet implemented (M11)"` `LLMProvider` instance, and an `_unused`
  shim. Already in `package.yaml` `exposed-modules`.
- `OpenCode.Session.streamerForProvider` returns `Left (LLMError "Anthropic
  streaming is not yet implemented…")` for the `Anthropic` arm.
- `OpenCode.Run.checkProvider` short-circuits a configured Anthropic key to
  `"FAIL (not implemented until M11)"`; `probeModel cfg Anthropic = ""`.
- `OpenCode.Config.fallbackModel = ModelId Anthropic "claude-opus-4-5"`;
  `defaultMiniMaxModel` is exported (pattern to mirror).
- Internal types: `LLMRequest { reqModel, reqMessages, reqTools,
  reqSystemPrompt :: Text, reqMaxTokens :: Maybe Int }`; `ToolArgs` is raw JSON
  *text*; `StreamEvent` = `TextDelta | ToolCallStart id name | ToolCallArgDelta
  id frag | ToolCallEnd id | StreamDone Usage | StreamError Text`.
- Fixtures live at `test/fixtures/openai/*.sse`; `OpenAISpec` replays them via a
  `runStream "<path>"` helper.

## Decisions resolved in brainstorming

1. **Architecture: mirror the OpenAI/Schema split (chosen option ①).** Anthropic
   *request-shaping* (`toolToAnthropicSchema`, `messagesToAnthropic`,
   `buildAnthropicRequestBody`) goes into `OpenCode.LLM.Schema` beside the OpenAI
   builders; Anthropic *streaming* (provider record, SSE event types,
   accumulator, interpreter, HTTP) goes into `OpenCode.LLM.Anthropic`. *Rejected:*
   one self-contained Anthropic module (diverges from the OpenAI split, one large
   file); a namespaced `OpenCode.LLM.Anthropic.Schema` (over-structured for one
   provider).
2. **`max_tokens` is always sent.** Anthropic *requires* it. `reqMaxTokens =
   Nothing` → `defaultAnthropicMaxTokens = 4096`.
3. **Prompt caching is included.** A non-empty system prompt is sent as the
   top-level `system` field carrying `cache_control: { type: "ephemeral" }`.
4. **Default Anthropic model** = `"claude-opus-4-5"` (matches the existing
   `fallbackModel`), added as an exported `Config.defaultAnthropicModel` and used
   by `probeModel`.
5. **Tool results go in a `user` turn.** Unlike OpenAI's `role:"tool"`, Anthropic
   carries tool results as `tool_result` content blocks inside a `user` message.
6. **`ToolArgs` text is decoded to a JSON object** for `tool_use.input` (Anthropic
   wants an object, not a string); a non-decodable blob falls back to `{}`.
7. **SSE dispatch on the JSON `type` field**, not the `event:` line — each
   Anthropic `data:` payload is self-describing, so `sseDataLine` + a `"type"`
   switch suffices (no need to track `event:` lines).

## Components / changes

### 1. `OpenCode.LLM.Anthropic` (replace the stub)

```haskell
data AnthropicProvider = AnthropicProvider { apiKey :: ApiKey, baseUrl :: Text }
defaultAnthropic :: ApiKey -> AnthropicProvider   -- baseUrl "https://api.anthropic.com"
```

**SSE event model** — decode each `data:` payload and dispatch on `"type"`:

```haskell
data AnthropicEvent
  = EvMessageStart   Int                 -- input_tokens (from message.usage)
  | EvBlockStart     Int BlockStart      -- content index, block kind
  | EvBlockDelta     Int BlockDelta      -- content index, delta kind
  | EvBlockStop      Int
  | EvMessageDelta   (Maybe Int)         -- output_tokens (from usage)
  | EvMessageStop
  | EvPing
  | EvError          Text
  | EvOther                              -- unknown type → ignored

data BlockStart = BlockText | BlockToolUse Text Text   -- id, name
data BlockDelta = DeltaText Text | DeltaInputJson Text
```

`FromJSON AnthropicEvent` reads `type` and the relevant nested fields
(`content_block.type`, `delta.type`, `message.usage.input_tokens`,
`usage.output_tokens`, `error.message`); unrecognized types parse to `EvOther`.

**Accumulator** (mirrors OpenAI's `ToolCallAccum`):

```haskell
data AnthropicAccum = AnthropicAccum
  { accBlocks :: Map Int Text   -- content index → callId (tool_use blocks)
  , accInput  :: Int            -- input tokens carried from message_start
  }

processAnthropicEvent :: AnthropicAccum -> AnthropicEvent -> ([StreamEvent], AnthropicAccum)
```

| Event | Emits | State |
|---|---|---|
| `EvMessageStart n` | — | `accInput = n` |
| `EvBlockStart i (BlockToolUse cid name)` | `ToolCallStart cid name` | insert `i→cid` |
| `EvBlockStart i BlockText` | — | — |
| `EvBlockDelta i (DeltaText t)` | `TextDelta t` (when non-empty) | — |
| `EvBlockDelta i (DeltaInputJson frag)` | `ToolCallArgDelta cid frag` (look up `i`) | — |
| `EvBlockStop i` | `ToolCallEnd cid` (when `i` is a tool block) | — |
| `EvMessageDelta (Just out)` | `StreamDone (Usage accInput out Nothing Nothing)` | — |
| `EvError e` | `StreamError e` | — |
| `EvPing`/`EvMessageStop`/`EvOther`/`EvMessageDelta Nothing` | — | — |

**Interpreter + HTTP** (parallels OpenAI):

```haskell
interpretAnthropicStream :: MonadIO m => ConduitT ByteString StreamEvent m ()
-- = Request.chunkSSELines .| translate (sseDataLine → decode → processAnthropicEvent)

streamAnthropic :: AnthropicProvider -> LLMRequest -> ConduitT () StreamEvent (ResourceT IO) ()
-- POST <baseUrl>/v1/messages ; headers: x-api-key, anthropic-version: 2023-06-01,
-- content-type: application/json, accept: text/event-stream ;
-- body = Schema.buildAnthropicRequestBody req ; responseTimeout = none.
-- 2xx → getResponseBody .| interpretAnthropicStream ; non-2xx → drain + one
-- StreamError via anthropicErrorFromHttp (prefix "anthropic: <code>: <snippet>").

anthropicErrorFromHttp :: Int -> ByteString -> StreamEvent

instance LLMProvider AnthropicProvider where streamCompletion = streamAnthropic
```

Malformed `data:` payloads are ignored (decode failure → skip), matching
`interpretOpenAIStream`. `[DONE]` is not used by Anthropic; the stream ends on
`message_stop`/connection close.

### 2. `OpenCode.LLM.Schema` (Anthropic request shapes)

```haskell
toolToAnthropicSchema :: ToolDefinition -> Value
-- { "name": tdName, "description": tdDescription, "input_schema": tdSchema }

messagesToAnthropic :: [Message] -> [Value]
buildAnthropicRequestBody :: LLMRequest -> Value
```

- `buildAnthropicRequestBody req`: object with `model = reqModel`,
  `max_tokens = fromMaybe defaultAnthropicMaxTokens (reqMaxTokens req)`,
  `stream = True`, `messages = messagesToAnthropic (reqMessages req)`, `tools`
  (only when non-empty), and — when `reqSystemPrompt` is non-empty — a top-level
  `system` array: `[{ "type":"text", "text":<prompt>, "cache_control":{"type":"ephemeral"} }]`.
  `defaultAnthropicMaxTokens :: Int = 4096`.
- `messagesToAnthropic`: per internal `Message`, emit one or two Anthropic
  messages.
  - `RoleUser` with `TextPart`s → `{ role:"user", content:[{type:text,text}] }`.
  - `RoleAssistant`:
    - text parts → `text` content blocks;
    - `ToolCallPart tc` → `tool_use` block `{ type:"tool_use", id:callId,
      name:toolName, input:<decoded ToolArgs object> }`;
    - emit the `assistant` message with the text + tool_use blocks, and **if any
      `ToolResultPart`s are bundled**, follow it with a `{ role:"user",
      content:[{type:"tool_result", tool_use_id:resultCallId, content}] }` message.
  - `RoleTool` (not produced by the loop today, but handled for symmetry) →
    a `user` message of `tool_result` blocks.
  - `ErrorPart`s are dropped from the wire (as in `messagesToOpenAI` they become
    system text; Anthropic has no clean slot — drop, matching "don't send our
    own error strings to the model").
  - `decodeArgs :: ToolArgs -> Value` = `fromMaybe (object []) (Aeson.decodeStrict (encodeUtf8 (unToolArgs a)))` (`encodeUtf8` is strict, so use `decodeStrict`).

### 3. `OpenCode.Config`

Add `defaultAnthropicModel :: Text = "claude-opus-4-5"` and export it; redefine
`fallbackModel` to use it (no value change).

### 4. `OpenCode.Session`

The existing `withKey` helper hardcodes `OpenAI.streamOpenAI (mkProvider key)`,
so it can't build an Anthropic streamer. Generalize it to take a full
`ApiKey -> Streamer` builder, and have each arm supply its own:

```haskell
streamerForProvider cfg pid = case pid of
  OpenAI    -> withKey (Config.openaiKey    pc) "OpenAI"
                 (OpenAI.streamOpenAI . OpenAI.defaultOpenAI)
  MiniMax   -> withKey (Config.minimaxKey   pc) "MiniMax"
                 (OpenAI.streamOpenAI . OpenAI.minimaxOpenAI)
  Anthropic -> withKey (Config.anthropicKey pc) "Anthropic"
                 (Anthropic.streamAnthropic . Anthropic.defaultAnthropic)
  where
    pc = Config.providers cfg
    withKey mKey label mkStreamer = case mKey of
      Nothing  -> Left (LLMError ("no " <> label <> " API key configured"))
      Just key -> Right (mkStreamer key)
```

This removes the Anthropic `Left` and keeps OpenAI/MiniMax behavior identical
(`streamOpenAI . defaultOpenAI` ≡ the old `streamOpenAI (defaultOpenAI key)`).
Add an `import qualified OpenCode.LLM.Anthropic as Anthropic`.

### 5. `OpenCode.Run`

`checkProvider`: delete the Anthropic `"FAIL (not implemented until M11)"`
short-circuit so a configured Anthropic key probes through `streamerForProvider`
like the others. `probeModel cfg Anthropic = defaultAnthropicModel`.

### 6. `package.yaml`

Add `OpenCode.LLM.AnthropicSpec` to the test `other-modules`.
`OpenCode.LLM.Anthropic` is already exposed. No new dependencies (`http-conduit`,
`aeson`, `conduit` already present).

## Data flow

`LLMRequest → buildAnthropicRequestBody → POST /v1/messages (stream) → SSE bytes
→ chunkSSELines → sseDataLine → decode AnthropicEvent → processAnthropicEvent →
StreamEvent` — consumed by the existing `agentic` loop unchanged.

## Error handling

- Non-2xx HTTP → one `StreamError "anthropic: <code>: <body-snippet>"` (200-char
  cap, lenient UTF-8), then terminate — exactly like `streamErrorFromHttp`.
- Mid-stream `error` event → one `StreamError <message>`.
- Malformed/unknown SSE payloads → ignored (`EvOther` / decode failure skipped).

## Testing (TDD)

- **Fixtures** `test/fixtures/anthropic/`:
  - `text-stream.sse`: `message_start` → `content_block_start`(text) →
    `content_block_delta`×N (text_delta) → `content_block_stop` → `message_delta`
    (output usage) → `message_stop`.
  - `tool-call-stream.sse`: `content_block_start`(tool_use id+name) →
    `content_block_delta`×N (input_json_delta fragments) → `content_block_stop` →
    `message_delta`.
  - `error.sse`: a single `error` event.
- **`AnthropicSpec`** (mirror `OpenAISpec`):
  - `interpretAnthropicStream` over `text-stream.sse` → reassembled `TextDelta`s
    + final `StreamDone` with the fixture usage.
  - over `tool-call-stream.sse` → exactly one `ToolCallStart`, ordered
    `ToolCallArgDelta`s, one `ToolCallEnd`, one `StreamDone`.
  - over `error.sse` → exactly one `StreamError`.
  - `processAnthropicEvent` unit cases (tool-use start/delta/stop; text; usage).
  - `anthropicErrorFromHttp` contains the status code.
- **`SchemaSpec`** additions:
  - `buildAnthropicRequestBody`: `stream:true`; `max_tokens` defaults to 4096 when
    `Nothing` and is honored when `Just`; `system` present with `cache_control`
    when the prompt is non-empty and absent when empty.
  - `messagesToAnthropic`: a bundled call+result assistant message → an
    `assistant` message with a `tool_use` block followed by a `user` message with
    a matching `tool_result` (`tool_use_id`); `tool_use.input` is a JSON object,
    not a string.
  - `toolToAnthropicSchema` wraps `{name, description, input_schema}`.

## Acceptance

- `stack test --ta '--match "Anthropic"'` passes; full suite green; `-Wall` and
  `hlint` clean.
- `stack run opencode-hs -- config check` with `ANTHROPIC_API_KEY` set reports
  `anthropic: OK`.
- `stack run opencode-hs -- run --prompt "hello" --model anthropic:claude-opus-4-5
  --no-tui` (with a key) prints a real streamed response.

*(Live acceptance needs an Anthropic key; the fixture-replay tests are the
primary verification, as they were for OpenAI in M4.)*

## Out of scope (M12 and beyond)

Extended-thinking / `reasoning_content` rendering (the shared M12 task),
context-window summarization, `--version`, SIGINT. Anthropic-specific beta
features beyond text + tool_use + prompt caching.
