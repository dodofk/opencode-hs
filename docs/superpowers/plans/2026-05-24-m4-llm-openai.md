# M4 — LLM Streaming (OpenAI only) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stream completions from OpenAI as a `ConduitT () StreamEvent (ResourceT IO) ()`, handling text deltas, tool calls (including fragmented JSON arguments), final usage, and HTTP errors. Add a mock provider for downstream session-loop tests.

**Architecture:** A pure-streaming pipeline in `OpenCode.LLM.OpenAI` composes (1) raw-byte chunking into SSE lines, (2) `sseDataLine` payload extraction with `[DONE]` sentinel detection, (3) JSON decoding into a `ChatCompletionChunk` wire type, (4) a per-tool-call argument accumulator that emits `ToolCallStart` / `ToolCallArgDelta` / `ToolCallEnd` events, and (5) final `StreamDone` on `finish_reason`. `streamOpenAI` wraps this with `http-conduit`'s `httpSource`, handling 4xx/5xx by draining the body and emitting a single `StreamError`. A small `OpenCode.LLM.Schema` module wraps `ToolDefinition` into OpenAI's tool envelope and converts `[Message]` to OpenAI's chat format. `OpenCode.LLM.Mock` provides a scripted-stream helper for M6's session loop tests.

**Tech stack:** `http-conduit 2.3.8+`, `conduit 1.3.5+`, `conduit-extra 1.3+`, `aeson 2.1+`, `bytestring 0.11+`, `text 2.0+`. No new dependencies.

---

## File structure

| Path | Action | Responsibility |
| ---- | ------ | -------------- |
| `src/OpenCode/LLM/Types.hs` | edit | Add `reqModel`; relax `reqMaxTokens` to `Maybe Int`; widen typeclass effect to `ResourceT IO` |
| `src/OpenCode/LLM/Request.hs` | edit | Split `[DONE]` out of `sseDataLine`; add `chunkSSELines` conduit |
| `src/OpenCode/LLM/OpenAI.hs` | edit (large) | Wire types, JSON decoder, tool-call accumulator, pure pipeline, HTTP integration |
| `src/OpenCode/LLM/Anthropic.hs` | edit | Tighten `apiKey :: Text` to `apiKey :: ApiKey` (matches OpenAI; stub stays an `error`) |
| `src/OpenCode/LLM/Schema.hs` | create | `toolToOpenAISchema`, `messagesToOpenAI`, `buildOpenAIRequestBody` |
| `src/OpenCode/LLM/Mock.hs` | create | `mockStreamCompletion` — emits scripted `[StreamEvent]` |
| `test/OpenCode/LLM/RequestSpec.hs` | create | Tests for `sseDataLine`, `chunkSSELines` |
| `test/OpenCode/LLM/OpenAISpec.hs` | create | Tests for `ChatCompletionChunk` decoder, tool-call accumulator, full pipeline against fixtures |
| `test/OpenCode/LLM/SchemaSpec.hs` | create | Tests for `toolToOpenAISchema`, `messagesToOpenAI`, `buildOpenAIRequestBody` |
| `test/OpenCode/LLM/MockSpec.hs` | create | Trivial round-trip test for `mockStreamCompletion` |
| `test/OpenCode/LLMSpec.hs` | delete | Placeholder from M0; replaced by per-module specs |
| `test/fixtures/openai/text-stream.sse` | create | 5-event SSE body for text-only completion |
| `test/fixtures/openai/tool-call-stream.sse` | create | 6-event SSE body for a fragmented tool call |
| `test/fixtures/openai/done-only.sse` | create | Single `data: [DONE]\n\n` for sentinel test |
| `package.yaml` | edit | Add `OpenCode.LLM.Schema` and `OpenCode.LLM.Mock` to `exposed-modules`; (cabal regenerates) |
| `MILESTONES.md` | edit (final task) | Mark M4 done |

The skeleton `_unused :: (LLMRequest, StreamEvent) -> ()` placeholder in `OpenCode/LLM/OpenAI.hs` (used to silence M0's unused-import warnings) is deleted once the real implementation references those types. The same placeholder in `OpenCode/LLM/Anthropic.hs` stays — Anthropic is still a stub until M11.

---

## Toolchain note

`stack`/`ghc` live at `~/.ghcup/bin` and are NOT on the default `$PATH` for non-interactive shells. `hlint` v3.10 is at `/opt/homebrew/bin/hlint` (already on `$PATH`). Every Bash invocation that calls `stack` MUST prefix with `export PATH="$HOME/.ghcup/bin:$PATH" &&`.

CI is now in place from M3 (`.github/workflows/ci.yml`); each push to `main` runs `stack build` + `stack test` on ubuntu+macos and `hlint src app test verify` on ubuntu. Tasks below assume local tests pass before pushing; CI is the safety net.

---

## Wire-format reference (OpenAI Chat Completions, streaming)

### Request body (POST /v1/chat/completions)

```json
{
  "model": "gpt-4o",
  "messages": [
    {"role": "system", "content": "You are…"},
    {"role": "user", "content": "Hello"},
    {"role": "assistant", "content": null, "tool_calls": [
      {"id": "call_abc", "type": "function", "function": {"name": "bash", "arguments": "{\"command\":\"ls\"}"}}
    ]},
    {"role": "tool", "tool_call_id": "call_abc", "content": "file.txt\n"}
  ],
  "tools": [
    {"type": "function", "function": {
      "name": "bash",
      "description": "Run a shell command",
      "parameters": {"type": "object", "properties": {"command": {"type": "string"}}, "required": ["command"]}
    }}
  ],
  "stream": true,
  "max_tokens": 4096
}
```

Headers: `Authorization: Bearer <api-key>`, `Content-Type: application/json`.

### Response stream

```
data: {"id":"chatcmpl-abc","choices":[{"index":0,"delta":{"role":"assistant","content":""},"finish_reason":null}]}

data: {"id":"chatcmpl-abc","choices":[{"index":0,"delta":{"content":"Hello"},"finish_reason":null}]}

data: {"id":"chatcmpl-abc","choices":[{"index":0,"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":10,"completion_tokens":2,"total_tokens":12}}

data: [DONE]
```

Each event is `data: <json>\n\n`. The final `data: [DONE]\n\n` is a sentinel meaning "stream over" (no JSON payload).

### Tool-call streaming

```
data: {"id":"x","choices":[{"delta":{"role":"assistant","content":null,"tool_calls":[{"index":0,"id":"call_abc","type":"function","function":{"name":"bash","arguments":""}}]},"finish_reason":null}]}

data: {"id":"x","choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\""}}]},"finish_reason":null}]}

data: {"id":"x","choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"command\":\""}}]},"finish_reason":null}]}

data: {"id":"x","choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"echo hi\"}"}}]},"finish_reason":null}]}

data: {"id":"x","choices":[{"delta":{},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":50,"completion_tokens":15,"total_tokens":65}}

data: [DONE]
```

Tool calls are identified by their `index` within the choices array; the first chunk for an index supplies `id` + `function.name`, subsequent chunks add `function.arguments` fragments. `finish_reason` arrives in a chunk with `delta: {}` (no further content) and `usage` on the same chunk.

---

## Task 1 — Reshape LLM.Types and provider records

**Files:**
- Modify: `src/OpenCode/LLM/Types.hs`
- Modify: `src/OpenCode/LLM/OpenAI.hs`
- Modify: `src/OpenCode/LLM/Anthropic.hs`

This is a refactor task. Behavior doesn't change (the stub instances still `error`), but the types are tightened to support what M4 needs.

- [ ] **Step 1.1: Verify baseline build/tests**

```
export PATH="$HOME/.ghcup/bin:$PATH" && stack test 2>&1 | tail -3
```

Expected: `56 examples, 0 failures`.

- [ ] **Step 1.2: Rewrite `src/OpenCode/LLM/Types.hs`**

Overwrite the file:

```haskell
-- | Shared types for the LLM client layer.
module OpenCode.LLM.Types
  ( ToolDefinition (..)
  , LLMRequest (..)
  , LLMProvider (..)
  ) where

import Conduit (ConduitT)
import Control.Monad.Trans.Resource (ResourceT)
import Data.Aeson (Value)
import Data.Text (Text)
import OpenCode.Types (Message, StreamEvent)

-- ---------------------------------------------------------------------------
-- Tool definition (sent to the LLM so it knows what tools are available)
-- ---------------------------------------------------------------------------

data ToolDefinition = ToolDefinition
  { tdName        :: Text
  , tdDescription :: Text
  , tdSchema      :: Value   -- ^ JSON Schema object describing the input
  }
  deriving stock (Show, Eq)

-- ---------------------------------------------------------------------------
-- Request
-- ---------------------------------------------------------------------------

data LLMRequest = LLMRequest
  { reqModel        :: Text         -- ^ Model identifier, e.g. "gpt-4o"
  , reqMessages     :: [Message]    -- ^ Conversation history; system goes in reqSystemPrompt
  , reqTools        :: [ToolDefinition]
  , reqSystemPrompt :: Text         -- ^ Empty string means no system prompt
  , reqMaxTokens    :: Maybe Int    -- ^ Nothing = let the provider pick its default
  }
  deriving stock (Show, Eq)

-- ---------------------------------------------------------------------------
-- Provider typeclass
-- ---------------------------------------------------------------------------

class LLMProvider p where
  streamCompletion
    :: p
    -> LLMRequest
    -> ConduitT () StreamEvent (ResourceT IO) ()
```

Three changes from the M0 skeleton: added `reqModel :: Text`, changed `reqMaxTokens :: Int` to `Maybe Int`, widened the typeclass effect to `ConduitT () StreamEvent (ResourceT IO) ()`. The new `Control.Monad.Trans.Resource` import comes from the `resourcet` package, which is a transitive dep of `conduit-extra` already in `package.yaml`.

- [ ] **Step 1.3: Update `src/OpenCode/LLM/OpenAI.hs` to use `ApiKey` and the new effect type**

The current file is:

```haskell
-- | OpenAI provider: streaming completions via SSE.
module OpenCode.LLM.OpenAI
  ( OpenAIProvider (..)
  , defaultOpenAI
  ) where

import Data.Text (Text)
import OpenCode.LLM.Types (LLMProvider (..), LLMRequest)
import OpenCode.Types (StreamEvent)

data OpenAIProvider = OpenAIProvider
  { apiKey  :: Text
  , baseUrl :: Text
  }
  deriving stock (Show, Eq)

instance LLMProvider OpenAIProvider where
  streamCompletion _ _ = error "OpenCode.LLM.OpenAI: not yet implemented (M3b)"

defaultOpenAI :: Text -> OpenAIProvider
defaultOpenAI key = OpenAIProvider
  { apiKey  = key
  , baseUrl = "https://api.openai.com"
  }

_unused :: (LLMRequest, StreamEvent) -> ()
_unused _ = ()
```

Replace the `data OpenAIProvider` and `defaultOpenAI` with:

```haskell
data OpenAIProvider = OpenAIProvider
  { apiKey  :: ApiKey
  , baseUrl :: Text         -- ^ defaults to "https://api.openai.com"
  }
  deriving stock (Show, Eq)

defaultOpenAI :: ApiKey -> OpenAIProvider
defaultOpenAI key = OpenAIProvider
  { apiKey  = key
  , baseUrl = "https://api.openai.com"
  }
```

Add to the existing imports:

```haskell
import OpenCode.Types (ApiKey, StreamEvent)
```

(Replace the existing `import OpenCode.Types (StreamEvent)` with the above — combine into one line.)

Leave the stub `instance` and `_unused` placeholders as-is; Task 7 replaces them. Update the obsolete `M3b` reference in the stub error message to `M4`:

```haskell
instance LLMProvider OpenAIProvider where
  streamCompletion _ _ = error "OpenCode.LLM.OpenAI: not yet implemented (M4)"
```

- [ ] **Step 1.4: Update `src/OpenCode/LLM/Anthropic.hs` for `ApiKey` consistency**

Replace the existing `data AnthropicProvider`:

```haskell
data AnthropicProvider = AnthropicProvider
  { apiKey :: Text
  }
```

with:

```haskell
data AnthropicProvider = AnthropicProvider
  { apiKey :: ApiKey
  }
```

(The `newtype` change from M3 Task 1 stays — only the field type changes.) Update the file's imports to bring in `ApiKey` from `OpenCode.Types` (the existing import already names `StreamEvent` from there).

The file's stub error message should remain `M11` (the milestone where Anthropic actually lands). If it currently says `M3c`, update to `M11`.

- [ ] **Step 1.5: Build + test**

```
export PATH="$HOME/.ghcup/bin:$PATH" && stack build 2>&1 | tail -10 && stack test 2>&1 | tail -3
```

Expected: clean build, `56 examples, 0 failures`. No new warnings.

- [ ] **Step 1.6: Confirm hlint still clean**

```
hlint src app test verify 2>&1 | tail -3
```

Expected: `No hints`. If any appear from the new code, fix them inline before committing.

- [ ] **Step 1.7: Commit**

```
git add src/OpenCode/LLM/Types.hs src/OpenCode/LLM/OpenAI.hs src/OpenCode/LLM/Anthropic.hs
git commit -m "M4: tighten LLM.Types and provider records (ApiKey, ResourceT, reqModel)"
```

---

## Task 2 — Split `[DONE]` out of `sseDataLine` + add `chunkSSELines` conduit

**Files:**
- Modify: `src/OpenCode/LLM/Request.hs`
- Create: `test/OpenCode/LLM/RequestSpec.hs`

The existing `sseDataLine` conflates `data: [DONE]` (end-of-stream sentinel) with non-data lines (comments, blanks). We need to distinguish them — `[DONE]` means "stop", others mean "skip and keep reading."

We also need to chunk a raw `ByteString` conduit (which `http-conduit` produces in arbitrary-sized pieces) into one `ByteString` per logical line.

### Step 2.1: Write the failing tests

Create `test/OpenCode/LLM/RequestSpec.hs`:

```haskell
module OpenCode.LLM.RequestSpec (spec) where

import Conduit (ConduitT, runConduit, sourceList, sinkList, (.|))
import Control.Monad.Identity (Identity, runIdentity)
import Data.ByteString (ByteString)
import Test.Hspec

import OpenCode.LLM.Request

spec :: Spec
spec = do
  describe "sseDataLine" $ do

    it "extracts payload from a data: line" $
      sseDataLine "data: {\"foo\":1}" `shouldBe` Just "{\"foo\":1}"

    it "returns Just \"[DONE]\" for the done sentinel" $
      sseDataLine "data: [DONE]" `shouldBe` Just "[DONE]"

    it "returns Nothing for a comment line" $
      sseDataLine ": this is a comment" `shouldBe` Nothing

    it "returns Nothing for an event: line" $
      sseDataLine "event: ping" `shouldBe` Nothing

    it "returns Nothing for a blank line" $
      sseDataLine "" `shouldBe` Nothing

  describe "chunkSSELines" $ do

    it "splits a single complete line into one chunk" $
      runChunker ["data: hello\n"] `shouldBe` ["data: hello"]

    it "handles a line split across two input chunks" $
      runChunker ["data: hel", "lo\n"] `shouldBe` ["data: hello"]

    it "handles two lines in one input chunk" $
      runChunker ["data: a\ndata: b\n"] `shouldBe` ["data: a", "data: b"]

    it "preserves order across many splits" $
      runChunker ["da", "ta: a\nda", "ta: b\nda", "ta: c\n"]
        `shouldBe` ["data: a", "data: b", "data: c"]

    it "emits blank lines as empty bytestrings" $
      runChunker ["data: a\n\ndata: b\n"]
        `shouldBe` ["data: a", "", "data: b"]

    it "flushes any unterminated trailing line at end of stream" $
      runChunker ["data: a\ndata: b"]
        `shouldBe` ["data: a", "data: b"]

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

runChunker :: [ByteString] -> [ByteString]
runChunker inputs = runIdentity $ runConduit $
  sourceList inputs .| (chunkSSELines :: ConduitT ByteString ByteString Identity ()) .| sinkList
```

### Step 2.2: Run tests to confirm they fail

```
export PATH="$HOME/.ghcup/bin:$PATH" && stack test --match "OpenCode.LLM.Request" 2>&1 | tail -20
```

Expected: the 5 `sseDataLine` tests around `[DONE]` and the 6 `chunkSSELines` tests fail because (a) the current `sseDataLine` returns `Nothing` for `[DONE]` and (b) `chunkSSELines` doesn't exist yet.

### Step 2.3: Rewrite `src/OpenCode/LLM/Request.hs`

```haskell
-- | Shared request-building utilities used by both provider modules.
module OpenCode.LLM.Request
  ( buildSystemPrompt
  , sseDataLine
  , chunkSSELines
  ) where

import Conduit (ConduitT, await, yield)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BSC
import Data.Text (Text)
import OpenCode.LLM.Types (ToolDefinition)

-- | Build a system prompt from a list of available tool descriptions.
-- Expanded in M6 to include agent-specific instructions and per-tool blocks.
buildSystemPrompt :: [ToolDefinition] -> Text
buildSystemPrompt _ = "You are a helpful AI coding assistant."

-- | Extract the payload from an SSE @data:@ line.
--
--   * @data: <payload>@ → @Just payload@ (including @Just "[DONE]"@)
--   * comments (starting with @:@), @event:@ lines, blanks → @Nothing@
--
-- The caller is responsible for recognizing @"[DONE]"@ as the end-of-stream
-- sentinel; this parser only handles the SSE envelope.
sseDataLine :: ByteString -> Maybe ByteString
sseDataLine bs
  | "data: " `BS.isPrefixOf` bs = Just (BS.drop 6 bs)
  | otherwise                   = Nothing

-- | Chunk a raw byte stream into one 'ByteString' per logical line.
-- Splits on the @\\n@ byte; carriage returns are kept as-is.
-- Any unterminated final line is yielded at end-of-stream.
chunkSSELines :: Monad m => ConduitT ByteString ByteString m ()
chunkSSELines = loop BS.empty
  where
    loop buf = do
      mchunk <- await
      case mchunk of
        Nothing ->
          -- End of input: emit whatever's left as a final line if non-empty.
          if BS.null buf then pure () else yield buf
        Just chunk -> do
          let combined = buf <> chunk
              (complete, rest) = breakLines combined
          mapM_ yield complete
          loop rest

    -- Split a buffer into (complete lines, residual after the last \n).
    breakLines :: ByteString -> ([ByteString], ByteString)
    breakLines b = case BSC.split '\n' b of
      []   -> ([], BS.empty)
      [x]  -> ([], x)       -- no \n seen; entire buffer is residual
      xs   -> (init xs, last xs)
```

`Data.ByteString.Char8` is added to the imports for `split '\n'`. Both `BS` and `BSC` are qualified to keep call sites unambiguous.

### Step 2.4: Run tests to confirm pass

```
export PATH="$HOME/.ghcup/bin:$PATH" && stack test --match "OpenCode.LLM.Request" 2>&1 | tail -10
```

Expected: 11 specs pass (5 `sseDataLine` + 6 `chunkSSELines`); full suite 67 / 0.

### Step 2.5: Confirm hlint clean

```
hlint src app test verify 2>&1 | tail -3
```

Expected: `No hints`.

### Step 2.6: Commit

```
git add src/OpenCode/LLM/Request.hs test/OpenCode/LLM/RequestSpec.hs
git commit -m "M4: split [DONE] handling from sseDataLine + add chunkSSELines conduit"
```

---

## Task 3 — ChatCompletionChunk wire type and JSON decoder

**Files:**
- Modify: `src/OpenCode/LLM/OpenAI.hs`
- Create: `test/OpenCode/LLM/OpenAISpec.hs`

Introduce the internal wire type modeling one OpenAI chunk and a `decodeChunk` function. Manual `FromJSON` instances (rather than Generic) because the JSON uses snake_case fields and several `Maybe` shapes that don't survive Aeson's default options cleanly.

### Step 3.1: Write the failing tests

Create `test/OpenCode/LLM/OpenAISpec.hs`:

```haskell
module OpenCode.LLM.OpenAISpec (spec) where

import Data.ByteString (ByteString)
import Test.Hspec

import OpenCode.LLM.OpenAI

spec :: Spec
spec = do
  describe "decodeChunk" $ do

    it "parses a text-delta chunk" $ do
      let bs :: ByteString
          bs = "{\"id\":\"x\",\"choices\":[{\"index\":0,\"delta\":{\"content\":\"Hello\"},\"finish_reason\":null}]}"
      case decodeChunk bs of
        Left err -> expectationFailure err
        Right c  -> do
          cccId c `shouldBe` "x"
          length (cccChoices c) `shouldBe` 1
          let ch = head (cccChoices c)
          deltaContent (choiceDelta ch) `shouldBe` Just "Hello"
          deltaToolCalls (choiceDelta ch) `shouldBe` Nothing
          choiceFinishReason ch `shouldBe` Nothing
          cccUsage c `shouldBe` Nothing

    it "parses a chunk with a tool-call fragment" $ do
      let bs :: ByteString
          bs = "{\"id\":\"x\",\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"call_abc\",\"type\":\"function\",\"function\":{\"name\":\"bash\",\"arguments\":\"\"}}]},\"finish_reason\":null}]}"
      case decodeChunk bs of
        Right c -> do
          let ch = head (cccChoices c)
          case deltaToolCalls (choiceDelta ch) of
            Just [tcd] -> do
              tcdIndex tcd    `shouldBe` 0
              tcdId tcd       `shouldBe` Just "call_abc"
              fmap fdName (tcdFunction tcd) `shouldBe` Just (Just "bash")
              fmap fdArguments (tcdFunction tcd) `shouldBe` Just (Just "")
            _ -> expectationFailure "expected exactly one tool_call delta"
        Left err -> expectationFailure err

    it "parses a chunk carrying usage on finish_reason" $ do
      let bs :: ByteString
          bs = "{\"id\":\"x\",\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}],\"usage\":{\"prompt_tokens\":10,\"completion_tokens\":2,\"total_tokens\":12}}"
      case decodeChunk bs of
        Right c -> do
          choiceFinishReason (head (cccChoices c)) `shouldBe` Just "stop"
          fmap ccUsagePromptTokens     (cccUsage c) `shouldBe` Just 10
          fmap ccUsageCompletionTokens (cccUsage c) `shouldBe` Just 2
        Left err -> expectationFailure err

    it "returns Left on malformed JSON" $
      case decodeChunk "{ not valid json" of
        Left _  -> pure ()
        Right _ -> expectationFailure "expected Left on bad JSON"
```

### Step 3.2: Run tests to confirm fail

```
export PATH="$HOME/.ghcup/bin:$PATH" && stack test --match "OpenCode.LLM.OpenAI" 2>&1 | tail -15
```

Expected: tests don't compile because `decodeChunk`, `cccId`, `ChatCompletionChunk` etc. don't exist yet.

### Step 3.3: Add the wire type and decoder to `src/OpenCode/LLM/OpenAI.hs`

Open `src/OpenCode/LLM/OpenAI.hs`. After the existing `defaultOpenAI` definition (i.e., before the `_unused` placeholder), add a new section:

```haskell
-- ---------------------------------------------------------------------------
-- Wire types (internal — exposed for tests)
-- ---------------------------------------------------------------------------

-- | One chunk of OpenAI's streaming chat-completion response.
-- Field names mirror the OpenAI JSON shape (snake_case → camelCase prefix).
data ChatCompletionChunk = ChatCompletionChunk
  { cccId      :: Text
  , cccChoices :: [Choice]
  , cccUsage   :: Maybe ChatCompletionUsage
  }
  deriving stock (Show, Eq)

data Choice = Choice
  { choiceIndex        :: Int
  , choiceDelta        :: Delta
  , choiceFinishReason :: Maybe Text
  }
  deriving stock (Show, Eq)

data Delta = Delta
  { deltaContent   :: Maybe Text
  , deltaToolCalls :: Maybe [ToolCallDelta]
  }
  deriving stock (Show, Eq)

data ToolCallDelta = ToolCallDelta
  { tcdIndex    :: Int
  , tcdId       :: Maybe Text
  , tcdFunction :: Maybe FunctionDelta
  }
  deriving stock (Show, Eq)

data FunctionDelta = FunctionDelta
  { fdName      :: Maybe Text
  , fdArguments :: Maybe Text
  }
  deriving stock (Show, Eq)

data ChatCompletionUsage = ChatCompletionUsage
  { ccUsagePromptTokens     :: Int
  , ccUsageCompletionTokens :: Int
  , ccUsageTotalTokens      :: Int
  }
  deriving stock (Show, Eq)

instance FromJSON ChatCompletionChunk where
  parseJSON = withObject "ChatCompletionChunk" $ \o ->
    ChatCompletionChunk
      <$> o .:  "id"
      <*> o .:  "choices"
      <*> o .:? "usage"

instance FromJSON Choice where
  parseJSON = withObject "Choice" $ \o ->
    Choice
      <$> o .:  "index"
      <*> o .:  "delta"
      <*> o .:? "finish_reason"

instance FromJSON Delta where
  parseJSON = withObject "Delta" $ \o ->
    Delta
      <$> o .:? "content"
      <*> o .:? "tool_calls"

instance FromJSON ToolCallDelta where
  parseJSON = withObject "ToolCallDelta" $ \o ->
    ToolCallDelta
      <$> o .:  "index"
      <*> o .:? "id"
      <*> o .:? "function"

instance FromJSON FunctionDelta where
  parseJSON = withObject "FunctionDelta" $ \o ->
    FunctionDelta
      <$> o .:? "name"
      <*> o .:? "arguments"

instance FromJSON ChatCompletionUsage where
  parseJSON = withObject "ChatCompletionUsage" $ \o ->
    ChatCompletionUsage
      <$> o .: "prompt_tokens"
      <*> o .: "completion_tokens"
      <*> o .: "total_tokens"

-- | Decode one SSE payload as a 'ChatCompletionChunk'.
decodeChunk :: ByteString -> Either String ChatCompletionChunk
decodeChunk = Aeson.eitherDecodeStrict
```

Update the module export list to include all new identifiers needed by tests and downstream tasks:

```haskell
module OpenCode.LLM.OpenAI
  ( -- * Provider
    OpenAIProvider (..)
  , defaultOpenAI
    -- * Wire types (internal — exposed for tests)
  , ChatCompletionChunk (..)
  , Choice (..)
  , Delta (..)
  , ToolCallDelta (..)
  , FunctionDelta (..)
  , ChatCompletionUsage (..)
  , decodeChunk
  ) where
```

Add the necessary imports at the top:

```haskell
import Data.Aeson qualified as Aeson
import Data.Aeson (FromJSON (..), (.:), (.:?), withObject)
import Data.ByteString (ByteString)
```

The placeholder `_unused :: (LLMRequest, StreamEvent) -> ()` can now be deleted — both `LLMRequest` and `StreamEvent` are referenced elsewhere in the file (via the typeclass instance and downstream tasks). Actually — keep `_unused` for now since `StreamEvent` is still only referenced by the still-stub `streamCompletion` instance; Task 7 deletes it.

### Step 3.4: Build + test

```
export PATH="$HOME/.ghcup/bin:$PATH" && stack build 2>&1 | tail -5 && stack test --match "OpenCode.LLM.OpenAI" 2>&1 | tail -10
```

Expected: clean build; the 4 `decodeChunk` specs pass; full suite 71 / 0.

### Step 3.5: hlint clean

```
hlint src app test verify 2>&1 | tail -3
```

Expected: `No hints`. If hlint flags `head (cccChoices c)` (which is a partial use), wrap in `case` instead — the test data is hand-crafted so a list-pattern match like `let [ch] = cccChoices c` is safer.

If hlint flags anything else (e.g., a redundant import after the changes), tidy before committing.

### Step 3.6: Commit

```
git add src/OpenCode/LLM/OpenAI.hs test/OpenCode/LLM/OpenAISpec.hs
git commit -m "M4: ChatCompletionChunk wire type and decodeChunk"
```

---

## Task 4 — Tool-call argument accumulator

**Files:**
- Modify: `src/OpenCode/LLM/OpenAI.hs`
- Modify: `test/OpenCode/LLM/OpenAISpec.hs`

A pure state machine over `Map Int ToolCallState`. Consumes one `ChatCompletionChunk` at a time and emits zero or more `StreamEvent`s. The state tracks per-tool-call-index whether `ToolCallStart` has been emitted yet (and the call id, for emitting `ToolCallEnd` later).

### Step 4.1: Add tests

Append to `test/OpenCode/LLM/OpenAISpec.hs` (after the existing `describe "decodeChunk"`):

```haskell
  describe "processChunk" $ do

    it "emits TextDelta for content fragments" $
      let chunk = mkTextChunk "Hello"
          (events, st') = processChunk mempty chunk
      in do
        events `shouldBe` [TextDelta "Hello"]
        st' `shouldBe` mempty

    it "emits ToolCallStart + ToolCallArgDelta on first sight of a tool call" $
      let chunk = mkToolStartChunk 0 "call_abc" "bash" ""
          (events, _) = processChunk mempty chunk
      in events `shouldBe`
           [ ToolCallStart "call_abc" "bash"
           ]

    it "emits ToolCallArgDelta for subsequent argument fragments" $
      let st0 = mempty
          (_, st1) = processChunk st0 (mkToolStartChunk 0 "call_abc" "bash" "")
          (events, _) = processChunk st1
            (mkToolArgChunk 0 "{\"command\":\"ls\"}")
      in events `shouldBe` [ToolCallArgDelta "call_abc" "{\"command\":\"ls\"}"]

    it "emits ToolCallEnd + StreamDone on a finish_reason chunk" $
      let st0 = mempty
          (_, st1) = processChunk st0 (mkToolStartChunk 0 "call_abc" "bash" "")
          chunk = mkFinishChunk "tool_calls" (Just (50, 15, 65))
          (events, _) = processChunk st1 chunk
      in events `shouldBe`
           [ ToolCallEnd "call_abc"
           , StreamDone (Usage 50 15 Nothing Nothing)
           ]

    it "emits StreamDone only (no ToolCallEnd) on a text-only finish_reason" $
      let chunk = mkFinishChunk "stop" (Just (10, 2, 12))
          (events, _) = processChunk mempty chunk
      in events `shouldBe`
           [ StreamDone (Usage 10 2 Nothing Nothing)
           ]

-- ---------------------------------------------------------------------------
-- Test fixtures: small chunk builders so tests are readable
-- ---------------------------------------------------------------------------

mkTextChunk :: Text -> ChatCompletionChunk
mkTextChunk content = ChatCompletionChunk
  { cccId      = "x"
  , cccChoices =
      [ Choice
          { choiceIndex        = 0
          , choiceDelta        = Delta { deltaContent = Just content, deltaToolCalls = Nothing }
          , choiceFinishReason = Nothing
          }
      ]
  , cccUsage   = Nothing
  }

mkToolStartChunk :: Int -> Text -> Text -> Text -> ChatCompletionChunk
mkToolStartChunk idx cid tname args = ChatCompletionChunk
  { cccId      = "x"
  , cccChoices =
      [ Choice
          { choiceIndex        = 0
          , choiceDelta        = Delta
              { deltaContent   = Nothing
              , deltaToolCalls = Just
                  [ ToolCallDelta
                      { tcdIndex    = idx
                      , tcdId       = Just cid
                      , tcdFunction = Just FunctionDelta
                          { fdName      = Just tname
                          , fdArguments = Just args
                          }
                      }
                  ]
              }
          , choiceFinishReason = Nothing
          }
      ]
  , cccUsage   = Nothing
  }

mkToolArgChunk :: Int -> Text -> ChatCompletionChunk
mkToolArgChunk idx args = ChatCompletionChunk
  { cccId      = "x"
  , cccChoices =
      [ Choice
          { choiceIndex        = 0
          , choiceDelta        = Delta
              { deltaContent   = Nothing
              , deltaToolCalls = Just
                  [ ToolCallDelta
                      { tcdIndex    = idx
                      , tcdId       = Nothing
                      , tcdFunction = Just FunctionDelta
                          { fdName      = Nothing
                          , fdArguments = Just args
                          }
                      }
                  ]
              }
          , choiceFinishReason = Nothing
          }
      ]
  , cccUsage   = Nothing
  }

mkFinishChunk :: Text -> Maybe (Int, Int, Int) -> ChatCompletionChunk
mkFinishChunk reason usage = ChatCompletionChunk
  { cccId      = "x"
  , cccChoices =
      [ Choice
          { choiceIndex        = 0
          , choiceDelta        = Delta { deltaContent = Nothing, deltaToolCalls = Nothing }
          , choiceFinishReason = Just reason
          }
      ]
  , cccUsage   = fmap (\(p, c, t) -> ChatCompletionUsage p c t) usage
  }
```

Add imports at the top of the test file:

```haskell
import Data.Text (Text)
import OpenCode.Types (StreamEvent (..), Usage (..))
```

### Step 4.2: Run tests to confirm fail

```
export PATH="$HOME/.ghcup/bin:$PATH" && stack test --match "processChunk" 2>&1 | tail -15
```

Expected: 5 failures because `processChunk` isn't defined.

### Step 4.3: Implement the accumulator in `src/OpenCode/LLM/OpenAI.hs`

After the JSON decoder section, add:

```haskell
-- ---------------------------------------------------------------------------
-- Tool-call accumulator state
--
-- Tracks per-tool-call-index (within a single choice) whether ToolCallStart
-- has been emitted yet (so we know to emit ToolCallEnd at finish time) and
-- the call id we observed. OpenAI guarantees that the first chunk for a
-- given index supplies both id and function.name; subsequent chunks for the
-- same index only carry function.arguments fragments.
-- ---------------------------------------------------------------------------

type ToolCallAccum = Map Int Text   -- ^ index → callId

-- | Consume one chunk and emit zero or more 'StreamEvent's, updating the
-- accumulator state.
processChunk
  :: ToolCallAccum
  -> ChatCompletionChunk
  -> ([StreamEvent], ToolCallAccum)
processChunk st chunk =
  let allChoices = cccChoices chunk
      (textEvents, st1) = foldl' collectText  ([], st) allChoices
      (toolEvents, st2) = foldl' collectTools (textEvents, st1) allChoices
      (finalEvents, st3) = foldl' collectFinish (toolEvents, st2) allChoices
      usageEvents = case cccUsage chunk of
        Just u  | any (isJust . choiceFinishReason) allChoices ->
                    [StreamDone (toUsage u)]
        _       -> []
  in (finalEvents ++ usageEvents, st3)
  where
    collectText (acc, s) ch = case deltaContent (choiceDelta ch) of
      Just t | not (Text.null t) -> (acc ++ [TextDelta t], s)
      _                          -> (acc, s)

    collectTools (acc, s) ch = case deltaToolCalls (choiceDelta ch) of
      Nothing  -> (acc, s)
      Just tcs -> foldl' processTC (acc, s) tcs

    processTC (acc, s) tcd =
      let idx = tcdIndex tcd
      in case Map.lookup idx s of
        Nothing ->
          -- First sighting: must have id + function.name.
          case (tcdId tcd, tcdFunction tcd >>= fdName) of
            (Just cid, Just tname) ->
              let s'     = Map.insert idx cid s
                  start  = ToolCallStart cid tname
                  args   = tcdFunction tcd >>= fdArguments
                  argEvt = case args of
                    Just a | not (Text.null a) -> [ToolCallArgDelta cid a]
                    _                          -> []
              in (acc ++ [start] ++ argEvt, s')
            _ -> (acc, s)   -- malformed first chunk; ignore quietly
        Just cid ->
          -- Subsequent chunk: argument fragment.
          let args = tcdFunction tcd >>= fdArguments
              argEvt = case args of
                Just a | not (Text.null a) -> [ToolCallArgDelta cid a]
                _                          -> []
          in (acc ++ argEvt, s)

    collectFinish (acc, s) ch = case choiceFinishReason ch of
      Nothing -> (acc, s)
      Just _  ->
        -- Emit ToolCallEnd for every in-flight tool call.
        let ends = map ToolCallEnd (Map.elems s)
        in (acc ++ ends, Map.empty)

toUsage :: ChatCompletionUsage -> Usage
toUsage u = Usage
  { inputTokens  = ccUsagePromptTokens u
  , outputTokens = ccUsageCompletionTokens u
  , cacheRead    = Nothing
  , cacheWrite   = Nothing
  }
```

Add the new export and imports. Update the export list:

```haskell
  -- * Streaming pipeline (internal — exposed for tests)
  , ToolCallAccum
  , processChunk
```

Add imports:

```haskell
import Data.Foldable (foldl')
import Data.List qualified as List  -- if needed
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (isJust)
import Data.Text qualified as Text
import OpenCode.Types (StreamEvent (..), Usage (..))
```

(The `OpenCode.Types` import line should be updated to include `StreamEvent (..)` and `Usage (..)` — merge with the existing `ApiKey, StreamEvent` import.)

### Step 4.4: Run tests to confirm pass

```
export PATH="$HOME/.ghcup/bin:$PATH" && stack test --match "OpenCode.LLM.OpenAI" 2>&1 | tail -15
```

Expected: 9 specs pass (4 decodeChunk + 5 processChunk); full suite 76 / 0.

### Step 4.5: hlint clean

```
hlint src app test verify 2>&1 | tail -3
```

If hints appear, fix before committing. The `foldl'` style avoids many laziness-related hints; if hlint suggests `mapMaybe` or similar, accept the suggestion if it improves clarity, else add a `{-# LANGUAGE NumericUnderscores #-}` or similar local pragma if needed.

### Step 4.6: Commit

```
git add src/OpenCode/LLM/OpenAI.hs test/OpenCode/LLM/OpenAISpec.hs
git commit -m "M4: tool-call argument accumulator (processChunk state machine)"
```

---

## Task 5 — Pure SSE → StreamEvent pipeline + fixture replay

**Files:**
- Modify: `src/OpenCode/LLM/OpenAI.hs`
- Modify: `test/OpenCode/LLM/OpenAISpec.hs`
- Create: `test/fixtures/openai/text-stream.sse`
- Create: `test/fixtures/openai/tool-call-stream.sse`
- Create: `test/fixtures/openai/done-only.sse`

Compose the building blocks (chunkSSELines + sseDataLine + decodeChunk + processChunk) into a single conduit `interpretOpenAIStream :: ConduitT ByteString StreamEvent (ResourceT IO) ()`. Test by replaying real-shaped fixture bodies.

### Step 5.1: Write the fixtures

Create `test/fixtures/openai/text-stream.sse` — 5 events, text-only response. Use real-looking but synthetic ids. The trailing blank line after `[DONE]` is important — SSE record separator.

```
data: {"id":"chatcmpl-abc","object":"chat.completion.chunk","created":1234567890,"model":"gpt-4o","choices":[{"index":0,"delta":{"role":"assistant","content":""},"finish_reason":null}]}

data: {"id":"chatcmpl-abc","object":"chat.completion.chunk","created":1234567890,"model":"gpt-4o","choices":[{"index":0,"delta":{"content":"Hello"},"finish_reason":null}]}

data: {"id":"chatcmpl-abc","object":"chat.completion.chunk","created":1234567890,"model":"gpt-4o","choices":[{"index":0,"delta":{"content":" world"},"finish_reason":null}]}

data: {"id":"chatcmpl-abc","object":"chat.completion.chunk","created":1234567890,"model":"gpt-4o","choices":[{"index":0,"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":10,"completion_tokens":2,"total_tokens":12}}

data: [DONE]

```

Create `test/fixtures/openai/tool-call-stream.sse`:

```
data: {"id":"chatcmpl-xyz","choices":[{"index":0,"delta":{"role":"assistant","content":null,"tool_calls":[{"index":0,"id":"call_abc","type":"function","function":{"name":"bash","arguments":""}}]},"finish_reason":null}]}

data: {"id":"chatcmpl-xyz","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\""}}]},"finish_reason":null}]}

data: {"id":"chatcmpl-xyz","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"command\":\""}}]},"finish_reason":null}]}

data: {"id":"chatcmpl-xyz","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"echo hi\"}"}}]},"finish_reason":null}]}

data: {"id":"chatcmpl-xyz","choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":50,"completion_tokens":15,"total_tokens":65}}

data: [DONE]

```

Create `test/fixtures/openai/done-only.sse`:

```
data: [DONE]

```

### Step 5.2: Write the failing tests

Append to `test/OpenCode/LLM/OpenAISpec.hs`:

```haskell
  describe "interpretOpenAIStream" $ do

    it "reassembles a multi-chunk text response into TextDelta + StreamDone" $ do
      events <- runStream "test/fixtures/openai/text-stream.sse"
      events `shouldBe`
        [ TextDelta "Hello"
        , TextDelta " world"
        , StreamDone (Usage 10 2 Nothing Nothing)
        ]

    it "decodes a fragmented tool call into ordered start/delta/end events" $ do
      events <- runStream "test/fixtures/openai/tool-call-stream.sse"
      events `shouldBe`
        [ ToolCallStart "call_abc" "bash"
        , ToolCallArgDelta "call_abc" "{\""
        , ToolCallArgDelta "call_abc" "command\":\""
        , ToolCallArgDelta "call_abc" "echo hi\"}"
        , ToolCallEnd "call_abc"
        , StreamDone (Usage 50 15 Nothing Nothing)
        ]

    it "terminates cleanly on a done-only stream with no events" $ do
      events <- runStream "test/fixtures/openai/done-only.sse"
      events `shouldBe` []

-- ---------------------------------------------------------------------------
-- Fixture replay helper
-- ---------------------------------------------------------------------------

runStream :: FilePath -> IO [StreamEvent]
runStream path = do
  body <- BS.readFile path
  -- Feed the whole body as a single chunk; chunk-boundary resilience is
  -- tested separately in OpenCode.LLM.RequestSpec.
  Conduit.runResourceT $ Conduit.runConduit $
    Conduit.sourceList [body]
      .| interpretOpenAIStream
      .| Conduit.sinkList
```

Add imports:

```haskell
import Conduit qualified
import Conduit ((.|))
import Data.ByteString qualified as BS
```

### Step 5.3: Run tests to confirm fail

```
export PATH="$HOME/.ghcup/bin:$PATH" && stack test --match "interpretOpenAIStream" 2>&1 | tail -10
```

Expected: 3 failures because `interpretOpenAIStream` doesn't exist.

### Step 5.4: Implement `interpretOpenAIStream`

In `src/OpenCode/LLM/OpenAI.hs`, after the `processChunk` definition, add:

```haskell
-- ---------------------------------------------------------------------------
-- Pure SSE → StreamEvent pipeline (no HTTP)
-- ---------------------------------------------------------------------------

-- | Consume a raw SSE byte stream and emit 'StreamEvent's.
-- Pure with respect to networking; tested directly against fixture bodies.
interpretOpenAIStream
  :: MonadIO m
  => ConduitT ByteString StreamEvent m ()
interpretOpenAIStream =
  Request.chunkSSELines
    .| translateLines
  where
    translateLines = go Map.empty
    go st = do
      mline <- await
      case mline of
        Nothing   -> pure ()
        Just line -> case Request.sseDataLine line of
          Nothing         -> go st
          Just "[DONE]"   -> pure ()
          Just payload    -> case decodeChunk payload of
            Left _      -> go st   -- ignore malformed chunks; production would log
            Right chunk -> do
              let (events, st') = processChunk st chunk
              mapM_ yield events
              go st'
```

Update the export list:

```haskell
  -- * Streaming pipeline (internal — exposed for tests)
  , ToolCallAccum
  , processChunk
  , interpretOpenAIStream
```

Add imports:

```haskell
import Conduit (ConduitT, MonadIO, await, yield, (.|))
import OpenCode.LLM.Request qualified as Request
```

(Adjust the existing import for `Conduit` to include the new identifiers; remove any redundant aliases.)

### Step 5.5: Run tests to confirm pass

```
export PATH="$HOME/.ghcup/bin:$PATH" && stack test --match "OpenCode.LLM.OpenAI" 2>&1 | tail -15
```

Expected: 12 specs pass (4 decodeChunk + 5 processChunk + 3 interpretOpenAIStream); full suite 79 / 0.

### Step 5.6: hlint + commit

```
hlint src app test verify 2>&1 | tail -3
git add src/OpenCode/LLM/OpenAI.hs test/OpenCode/LLM/OpenAISpec.hs test/fixtures/openai/
git commit -m "M4: pure SSE → StreamEvent conduit + fixture replay tests"
```

---

## Task 6 — Schema module + request body builder

**Files:**
- Create: `src/OpenCode/LLM/Schema.hs`
- Create: `test/OpenCode/LLM/SchemaSpec.hs`
- Modify: `package.yaml`

`OpenCode.LLM.Schema` is a pure module producing JSON values that `streamOpenAI` will then encode into the request body. Keeps the HTTP-side code in Task 7 trivial.

### Step 6.1: Add the new module to `package.yaml`

In `package.yaml`, under `library:` `exposed-modules:`, add the new module name. After this edit:

```yaml
  exposed-modules:
    - OpenCode.App
    - OpenCode.Config
    - OpenCode.Types
    - OpenCode.DB
    - OpenCode.Session
    - OpenCode.MCP
    - OpenCode.LLM.Types
    - OpenCode.LLM.OpenAI
    - OpenCode.LLM.Anthropic
    - OpenCode.LLM.Request
    - OpenCode.LLM.Schema     # NEW
    - OpenCode.Tool.Types
    - ...
```

(Insert `OpenCode.LLM.Schema` alphabetically among the `OpenCode.LLM.*` entries.) The `OpenCode.LLM.Mock` module added in Task 8 also goes here — add it now too:

```yaml
    - OpenCode.LLM.Mock       # NEW (for Task 8)
```

### Step 6.2: Write the failing tests

Create `test/OpenCode/LLM/SchemaSpec.hs`:

```haskell
module OpenCode.LLM.SchemaSpec (spec) where

import Data.Aeson (Value (..), object, (.=))
import qualified Data.Aeson as Aeson
import qualified Data.Aeson.KeyMap as KM
import Data.List.NonEmpty qualified as NE
import Data.Text (Text)
import Data.Time (UTCTime (..), fromGregorian)
import Test.Hspec

import OpenCode.LLM.Schema
import OpenCode.LLM.Types
import OpenCode.Types

spec :: Spec
spec = do
  describe "toolToOpenAISchema" $ do

    it "wraps a ToolDefinition in OpenAI's tool envelope" $
      toolToOpenAISchema sampleToolDef
        `shouldBe` object
          [ "type"     .= ("function" :: Text)
          , "function" .= object
              [ "name"        .= ("bash" :: Text)
              , "description" .= ("Run a shell command" :: Text)
              , "parameters"  .= sampleToolSchema
              ]
          ]

  describe "messagesToOpenAI" $ do

    it "converts a user TextPart message" $ do
      let msgs = [Message (MessageId "m1") RoleUser
                    (NE.fromList [TextPart "hi"]) t0]
      messagesToOpenAI "" msgs `shouldBe`
        [ object ["role" .= ("user" :: Text), "content" .= ("hi" :: Text)] ]

    it "prepends a system message when system prompt is non-empty" $ do
      let msgs = [Message (MessageId "m1") RoleUser
                    (NE.fromList [TextPart "hi"]) t0]
      messagesToOpenAI "you are helpful" msgs `shouldBe`
        [ object ["role" .= ("system" :: Text), "content" .= ("you are helpful" :: Text)]
        , object ["role" .= ("user" :: Text), "content" .= ("hi" :: Text)]
        ]

    it "renders an assistant tool_call as a separate message" $ do
      let msgs =
            [ Message (MessageId "m1") RoleAssistant
                (NE.fromList [ToolCallPart (ToolCall "c1" "bash" (ToolArgs "{}"))]) t0
            , Message (MessageId "m2") RoleTool
                (NE.fromList [ToolResultPart (ToolResult "c1" "ok" False)]) t0
            ]
      let result = messagesToOpenAI "" msgs
      length result `shouldBe` 2
      -- assistant message has tool_calls array
      case result of
        (a : t : _) -> do
          asKM a `shouldSatisfy` KM.member "tool_calls"
          asKM t `shouldSatisfy` KM.member "tool_call_id"
        _ -> expectationFailure "expected two converted messages"

  describe "buildOpenAIRequestBody" $ do

    it "produces a top-level object with model, messages, stream:true" $ do
      let body = buildOpenAIRequestBody sampleRequest
      asKM body `shouldSatisfy` KM.member "model"
      asKM body `shouldSatisfy` KM.member "messages"
      asKM body `shouldSatisfy` KM.member "stream"
      KM.lookup "stream" (asKM body) `shouldBe` Just (Bool True)
      KM.lookup "model" (asKM body) `shouldBe` Just (String "gpt-4o")

    it "omits max_tokens when reqMaxTokens is Nothing" $ do
      let body = buildOpenAIRequestBody sampleRequest { reqMaxTokens = Nothing }
      asKM body `shouldNotSatisfy` KM.member "max_tokens"

    it "includes max_tokens when reqMaxTokens is Just" $ do
      let body = buildOpenAIRequestBody sampleRequest { reqMaxTokens = Just 1024 }
      KM.lookup "max_tokens" (asKM body) `shouldBe` Just (Aeson.Number 1024)

-- ---------------------------------------------------------------------------
-- Fixtures
-- ---------------------------------------------------------------------------

asKM :: Value -> KM.KeyMap Value
asKM (Object o) = o
asKM v          = error ("expected Object, got " <> show v)

t0 :: UTCTime
t0 = UTCTime (fromGregorian 2026 5 24) 0

sampleToolSchema :: Value
sampleToolSchema = object
  [ "type"       .= ("object" :: Text)
  , "properties" .= object
      [ "command" .= object ["type" .= ("string" :: Text)] ]
  , "required"   .= (["command"] :: [Text])
  ]

sampleToolDef :: ToolDefinition
sampleToolDef = ToolDefinition
  { tdName        = "bash"
  , tdDescription = "Run a shell command"
  , tdSchema      = sampleToolSchema
  }

sampleRequest :: LLMRequest
sampleRequest = LLMRequest
  { reqModel        = "gpt-4o"
  , reqMessages     = [Message (MessageId "m1") RoleUser
                        (NE.fromList [TextPart "hi"]) t0]
  , reqTools        = []
  , reqSystemPrompt = ""
  , reqMaxTokens    = Just 4096
  }
```

### Step 6.3: Run tests to confirm fail

```
export PATH="$HOME/.ghcup/bin:$PATH" && stack test --match "OpenCode.LLM.Schema" 2>&1 | tail -15
```

Expected: doesn't compile (module doesn't exist).

### Step 6.4: Create `src/OpenCode/LLM/Schema.hs`

```haskell
-- | OpenAI-specific JSON shape conversions.
-- Pure: produces 'Aeson.Value's that the HTTP layer encodes.
module OpenCode.LLM.Schema
  ( toolToOpenAISchema
  , messagesToOpenAI
  , buildOpenAIRequestBody
  ) where

import Data.Aeson (Value (..), object, (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KM
import Data.List.NonEmpty qualified as NE
import Data.Text (Text)
import Data.Text qualified as T

import OpenCode.LLM.Types (LLMRequest (..), ToolDefinition (..))
import OpenCode.Types
  ( Message (..)
  , MessagePart (..)
  , Role (..)
  , ToolArgs (..)
  , ToolCall (..)
  , ToolResult (..)
  )

-- | Wrap a 'ToolDefinition' in OpenAI's tool envelope.
toolToOpenAISchema :: ToolDefinition -> Value
toolToOpenAISchema td = object
  [ "type"     .= ("function" :: Text)
  , "function" .= object
      [ "name"        .= tdName td
      , "description" .= tdDescription td
      , "parameters"  .= tdSchema td
      ]
  ]

-- | Convert internal messages to OpenAI's chat format.
-- A non-empty system prompt is prepended as a 'system'-role message.
messagesToOpenAI :: Text -> [Message] -> [Value]
messagesToOpenAI systemPrompt msgs =
  let sysMsg = if T.null systemPrompt
                 then []
                 else [object ["role" .= ("system" :: Text), "content" .= systemPrompt]]
      others = concatMap messageToOpenAI msgs
  in sysMsg ++ others

-- | Render one internal 'Message' as zero, one, or two OpenAI messages.
-- Most parts collapse to one message; a 'ToolResultPart' becomes its own
-- role:"tool" message.
messageToOpenAI :: Message -> [Value]
messageToOpenAI m =
  let parts = NE.toList (msgParts m)
      (textBits, toolCalls, toolResults, errs) = foldr classify ([], [], [], []) parts
      textContent = T.concat textBits
      base = case msgRole m of
        RoleUser      -> [object ["role" .= ("user" :: Text), "content" .= textContent]]
        RoleAssistant ->
          if null toolCalls
            then [object ["role" .= ("assistant" :: Text), "content" .= textContent]]
            else
              [ object
                  [ "role"       .= ("assistant" :: Text)
                  , "content"    .= Aeson.Null
                  , "tool_calls" .= map toolCallToOpenAI toolCalls
                  ]
              ]
        RoleTool ->
          map toolResultToOpenAI toolResults
      -- Errors are appended as separate system-role messages (rare, but kept).
      errMsgs = map (\e -> object ["role" .= ("system" :: Text), "content" .= e]) errs
  in base ++ errMsgs
  where
    classify p (ts, tcs, trs, es) = case p of
      TextPart t        -> (t : ts, tcs, trs, es)
      ToolCallPart tc   -> (ts, tc : tcs, trs, es)
      ToolResultPart tr -> (ts, tcs, tr : trs, es)
      ErrorPart e       -> (ts, tcs, trs, e : es)

toolCallToOpenAI :: ToolCall -> Value
toolCallToOpenAI tc = object
  [ "id"       .= callId tc
  , "type"     .= ("function" :: Text)
  , "function" .= object
      [ "name"      .= toolName tc
      , "arguments" .= unToolArgs (arguments tc)
      ]
  ]

toolResultToOpenAI :: ToolResult -> Value
toolResultToOpenAI tr = object
  [ "role"         .= ("tool" :: Text)
  , "tool_call_id" .= resultCallId tr
  , "content"      .= content tr
  ]

-- | Build the OpenAI chat-completion request body.
buildOpenAIRequestBody :: LLMRequest -> Value
buildOpenAIRequestBody req =
  let base = KM.fromList
        [ ("model",    Aeson.toJSON (reqModel req))
        , ("messages", Aeson.toJSON (messagesToOpenAI (reqSystemPrompt req) (reqMessages req)))
        , ("stream",   Bool True)
        ]
      withTools = case reqTools req of
        [] -> base
        ts -> KM.insert "tools" (Aeson.toJSON (map toolToOpenAISchema ts)) base
      withMax = case reqMaxTokens req of
        Nothing -> withTools
        Just n  -> KM.insert "max_tokens" (Aeson.toJSON n) withTools
  in Object withMax
```

### Step 6.5: Build + test

```
export PATH="$HOME/.ghcup/bin:$PATH" && stack build 2>&1 | tail -10 && stack test --match "OpenCode.LLM.Schema" 2>&1 | tail -15
```

Expected: clean build; all `OpenCode.LLM.Schema` specs pass; full suite at 86 / 0 (79 prior + 7 new).

### Step 6.6: hlint + commit

```
hlint src app test verify 2>&1 | tail -3
git add src/OpenCode/LLM/Schema.hs test/OpenCode/LLM/SchemaSpec.hs package.yaml opencode-hs.cabal
git commit -m "M4: OpenCode.LLM.Schema (tool envelope + message conversion + request body)"
```

(`opencode-hs.cabal` regenerates from `package.yaml` on `stack build`; include it so the commit stays in sync.)

---

## Task 7 — `streamOpenAI` HTTP integration

**Files:**
- Modify: `src/OpenCode/LLM/OpenAI.hs`
- Modify: `test/OpenCode/LLM/OpenAISpec.hs`

Wire `http-conduit`'s `httpSource` to the pure pipeline. On success (2xx), pipe the response body through `interpretOpenAIStream`. On non-2xx, drain the body, emit a single `StreamError`, end stream. Replace the stub `instance LLMProvider OpenAIProvider`.

Testing the HTTP layer end-to-end requires a mock server. To keep this task self-contained, we test the HTTP-error path by injecting a helper that takes an `(Int, ByteString)` (status code + body bytes) and produces the right `StreamError`. The happy-path is exercised by Task 5's fixture replay tests, which cover the full SSE pipeline already.

### Step 7.1: Add test for the error-mapping helper

Append to `test/OpenCode/LLM/OpenAISpec.hs`:

```haskell
  describe "streamErrorFromHttp" $ do

    it "produces a StreamError with status + truncated body" $
      streamErrorFromHttp 401 "Unauthorized: bad token"
        `shouldBe` StreamError "openai: 401: Unauthorized: bad token"

    it "truncates long bodies to 200 bytes" $
      let longBody = BS.replicate 500 65 -- "AAAA..." (500 chars, ASCII 'A')
          ev = streamErrorFromHttp 500 longBody
      in case ev of
        StreamError msg -> Text.length msg `shouldSatisfy` (< 250)
        _               -> expectationFailure "expected StreamError"
```

Add the imports if not already present:

```haskell
import qualified Data.Text as Text
```

### Step 7.2: Implement `streamOpenAI` and `streamErrorFromHttp` in `src/OpenCode/LLM/OpenAI.hs`

After the `interpretOpenAIStream` definition, add:

```haskell
-- ---------------------------------------------------------------------------
-- HTTP integration
-- ---------------------------------------------------------------------------

-- | Build an HTTP error 'StreamEvent' from a status code + body bytes.
streamErrorFromHttp :: Int -> ByteString -> StreamEvent
streamErrorFromHttp status body =
  let snippet = BS.take 200 body
  in StreamError $
      "openai: " <> Text.pack (show status) <> ": " <> Text.decodeUtf8 snippet

-- | Stream completions from OpenAI via SSE.
streamOpenAI
  :: OpenAIProvider
  -> LLMRequest
  -> ConduitT () StreamEvent (ResourceT IO) ()
streamOpenAI provider req = do
  initReq <- liftIO $ HTTP.parseRequest (Text.unpack (baseUrl provider) <> "/v1/chat/completions")
  let bodyBytes = Aeson.encode (Schema.buildOpenAIRequestBody req)
      authHeader = ("Authorization", "Bearer " <> Text.encodeUtf8 (unApiKey (apiKey provider)))
      httpReq = initReq
        { HTTP.method = "POST"
        , HTTP.requestHeaders =
            [ authHeader
            , ("Content-Type", "application/json")
            , ("Accept", "text/event-stream")
            ]
        , HTTP.requestBody = HTTP.RequestBodyLBS bodyBytes
        , HTTP.responseTimeout = HTTP.responseTimeoutNone   -- streams may run minutes
        }
  HTTP.httpSource httpReq dispatch
  where
    dispatch response =
      let status = HTTP.responseStatus response
          code   = HTTP.statusCode status
      in if code >= 200 && code < 300
           then HTTP.responseBody response .| interpretOpenAIStream
           else do
             body <- HTTP.responseBody response .| Conduit.foldC
             yield (streamErrorFromHttp code body)

instance LLMProvider OpenAIProvider where
  streamCompletion = streamOpenAI
```

Add the necessary imports:

```haskell
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Trans.Resource (ResourceT)
import qualified Conduit
import qualified Data.Aeson as Aeson
import qualified Data.ByteString as BS
import qualified Data.Text.Encoding as Text
import qualified Network.HTTP.Simple as HTTP
import qualified OpenCode.LLM.Schema as Schema
import OpenCode.Types (unApiKey)
```

(Note: `Network.HTTP.Simple` is the high-level wrapper around `http-conduit` and provides `parseRequest`, `httpSource`, `responseStatus`, `responseBody`, `responseTimeoutNone`, and the `RequestBody*` constructors.)

Delete the existing stub instance and the `_unused` placeholder (both now obsolete — the real instance and the real use of `LLMRequest`/`StreamEvent` exist now). Specifically, remove:

```haskell
instance LLMProvider OpenAIProvider where
  streamCompletion _ _ = error "OpenCode.LLM.OpenAI: not yet implemented (M4)"

-- Silence unused-import warnings for types needed in M4
_unused :: (LLMRequest, StreamEvent) -> ()
_unused _ = ()
```

The new real `instance LLMProvider OpenAIProvider` is at the bottom of the file (next to `streamOpenAI`).

Update the export list to add `streamOpenAI` and `streamErrorFromHttp`:

```haskell
  -- * Streaming
  , streamOpenAI
  , streamErrorFromHttp
```

### Step 7.3: Build + test

```
export PATH="$HOME/.ghcup/bin:$PATH" && stack build 2>&1 | tail -10 && stack test --match "OpenCode.LLM.OpenAI" 2>&1 | tail -15
```

Expected: clean build; the existing `OpenCode.LLM.OpenAI` specs plus the 2 new `streamErrorFromHttp` specs pass; full suite 88 / 0.

### Step 7.4: Smoke-test the request shape (no network)

This step verifies the constructed HTTP request body is well-formed JSON. It does NOT call the real OpenAI API. Add to `test/OpenCode/LLM/OpenAISpec.hs`:

```haskell
  describe "request body smoke test" $
    it "produces parseable JSON with model + messages + stream" $ do
      let req = LLMRequest
            { reqModel        = "gpt-4o"
            , reqMessages     = []
            , reqTools        = []
            , reqSystemPrompt = ""
            , reqMaxTokens    = Just 100
            }
          body = Aeson.encode (Schema.buildOpenAIRequestBody req)
      case Aeson.eitherDecode body :: Either String Aeson.Value of
        Left e  -> expectationFailure ("body not parseable: " <> e)
        Right _ -> pure ()
```

Add `import qualified Data.Aeson as Aeson` and `import qualified OpenCode.LLM.Schema as Schema` and `import OpenCode.LLM.Types` if not already in scope.

```
export PATH="$HOME/.ghcup/bin:$PATH" && stack test --match "request body smoke test" 2>&1 | tail -5
```

### Step 7.5: hlint + commit

```
hlint src app test verify 2>&1 | tail -3
git add src/OpenCode/LLM/OpenAI.hs test/OpenCode/LLM/OpenAISpec.hs
git commit -m "M4: streamOpenAI HTTP integration + error mapping"
```

---

## Task 8 — Mock LLM helper

**Files:**
- Create: `src/OpenCode/LLM/Mock.hs`
- Create: `test/OpenCode/LLM/MockSpec.hs`
- Delete: `test/OpenCode/LLMSpec.hs` (the placeholder from M0)

The mock is what M6's session loop will use in tests. Trivial implementation: a conduit that yields each scripted event in order.

### Step 8.1: Remove the obsolete placeholder spec

```
git rm /Users/dodofk/Misc/opencode-hs/test/OpenCode/LLMSpec.hs
```

### Step 8.2: Write the failing test

Create `test/OpenCode/LLM/MockSpec.hs`:

```haskell
module OpenCode.LLM.MockSpec (spec) where

import qualified Conduit
import Conduit ((.|))
import Test.Hspec

import OpenCode.LLM.Mock
import OpenCode.Types (StreamEvent (..), Usage (..))

spec :: Spec
spec = describe "mockStreamCompletion" $ do

  it "yields scripted events in order" $ do
    let scripted =
          [ TextDelta "Hello"
          , TextDelta " world"
          , StreamDone (Usage 5 2 Nothing Nothing)
          ]
    events <- Conduit.runResourceT $ Conduit.runConduit $
      mockStreamCompletion scripted .| Conduit.sinkList
    events `shouldBe` scripted

  it "yields no events for an empty script" $ do
    events <- Conduit.runResourceT $ Conduit.runConduit $
      mockStreamCompletion [] .| Conduit.sinkList
    events `shouldBe` []
```

### Step 8.3: Run tests to confirm fail

```
export PATH="$HOME/.ghcup/bin:$PATH" && stack test --match "mockStreamCompletion" 2>&1 | tail -10
```

Expected: doesn't compile (module missing).

### Step 8.4: Create `src/OpenCode/LLM/Mock.hs`

```haskell
-- | A mock LLM provider for tests. Emits a scripted sequence of 'StreamEvent's.
module OpenCode.LLM.Mock
  ( mockStreamCompletion
  ) where

import Conduit (ConduitT, yieldMany)
import Control.Monad.Trans.Resource (ResourceT)
import OpenCode.Types (StreamEvent)

-- | A streaming completion that emits a fixed list of events.
mockStreamCompletion
  :: [StreamEvent]
  -> ConduitT () StreamEvent (ResourceT IO) ()
mockStreamCompletion = yieldMany
```

### Step 8.5: Build + test

```
export PATH="$HOME/.ghcup/bin:$PATH" && stack build 2>&1 | tail -5 && stack test --match "OpenCode.LLM.Mock" 2>&1 | tail -10
```

Expected: clean build, 2 new specs pass; full suite 90 / 0 (88 + 2 mock, since the deleted placeholder removed 1).

### Step 8.6: hlint + commit

```
hlint src app test verify 2>&1 | tail -3
git add src/OpenCode/LLM/Mock.hs test/OpenCode/LLM/MockSpec.hs test/OpenCode/LLMSpec.hs
git commit -m "M4: OpenCode.LLM.Mock helper + drop M0 LLMSpec placeholder"
```

(`git add` of the deleted file stages the deletion since `git rm` already updated the index in Step 8.1; including it here is redundant but harmless. If `git rm` was used in Step 8.1, only `src/OpenCode/LLM/Mock.hs` and `test/OpenCode/LLM/MockSpec.hs` need explicit `git add` here.)

---

## Task 9 — Acceptance + mark M4 done

**Files:**
- Modify: `MILESTONES.md`

### Step 9.1: Run the full LLM spec suite

```
export PATH="$HOME/.ghcup/bin:$PATH" && stack test --match "OpenCode.LLM" 2>&1 | tail -10
```

Expected: all `OpenCode.LLM.*` specs pass — 11 Request + 12 OpenAI (4 decodeChunk + 5 processChunk + 3 interpretOpenAIStream) + 2 streamErrorFromHttp + 1 smoke + 7 Schema + 2 Mock = ~38 specs. The full suite count is 90+ examples, 0 failures.

### Step 9.2: Confirm `hlint` is still clean

```
hlint src app test verify 2>&1 | tail -3
```

Expected: `No hints`.

### Step 9.3: Confirm CI is green on the latest commit before updating MILESTONES.md

Push the M4 work-in-progress (if not already pushed during prior tasks):

```
git push origin main
```

Then watch CI:

```
gh -R dodofk/opencode-hs run watch
```

Expected: `build-and-test` (ubuntu+macos) and `lint` all ✅.

### Step 9.4: Update `MILESTONES.md` M4 row

In `MILESTONES.md`, find the M4 row in the Status snapshot table:

```
| M4  | LLM Streaming — OpenAI only            | pending   | —                  |
```

First get the M4-starting commit SHA (Task 1's commit):

```
git -C /Users/dodofk/Misc/opencode-hs log --oneline | grep "M4:" | tail -1
```

Substitute the short SHA into the table (the placeholder `<sha>` below):

```
| M4  | LLM Streaming — OpenAI only            | done      | `<sha>..`          |
```

### Step 9.5: Commit + push the status update

```
git -C /Users/dodofk/Misc/opencode-hs add MILESTONES.md
git -C /Users/dodofk/Misc/opencode-hs commit -m "M4: mark milestone done in status snapshot"
git -C /Users/dodofk/Misc/opencode-hs push origin main
```

### Step 9.6: Final verification

```
gh -R dodofk/opencode-hs run list --limit 3
```

Expected: the most recent runs on `main` (the M4 push series + the MILESTONES update push) all `completed / success`.

---

## Out of scope for M4 (do NOT add)

- **`LLMConfig` type** — mentioned in MILESTONES.md § M4 task list but redundant given the concrete `OpenAIProvider`/`AnthropicProvider` records and the `LLMProvider` typeclass. Skipped without loss of capability.
- **`[DONE]` → `StreamDone` direct mapping** — the spec phrasing suggests `[DONE]` itself emits `StreamDone`. In practice OpenAI sends `finish_reason` + `usage` in the chunk BEFORE `[DONE]`, and `[DONE]` is just an "end of stream" marker with no data. Our pipeline emits `StreamDone(usage)` on the `finish_reason` chunk and terminates the conduit on `[DONE]` — semantically equivalent and the correct OpenAI handling.
- **Anthropic provider** — M11. The stub stays.
- **Real HTTP integration tests against `api.openai.com`** — requires an API key in CI, costs money per request, flaky. Stick to fixture-replay unit tests.
- **Retry logic on 429/5xx** — useful but deferred to M12 hardening.
- **Streaming abort via the `envAbort` TVar** — wired up in M6 (Session loop), not here.
- **Token counting / cost estimation** — out of v1 scope.
- **`OpenCode.LLM.Mock` shrinkable QuickCheck generators** — overkill for M4; M6's session-loop tests use hand-crafted scripts.
- **`OpenCode.Session` integration** — that's the whole point of M6, not this milestone.
- **Anything from M5+ (Tools, Session, TUI, CLI).**

## Notes for the next milestone (M5 — Tool System: file I/O)

- `OpenCode.LLM.Mock` is ready for M6 to consume; M5 doesn't need it.
- The `LLMRequest` shape is now stable; M5 doesn't touch LLM at all.
- New modules `OpenCode.LLM.Schema` and `OpenCode.LLM.Mock` are listed in `package.yaml`'s `exposed-modules` and will be referenced from M6.
- The `ResourceT IO` effect type in the typeclass means M6's session loop must call `runResourceT` (or `runConduitRes`) when consuming the conduit.
