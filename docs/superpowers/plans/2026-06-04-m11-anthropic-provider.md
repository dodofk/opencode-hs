# M11 — Anthropic Provider — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add Anthropic as a fully-supported streaming provider (`anthropic:<model>`), reusing the M4 SSE infrastructure, so it works end-to-end like OpenAI/MiniMax.

**Architecture:** Mirror the OpenAI/Schema split. `OpenCode.LLM.Schema` gains the Anthropic request-body shapes (`buildAnthropicRequestBody`/`messagesToAnthropic`/`toolToAnthropicSchema`); `OpenCode.LLM.Anthropic` gains the streaming half (an `AnthropicEvent` ADT decoded by dispatching on the SSE payload `type`, a `processAnthropicEvent` accumulator, `interpretAnthropicStream` reusing `chunkSSELines`/`sseDataLine`, and `streamAnthropic` over `POST /v1/messages`). Provider dispatch is then wired through `streamerForProvider` and `config check`.

**Tech Stack:** Haskell (GHC 9.6.6, lts-22.39), `http-conduit`, `aeson`, `conduit`/`resourcet`, `hspec`. No new dependencies.

**Reference spec:** `docs/superpowers/specs/2026-06-04-m11-anthropic-provider-design.md`

---

## File Structure

**Modified (library):**
- `src/OpenCode/LLM/Schema.hs` — add `toolToAnthropicSchema`, `messagesToAnthropic`, `buildAnthropicRequestBody`, `defaultAnthropicMaxTokens` (beside the OpenAI builders).
- `src/OpenCode/LLM/Anthropic.hs` — replace the stub with the real provider: event ADT + `FromJSON`, `processAnthropicEvent`, `interpretAnthropicStream`, `streamAnthropic`, `anthropicErrorFromHttp`, `LLMProvider` instance.
- `src/OpenCode/Config.hs` — add/export `defaultAnthropicModel`; redefine `fallbackModel` in terms of it.
- `src/OpenCode/Session.hs` — generalize `withKey`; the `Anthropic` arm returns a real streamer.
- `src/OpenCode/Run.hs` — `checkProvider` probes Anthropic for real; `probeModel` returns `defaultAnthropicModel`.

**Created (tests + fixtures):**
- `test/OpenCode/LLM/AnthropicSpec.hs`
- `test/fixtures/anthropic/text-stream.sse`
- `test/fixtures/anthropic/tool-call-stream.sse`
- `test/fixtures/anthropic/error.sse`

**Modified (tests + config):**
- `test/OpenCode/LLM/SchemaSpec.hs` — Anthropic request-shape tests.
- `test/OpenCode/SessionSpec.hs` — `streamerForProvider` Anthropic cases.
- `package.yaml` — add `OpenCode.LLM.AnthropicSpec` to test `other-modules`.

`OpenCode.LLM.Anthropic` is already in `exposed-modules`; no dependency changes.

**Build/test commands used throughout:**
- Full build: `stack build`  (binary: `~/.ghcup/bin/stack`)
- Full suite: `stack test`
- One group: `stack test --ta '--match "<pattern>"'`

---

## Task 1: Anthropic request shapes in `OpenCode.LLM.Schema`

**Files:**
- Modify: `src/OpenCode/LLM/Schema.hs`
- Test: `test/OpenCode/LLM/SchemaSpec.hs`

- [ ] **Step 1: Write the failing tests in `test/OpenCode/LLM/SchemaSpec.hs`**

Add a new `describe` group (the file already imports `OpenCode.LLM.Schema`, `OpenCode.LLM.Types`, `OpenCode.Types`, `Data.Aeson (Value (..), object, (.=))`, `Data.Aeson.KeyMap as KM`, `Data.List.NonEmpty as NE`, `Data.Text (Text)` — all needed names are in scope):

```haskell
  describe "toolToAnthropicSchema" $
    it "wraps a ToolDefinition as { name, description, input_schema }" $
      toolToAnthropicSchema sampleToolDef
        `shouldBe` object
          [ "name"         .= ("bash" :: Text)
          , "description"  .= ("Run a shell command" :: Text)
          , "input_schema" .= sampleToolSchema
          ]

  describe "buildAnthropicRequestBody" $ do

    it "sets stream:true and defaults max_tokens to 4096 when Nothing" $ do
      let body = buildAnthropicRequestBody sampleRequest { reqMaxTokens = Nothing }
      KM.lookup "stream" (asKM body) `shouldBe` Just (Bool True)
      KM.lookup "max_tokens" (asKM body) `shouldBe` Just (Aeson.Number 4096)

    it "honors an explicit max_tokens" $ do
      let body = buildAnthropicRequestBody sampleRequest { reqMaxTokens = Just 256 }
      KM.lookup "max_tokens" (asKM body) `shouldBe` Just (Aeson.Number 256)

    it "hoists a non-empty system prompt with ephemeral cache_control" $ do
      let body = buildAnthropicRequestBody sampleRequest { reqSystemPrompt = "be terse" }
      case KM.lookup "system" (asKM body) of
        Just (Array _) -> pure ()
        other -> expectationFailure ("expected system array, got " <> show other)
      Aeson.encode body `shouldSatisfy` lbsInfix "ephemeral"
      Aeson.encode body `shouldSatisfy` lbsInfix "be terse"

    it "omits system when the prompt is empty" $ do
      let body = buildAnthropicRequestBody sampleRequest { reqSystemPrompt = "" }
      KM.lookup "system" (asKM body) `shouldBe` Nothing

  describe "messagesToAnthropic" $ do

    it "converts a user text message into a content block" $ do
      let msgs = [Message (MessageId "m1") RoleUser (NE.fromList [TextPart "hi"]) t0]
      Aeson.encode (Aeson.toJSON (messagesToAnthropic msgs)) `shouldSatisfy` lbsInfix "\"role\":\"user\""

    it "emits a bundled tool call+result as assistant tool_use then user tool_result" $ do
      let msgs =
            [ Message (MessageId "m1") RoleAssistant
                (NE.fromList
                  [ ToolCallPart   (ToolCall "c1" "bash" (ToolArgs "{\"command\":\"ls\"}"))
                  , ToolResultPart (ToolResult "c1" "ok" False)
                  ]) t0
            ]
          result = messagesToAnthropic msgs
      length result `shouldBe` 2
      case result of
        (a : u : _) -> do
          KM.lookup "role" (asKM a) `shouldBe` Just (String "assistant")
          KM.lookup "role" (asKM u) `shouldBe` Just (String "user")
          -- the tool_use carries the call id and an object (not string) input
          Aeson.encode a `shouldSatisfy` lbsInfix "\"type\":\"tool_use\""
          Aeson.encode a `shouldSatisfy` lbsInfix "\"input\":{\"command\":\"ls\"}"
          -- the tool_result references the same id
          Aeson.encode u `shouldSatisfy` lbsInfix "\"tool_use_id\":\"c1\""
          Aeson.encode u `shouldSatisfy` lbsInfix "\"type\":\"tool_result\""
        _ -> expectationFailure "expected assistant + user messages"
```

Add the import `import qualified Data.ByteString.Lazy as LBS` to the file, and add this single helper at the bottom (the `asKM`, `sampleToolSchema`, `sampleToolDef`, `sampleRequest`, `t0` fixtures already exist from the OpenAI tests — reuse them):

```haskell
lbsInfix :: LBS.ByteString -> LBS.ByteString -> Bool
lbsInfix needle hay = needle `LBS.isInfixOf` hay
```

This is what the assertions above use: `Aeson.encode body \`shouldSatisfy\` lbsInfix "ephemeral"` type-checks because `Aeson.encode :: ToJSON a => a -> LBS.ByteString` and the `"ephemeral"` literal is an `LBS.ByteString` via `OverloadedStrings`.

- [ ] **Step 2: Run the tests — verify they FAIL**

Run:
```bash
stack test --ta '--match "buildAnthropicRequestBody"'
```
Expected: RED — `Variable not in scope: buildAnthropicRequestBody` (and `toolToAnthropicSchema`, `messagesToAnthropic`).

- [ ] **Step 3: Implement the Anthropic shapes in `src/OpenCode/LLM/Schema.hs`**

Add to the export list:

```haskell
  , toolToAnthropicSchema
  , messagesToAnthropic
  , buildAnthropicRequestBody
```

Add imports (merge with existing — the file already imports `Data.Aeson qualified as Aeson`, `Data.Text qualified as T`, and the `OpenCode.Types` constructors):

```haskell
import Data.Maybe (fromMaybe)
import Data.Text.Encoding qualified as TextEnc
```

Add the definitions:

```haskell
-- | Anthropic requires max_tokens on every request.
defaultAnthropicMaxTokens :: Int
defaultAnthropicMaxTokens = 4096

-- | Wrap a 'ToolDefinition' in Anthropic's tool envelope.
toolToAnthropicSchema :: ToolDefinition -> Value
toolToAnthropicSchema td = object
  [ "name"         .= tdName td
  , "description"  .= tdDescription td
  , "input_schema" .= tdSchema td
  ]

-- | Build the Anthropic /v1/messages request body. The system prompt is hoisted
-- to a top-level 'system' array carrying ephemeral cache_control; max_tokens is
-- always present (defaulted); tools are included only when non-empty.
buildAnthropicRequestBody :: LLMRequest -> Value
buildAnthropicRequestBody req =
  let base =
        [ "model"      .= reqModel req
        , "max_tokens" .= fromMaybe defaultAnthropicMaxTokens (reqMaxTokens req)
        , "stream"     .= True
        , "messages"   .= messagesToAnthropic (reqMessages req)
        ]
      sys
        | T.null (reqSystemPrompt req) = []
        | otherwise =
            [ "system" .=
                [ object
                    [ "type"          .= ("text" :: Text)
                    , "text"          .= reqSystemPrompt req
                    , "cache_control" .= object ["type" .= ("ephemeral" :: Text)]
                    ]
                ]
            ]
      tools = case reqTools req of
        [] -> []
        ts -> [ "tools" .= map toolToAnthropicSchema ts ]
  in object (base <> sys <> tools)

-- | Convert internal messages to Anthropic's messages array. An assistant
-- message that bundles tool calls and their results becomes an assistant message
-- (text + tool_use blocks) followed by a user message (tool_result blocks) —
-- Anthropic carries tool results in a user turn.
messagesToAnthropic :: [Message] -> [Value]
messagesToAnthropic = concatMap messageToAnthropic

messageToAnthropic :: Message -> [Value]
messageToAnthropic m =
  let parts = NE.toList (msgParts m)
      (textBits, toolCalls, toolResults, _errs) = foldr classifyA ([], [], [], []) parts
      textContent = T.concat textBits
  in case msgRole m of
    RoleUser ->
      [ object ["role" .= ("user" :: Text), "content" .= [anthropicTextBlock textContent]] ]
    RoleAssistant ->
      let textBlocks   = [anthropicTextBlock textContent | not (T.null textContent)]
          toolBlocks   = map toolUseBlock toolCalls
          assistant    = [ object ["role" .= ("assistant" :: Text), "content" .= (textBlocks <> toolBlocks)]
                         | not (null (textBlocks <> toolBlocks)) ]
          resultsMsg   = [ object ["role" .= ("user" :: Text), "content" .= map toolResultBlock toolResults]
                         | not (null toolResults) ]
      in assistant <> resultsMsg
    RoleTool ->
      [ object ["role" .= ("user" :: Text), "content" .= map toolResultBlock toolResults]
      | not (null toolResults) ]
  where
    classifyA p (ts, tcs, trs, es) = case p of
      TextPart t        -> (t : ts, tcs, trs, es)
      ToolCallPart tc   -> (ts, tc : tcs, trs, es)
      ToolResultPart tr -> (ts, tcs, tr : trs, es)
      ErrorPart e       -> (ts, tcs, trs, e : es)

anthropicTextBlock :: Text -> Value
anthropicTextBlock t = object ["type" .= ("text" :: Text), "text" .= t]

toolUseBlock :: ToolCall -> Value
toolUseBlock tc = object
  [ "type"  .= ("tool_use" :: Text)
  , "id"    .= callId tc
  , "name"  .= toolName tc
  , "input" .= decodeArgs (arguments tc)
  ]

toolResultBlock :: ToolResult -> Value
toolResultBlock tr = object
  [ "type"        .= ("tool_result" :: Text)
  , "tool_use_id" .= resultCallId tr
  , "content"     .= content tr
  ]

-- | Decode raw JSON-text tool arguments into a Value object for tool_use.input;
-- a non-decodable blob falls back to an empty object.
decodeArgs :: ToolArgs -> Value
decodeArgs a = fromMaybe (object []) (Aeson.decodeStrict (TextEnc.encodeUtf8 (unToolArgs a)))
```

- [ ] **Step 4: Run the tests — verify they PASS**

Run:
```bash
stack test --ta '--match "Anthropic"'
```
Expected: GREEN — the `toolToAnthropicSchema`, `buildAnthropicRequestBody`, and `messagesToAnthropic` groups all pass. Run `stack test` once to confirm the full suite is green.

- [ ] **Step 5: Commit**

```bash
git add src/OpenCode/LLM/Schema.hs test/OpenCode/LLM/SchemaSpec.hs
git commit -m "$(cat <<'EOF'
M11: Anthropic request shapes in LLM.Schema

buildAnthropicRequestBody (required max_tokens default 4096, hoisted system
with ephemeral cache_control, stream:true), messagesToAnthropic (tool results
in a user turn, ToolArgs decoded to a JSON object), toolToAnthropicSchema.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: `OpenCode.LLM.Anthropic` streaming module + fixtures

**Files:**
- Modify: `src/OpenCode/LLM/Anthropic.hs` (replace the stub)
- Create: `test/fixtures/anthropic/text-stream.sse`
- Create: `test/fixtures/anthropic/tool-call-stream.sse`
- Create: `test/fixtures/anthropic/error.sse`
- Create: `test/OpenCode/LLM/AnthropicSpec.hs`
- Modify: `package.yaml`

- [ ] **Step 1: Create the three SSE fixtures**

`test/fixtures/anthropic/text-stream.sse`:
```
event: message_start
data: {"type":"message_start","message":{"id":"msg_1","type":"message","role":"assistant","model":"claude","content":[],"stop_reason":null,"usage":{"input_tokens":10,"output_tokens":1}}}

event: content_block_start
data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}

event: content_block_delta
data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello"}}

event: content_block_delta
data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":" world"}}

event: content_block_stop
data: {"type":"content_block_stop","index":0}

event: message_delta
data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":2}}

event: message_stop
data: {"type":"message_stop"}

```

`test/fixtures/anthropic/tool-call-stream.sse`:
```
event: message_start
data: {"type":"message_start","message":{"id":"msg_2","type":"message","role":"assistant","model":"claude","content":[],"stop_reason":null,"usage":{"input_tokens":50,"output_tokens":1}}}

event: content_block_start
data: {"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"toolu_abc","name":"bash","input":{}}}

event: content_block_delta
data: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\"command\":"}}

event: content_block_delta
data: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"\"echo hi\"}"}}

event: content_block_stop
data: {"type":"content_block_stop","index":0}

event: message_delta
data: {"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":15}}

event: message_stop
data: {"type":"message_stop"}

```

`test/fixtures/anthropic/error.sse`:
```
event: error
data: {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}

```

- [ ] **Step 2: Write the failing `test/OpenCode/LLM/AnthropicSpec.hs`**

```haskell
module OpenCode.LLM.AnthropicSpec (spec) where

import Conduit qualified
import Conduit ((.|))
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Map.Strict qualified as Map
import Test.Hspec

import OpenCode.LLM.Anthropic
import OpenCode.Types (StreamEvent (..), Usage (..))

spec :: Spec
spec = do
  describe "decodeEvent" $ do

    it "parses a text_delta event" $
      decodeEvent "{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Hi\"}}"
        `shouldBe` Right (EvBlockDelta 0 (DeltaText "Hi"))

    it "parses a tool_use content_block_start" $
      decodeEvent "{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"t1\",\"name\":\"bash\",\"input\":{}}}"
        `shouldBe` Right (EvBlockStart 0 (BlockToolUse "t1" "bash"))

    it "parses a message_delta with output usage" $
      decodeEvent "{\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":7}}"
        `shouldBe` Right (EvMessageDelta (Just 7))

    it "parses an error event" $
      decodeEvent "{\"type\":\"error\",\"error\":{\"type\":\"overloaded_error\",\"message\":\"Overloaded\"}}"
        `shouldBe` Right (EvError "Overloaded")

  describe "processAnthropicEvent" $ do

    it "emits ToolCallStart and records the block id" $
      let (evs, acc) = processAnthropicEvent emptyAccum (EvBlockStart 0 (BlockToolUse "t1" "bash"))
      in do
        evs `shouldBe` [ToolCallStart "t1" "bash"]
        Map.lookup 0 (accBlocks acc) `shouldBe` Just "t1"

    it "maps input_json_delta to ToolCallArgDelta via the recorded id" $
      let (_, acc) = processAnthropicEvent emptyAccum (EvBlockStart 0 (BlockToolUse "t1" "bash"))
          (evs, _) = processAnthropicEvent acc (EvBlockDelta 0 (DeltaInputJson "{\"a\":1}"))
      in evs `shouldBe` [ToolCallArgDelta "t1" "{\"a\":1}"]

    it "emits ToolCallEnd on content_block_stop for a tool block" $
      let (_, acc) = processAnthropicEvent emptyAccum (EvBlockStart 0 (BlockToolUse "t1" "bash"))
          (evs, _) = processAnthropicEvent acc (EvBlockStop 0)
      in evs `shouldBe` [ToolCallEnd "t1"]

    it "emits StreamDone combining stored input with output tokens" $
      let (_, acc) = processAnthropicEvent emptyAccum (EvMessageStart 12)
          (evs, _) = processAnthropicEvent acc (EvMessageDelta (Just 3))
      in evs `shouldBe` [StreamDone (Usage 12 3 Nothing Nothing)]

    it "emits TextDelta for text deltas" $
      fst (processAnthropicEvent emptyAccum (EvBlockDelta 0 (DeltaText "hey")))
        `shouldBe` [TextDelta "hey"]

  describe "interpretAnthropicStream" $ do

    it "reassembles a multi-block text response into TextDelta + StreamDone" $ do
      events <- runStream "test/fixtures/anthropic/text-stream.sse"
      events `shouldBe`
        [ TextDelta "Hello", TextDelta " world", StreamDone (Usage 10 2 Nothing Nothing) ]

    it "decodes a fragmented tool call into ordered start/delta/end events" $ do
      events <- runStream "test/fixtures/anthropic/tool-call-stream.sse"
      events `shouldBe`
        [ ToolCallStart "toolu_abc" "bash"
        , ToolCallArgDelta "toolu_abc" "{\"command\":"
        , ToolCallArgDelta "toolu_abc" "\"echo hi\"}"
        , ToolCallEnd "toolu_abc"
        , StreamDone (Usage 50 15 Nothing Nothing)
        ]

    it "emits exactly one StreamError on an error event" $ do
      events <- runStream "test/fixtures/anthropic/error.sse"
      events `shouldBe` [StreamError "Overloaded"]

  describe "anthropicErrorFromHttp" $
    it "includes the status code and body snippet" $
      anthropicErrorFromHttp 529 "overloaded"
        `shouldBe` StreamError "anthropic: 529: overloaded"

runStream :: FilePath -> IO [StreamEvent]
runStream path = do
  body <- BS.readFile path
  Conduit.runResourceT $ Conduit.runConduit $
    Conduit.yieldMany [body :: ByteString]
      .| interpretAnthropicStream
      .| Conduit.sinkList
```

Register the spec module in `package.yaml` (`tests: opencode-hs-test: other-modules:`), after `OpenCode.LLM.AnthropicSpec`'s alphabetical neighbor — place it right before `OpenCode.LLM.MockSpec`:

```yaml
      - OpenCode.LLM.AnthropicSpec
      - OpenCode.LLM.MockSpec
```

- [ ] **Step 3: Run the tests — verify they FAIL**

Run:
```bash
stack test --ta '--match "interpretAnthropicStream"'
```
Expected: RED — `OpenCode.LLM.Anthropic` does not export `decodeEvent`/`processAnthropicEvent`/`interpretAnthropicStream`/`EvBlockStart`/etc. (compile error).

- [ ] **Step 4: Replace `src/OpenCode/LLM/Anthropic.hs` with the full module**

```haskell
-- | Anthropic provider: streaming completions via the Messages API (SSE).
module OpenCode.LLM.Anthropic
  ( -- * Provider
    AnthropicProvider (..)
  , defaultAnthropic
    -- * SSE event model (internal — exposed for tests)
  , AnthropicEvent (..)
  , BlockStart (..)
  , BlockDelta (..)
  , AnthropicAccum (..)
  , emptyAccum
  , decodeEvent
  , processAnthropicEvent
  , interpretAnthropicStream
    -- * Streaming
  , streamAnthropic
  , anthropicErrorFromHttp
  ) where

import Conduit (ConduitT, MonadIO, await, yield, (.|))
import Conduit qualified
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Trans.Resource (ResourceT)
import Data.Aeson (FromJSON (..), withObject, (.:), (.:?))
import Data.Aeson qualified as Aeson
import Data.Aeson.Types (Parser)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEnc
import Data.Text.Encoding.Error (lenientDecode)
import Network.HTTP.Conduit (responseTimeout, responseTimeoutNone)
import Network.HTTP.Simple (setRequestBodyLBS, setRequestHeaders, setRequestMethod)
import Network.HTTP.Simple qualified as HTTP
import Network.HTTP.Types (statusCode)

import OpenCode.LLM.Request qualified as Request
import OpenCode.LLM.Schema qualified as Schema
import OpenCode.LLM.Types (LLMProvider (..), LLMRequest)
import OpenCode.Types (ApiKey, StreamEvent (..), Usage (..), unApiKey)

-- ---------------------------------------------------------------------------
-- Provider
-- ---------------------------------------------------------------------------

data AnthropicProvider = AnthropicProvider
  { apiKey  :: ApiKey
  , baseUrl :: Text
  }
  deriving stock (Show, Eq)

defaultAnthropic :: ApiKey -> AnthropicProvider
defaultAnthropic key = AnthropicProvider
  { apiKey  = key
  , baseUrl = "https://api.anthropic.com"
  }

-- ---------------------------------------------------------------------------
-- SSE event model (internal — exposed for tests)
-- ---------------------------------------------------------------------------

data BlockStart = BlockText | BlockToolUse Text Text   -- ^ id, name
  deriving stock (Show, Eq)

data BlockDelta = DeltaText Text | DeltaInputJson Text
  deriving stock (Show, Eq)

data AnthropicEvent
  = EvMessageStart Int            -- ^ input tokens
  | EvBlockStart Int BlockStart   -- ^ content index, block kind
  | EvBlockDelta Int BlockDelta   -- ^ content index, delta kind
  | EvBlockStop Int
  | EvMessageDelta (Maybe Int)    -- ^ output tokens
  | EvMessageStop
  | EvPing
  | EvError Text
  | EvOther
  deriving stock (Show, Eq)

instance FromJSON AnthropicEvent where
  parseJSON = withObject "AnthropicEvent" $ \o -> do
    ty <- o .: "type" :: Parser Text
    case ty of
      "message_start" -> do
        msg    <- o .: "message" :: Parser Aeson.Object
        mUsage <- msg .:? "usage" :: Parser (Maybe Aeson.Object)
        inp    <- case mUsage of
                    Just u  -> u .:? "input_tokens"
                    Nothing -> pure Nothing
        pure (EvMessageStart (fromMaybe 0 inp))
      "content_block_start" -> do
        idx <- o .: "index"
        blk <- o .: "content_block" :: Parser Aeson.Object
        bty <- blk .: "type" :: Parser Text
        case bty of
          "tool_use" -> do
            cid  <- blk .: "id"
            name <- blk .: "name"
            pure (EvBlockStart idx (BlockToolUse cid name))
          _ -> pure (EvBlockStart idx BlockText)
      "content_block_delta" -> do
        idx <- o .: "index"
        d   <- o .: "delta" :: Parser Aeson.Object
        dty <- d .: "type" :: Parser Text
        case dty of
          "text_delta"       -> EvBlockDelta idx . DeltaText      <$> d .: "text"
          "input_json_delta" -> EvBlockDelta idx . DeltaInputJson <$> d .: "partial_json"
          _                  -> pure EvOther
      "content_block_stop" -> EvBlockStop <$> o .: "index"
      "message_delta" -> do
        mUsage <- o .:? "usage" :: Parser (Maybe Aeson.Object)
        out    <- case mUsage of
                    Just u  -> u .:? "output_tokens"
                    Nothing -> pure Nothing
        pure (EvMessageDelta out)
      "message_stop" -> pure EvMessageStop
      "ping"         -> pure EvPing
      "error"        -> do
        err <- o .: "error" :: Parser Aeson.Object
        EvError <$> err .: "message"
      _ -> pure EvOther

-- | Decode one SSE payload as an 'AnthropicEvent'.
decodeEvent :: ByteString -> Either String AnthropicEvent
decodeEvent = Aeson.eitherDecodeStrict

-- ---------------------------------------------------------------------------
-- Accumulator
-- ---------------------------------------------------------------------------

data AnthropicAccum = AnthropicAccum
  { accBlocks :: Map Int Text   -- ^ content index → callId (tool_use blocks)
  , accInput  :: Int            -- ^ input tokens carried from message_start
  }
  deriving stock (Show, Eq)

emptyAccum :: AnthropicAccum
emptyAccum = AnthropicAccum Map.empty 0

-- | Consume one event, emitting zero or more 'StreamEvent's.
processAnthropicEvent :: AnthropicAccum -> AnthropicEvent -> ([StreamEvent], AnthropicAccum)
processAnthropicEvent acc ev = case ev of
  EvMessageStart inp -> ([], acc { accInput = inp })
  EvBlockStart idx (BlockToolUse cid name) ->
    ([ToolCallStart cid name], acc { accBlocks = Map.insert idx cid (accBlocks acc) })
  EvBlockStart _ BlockText -> ([], acc)
  EvBlockDelta _ (DeltaText t)
    | Text.null t -> ([], acc)
    | otherwise   -> ([TextDelta t], acc)
  EvBlockDelta idx (DeltaInputJson frag) ->
    case Map.lookup idx (accBlocks acc) of
      Just cid | not (Text.null frag) -> ([ToolCallArgDelta cid frag], acc)
      _                               -> ([], acc)
  EvBlockStop idx ->
    case Map.lookup idx (accBlocks acc) of
      Just cid -> ([ToolCallEnd cid], acc)
      Nothing  -> ([], acc)
  EvMessageDelta (Just out) -> ([StreamDone (Usage (accInput acc) out Nothing Nothing)], acc)
  EvMessageDelta Nothing    -> ([], acc)
  EvMessageStop -> ([], acc)
  EvPing        -> ([], acc)
  EvError e     -> ([StreamError e], acc)
  EvOther       -> ([], acc)

-- ---------------------------------------------------------------------------
-- Pure SSE → StreamEvent pipeline
-- ---------------------------------------------------------------------------

interpretAnthropicStream :: MonadIO m => ConduitT ByteString StreamEvent m ()
interpretAnthropicStream = Request.chunkSSELines .| go emptyAccum
  where
    go acc = do
      mline <- await
      case mline of
        Nothing   -> pure ()
        Just line -> case Request.sseDataLine line of
          Nothing      -> go acc
          Just payload -> case decodeEvent payload of
            Left _   -> go acc                -- ignore malformed payloads
            Right ev -> do
              let (events, acc') = processAnthropicEvent acc ev
              mapM_ yield events
              go acc'

-- ---------------------------------------------------------------------------
-- HTTP integration
-- ---------------------------------------------------------------------------

anthropicErrorFromHttp :: Int -> ByteString -> StreamEvent
anthropicErrorFromHttp status body =
  let snippet = BS.take 200 body
  in StreamError $
      "anthropic: " <> Text.pack (show status) <> ": " <> TextEnc.decodeUtf8With lenientDecode snippet

-- | Stream completions from Anthropic's Messages API via SSE.
streamAnthropic
  :: AnthropicProvider
  -> LLMRequest
  -> ConduitT () StreamEvent (ResourceT IO) ()
streamAnthropic provider req = do
  initReq <- liftIO $ HTTP.parseRequest (Text.unpack (baseUrl provider) <> "/v1/messages")
  let bodyBytes = Aeson.encode (Schema.buildAnthropicRequestBody req)
      headers =
        [ ("x-api-key", TextEnc.encodeUtf8 (unApiKey (apiKey provider)))
        , ("anthropic-version", "2023-06-01")
        , ("Content-Type", "application/json")
        , ("Accept", "text/event-stream")
        ]
      httpReq = setRequestMethod "POST"
              . setRequestHeaders headers
              . setRequestBodyLBS bodyBytes
              $ initReq { responseTimeout = responseTimeoutNone }
  HTTP.httpSource httpReq dispatch
  where
    dispatch response =
      let code = statusCode (HTTP.getResponseStatus response)
      in if code >= 200 && code < 300
           then HTTP.getResponseBody response .| interpretAnthropicStream
           else do
             body <- HTTP.getResponseBody response .| Conduit.foldC
             yield (anthropicErrorFromHttp code body)

instance LLMProvider AnthropicProvider where
  streamCompletion = streamAnthropic
```

- [ ] **Step 5: Run the tests — verify they PASS**

Run:
```bash
stack test --ta '--match "decodeEvent"'
stack test --ta '--match "processAnthropicEvent"'
stack test --ta '--match "interpretAnthropicStream"'
```
Expected: GREEN — all event-decode, accumulator, and fixture-replay cases pass. Then `stack build && stack test` for the whole suite. If GHC flags an unused import in `Anthropic.hs`, remove only that name.

- [ ] **Step 6: Commit**

```bash
git add src/OpenCode/LLM/Anthropic.hs test/OpenCode/LLM/AnthropicSpec.hs \
        test/fixtures/anthropic package.yaml
git commit -m "$(cat <<'EOF'
M11: Anthropic streaming module (SSE event model + interpreter + HTTP)

Replace the stub with AnthropicProvider/defaultAnthropic, an AnthropicEvent ADT
decoded by dispatching on the SSE payload type, processAnthropicEvent
accumulator (block-index→callId + carried input tokens), interpretAnthropicStream
(reusing chunkSSELines/sseDataLine), and streamAnthropic over POST /v1/messages.
Fixture-replay tests mirror OpenAISpec.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Wire Anthropic into dispatch + config check

**Files:**
- Modify: `src/OpenCode/Config.hs`
- Modify: `src/OpenCode/Session.hs`
- Modify: `src/OpenCode/Run.hs`
- Test: `test/OpenCode/SessionSpec.hs`

- [ ] **Step 1: Update the failing `streamerForProvider` tests in `test/OpenCode/SessionSpec.hs`**

The M10 test `"fails for Anthropic (not yet implemented)"` asserted `isLeft` for an Anthropic key that was never actually set (the `cfgWith` helper hardcodes `anthropicKey = Nothing`). Replace that single `it` with two cases — one for the absent key (still `Left`) and one for a present key (now `Right`). Find:

```haskell
    it "fails for Anthropic (not yet implemented)" $
      isLeft (streamerForProvider (cfgWith (Just (ApiKey "k")) Nothing) Anthropic)
        `shouldBe` True
```

Replace with:

```haskell
    it "fails when the Anthropic key is absent" $
      isLeft (streamerForProvider (cfgWith Nothing Nothing) Anthropic) `shouldBe` True
    it "returns a streamer when the Anthropic key is present" $
      isRight (streamerForProvider cfgAnthropic Anthropic) `shouldBe` True
```

Add the fixture next to the existing `cfgWith` helper at the bottom of the file:

```haskell
cfgAnthropic :: Config
cfgAnthropic = Config
  { providers    = ProviderConfig
      { openaiKey = Nothing, anthropicKey = Just (ApiKey "k"), minimaxKey = Nothing }
  , defaultModel = ModelId Anthropic "claude-opus-4-5"
  }
```

- [ ] **Step 2: Run the tests — verify they FAIL**

Run:
```bash
stack test --ta '--match "streamerForProvider"'
```
Expected: RED — `"returns a streamer when the Anthropic key is present"` fails (current `streamerForProvider` returns `Left` for the `Anthropic` arm).

- [ ] **Step 3: Add `defaultAnthropicModel` to `src/OpenCode/Config.hs`**

Add it to the export list under `-- * Pure assembly (exported for white-box testing)`:

```haskell
  , defaultMiniMaxModel
  , defaultAnthropicModel
```

Add the definition next to `defaultMiniMaxModel`:

```haskell
-- | The Anthropic model used as the fallback default and for connectivity probes.
defaultAnthropicModel :: Text
defaultAnthropicModel = "claude-opus-4-5"
```

Redefine `fallbackModel` to use it (no value change):

```haskell
fallbackModel :: ModelId
fallbackModel = ModelId { provider = Anthropic, model = defaultAnthropicModel }
```

- [ ] **Step 4: Generalize `withKey` in `src/OpenCode/Session.hs`**

Replace the `streamerForProvider` definition (and its `where`):

```haskell
streamerForProvider :: Config.Config -> ProviderId -> Either AppError Streamer
streamerForProvider cfg pid =
  case pid of
    OpenAI    -> withKey (Config.openaiKey  pc) "OpenAI"
                   (OpenAI.streamOpenAI . OpenAI.defaultOpenAI)
    MiniMax   -> withKey (Config.minimaxKey pc) "MiniMax"
                   (OpenAI.streamOpenAI . OpenAI.minimaxOpenAI)
    Anthropic -> withKey (Config.anthropicKey pc) "Anthropic"
                   (Anthropic.streamAnthropic . Anthropic.defaultAnthropic)
  where
    pc = Config.providers cfg
    withKey mKey label mkStreamer = case mKey of
      Nothing  -> Left (LLMError ("no " <> label <> " API key configured"))
      Just key -> Right (mkStreamer key)
```

Add the import (next to the existing `import OpenCode.LLM.OpenAI qualified as OpenAI`):

```haskell
import OpenCode.LLM.Anthropic qualified as Anthropic
```

- [ ] **Step 5: Probe Anthropic for real in `src/OpenCode/Run.hs`**

In `checkProvider`, remove the Anthropic short-circuit so a configured key probes like the others. Replace:

```haskell
  status <- case mKey of
    Nothing -> pure "not configured"
    Just _  -> case pid of
      Anthropic -> pure "FAIL (not implemented until M11)"
      _         -> case streamerForProvider cfg pid of
        Left err       -> pure ("FAIL (" <> displayAppError err <> ")")
        Right streamer -> probeProvider streamer (probeModel cfg pid)
```

with:

```haskell
  status <- case mKey of
    Nothing -> pure "not configured"
    Just _  -> case streamerForProvider cfg pid of
      Left err       -> pure ("FAIL (" <> displayAppError err <> ")")
      Right streamer -> probeProvider streamer (probeModel cfg pid)
```

In `probeModel`, change the Anthropic arm from `""` to `defaultAnthropicModel`:

```haskell
probeModel cfg pid
  | provider (defaultModel cfg) == pid = model (defaultModel cfg)
  | otherwise = case pid of
      OpenAI    -> "gpt-4o"
      MiniMax   -> defaultMiniMaxModel
      Anthropic -> defaultAnthropicModel
```

Add `defaultAnthropicModel` to the `OpenCode.Config` import in `Run.hs`:

```haskell
import OpenCode.Config
  ( Config (..), ProviderConfig (..), defaultAnthropicModel, defaultMiniMaxModel, loadConfig )
```

- [ ] **Step 6: Run the tests — verify they PASS**

Run:
```bash
stack test --ta '--match "streamerForProvider"'
stack build && stack test
```
Expected: GREEN — Anthropic-with-key → `Right`, absent → `Left`; full suite passes. Remove any unused import GHC flags.

- [ ] **Step 7: Commit**

```bash
git add src/OpenCode/Config.hs src/OpenCode/Session.hs src/OpenCode/Run.hs \
        test/OpenCode/SessionSpec.hs
git commit -m "$(cat <<'EOF'
M11: wire Anthropic into provider dispatch + config check

Generalize streamerForProvider's withKey to an ApiKey->Streamer builder so the
Anthropic arm returns streamAnthropic; config check now probes Anthropic for
real; add/export Config.defaultAnthropicModel and use it in fallbackModel and
the probe.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: Integration — full verify + mark M11 done

**Files:**
- Modify: `MILESTONES.md`

- [ ] **Step 1: Full build + test + lint**

Run:
```bash
stack build 2>&1 | grep -iE "warning|error" | grep -viE "MacOSX.sdk|search path|ld: warning"
stack test  2>&1 | tail -5
hlint src app test
```
Expected: no Haskell warnings; entire suite green; `hlint` reports `No hints`. Fix any new hint in the touched files.

- [ ] **Step 2: Smoke-test the dispatch wiring (no key required)**

Run:
```bash
~/.ghcup/bin/stack run opencode-hs -- config check 2>/dev/null
```
Expected: three lines `openai: …`, `minimax: …`, `anthropic: …`. With no `ANTHROPIC_API_KEY` set, the Anthropic line reads `anthropic: not configured` (it no longer says "not implemented"). If an `ANTHROPIC_API_KEY` is set, it performs a real probe and should read `anthropic: OK`.

- [ ] **Step 3: Mark M11 done in `MILESTONES.md`**

In the status-snapshot table, change the M11 row from:

```markdown
| M11 | Anthropic provider                     | pending   | —                  |
```

to (use the first M11 commit SHA from `git log --oneline --grep "^M11:"` — the `Schema` commit — for the cell):

```markdown
| M11 | Anthropic provider                     | done      | `<first-M11-sha>..` |
```

Change the section heading from `## M11 — Anthropic provider` to `## M11 — Anthropic provider — DONE` and insert an outcome paragraph immediately under it:

```markdown
## M11 — Anthropic provider — DONE

Outcome: `OpenCode.LLM.Anthropic` implements the Messages API over SSE — an
`AnthropicEvent` ADT decoded by dispatching on the payload `type`, a
`processAnthropicEvent` accumulator (block-index→callId + carried input tokens),
`interpretAnthropicStream` reusing `chunkSSELines`/`sseDataLine`, and
`streamAnthropic` (`POST /v1/messages`, `x-api-key` + `anthropic-version`, non-2xx
→ `StreamError`). Request shaping lives in `OpenCode.LLM.Schema`
(`buildAnthropicRequestBody` with required `max_tokens` + hoisted `system` +
ephemeral cache_control, `messagesToAnthropic` putting tool results in a user
turn and decoding `ToolArgs` to an object, `toolToAnthropicSchema`).
`streamerForProvider` now returns a real streamer for the `Anthropic` arm (its
`withKey` generalized to an `ApiKey -> Streamer` builder), `config check` probes
Anthropic for real, and `Config.defaultAnthropicModel` backs both the fallback
model and the probe. Verified by fixture-replay tests mirroring `OpenAISpec`
(text reassembly, fragmented tool call, error event) plus Schema unit tests; a
live run needs an `ANTHROPIC_API_KEY`.

**Goal**: Add the second provider, reusing the M4 streaming infrastructure.
```

(Leave the existing Tasks/Tests/Acceptance subsections below the new outcome paragraph.)

- [ ] **Step 4: Commit**

```bash
git add MILESTONES.md
git commit -m "$(cat <<'EOF'
M11: verification + mark milestone done

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Self-Review

**Spec coverage** (against `2026-06-04-m11-anthropic-provider-design.md`):
- `toolToAnthropicSchema` / `messagesToAnthropic` / `buildAnthropicRequestBody` (max_tokens default, system hoist + cache_control, tool_result in user turn, ToolArgs→object) → Task 1.
- `OpenCode.LLM.Anthropic`: provider record + `defaultAnthropic`, `AnthropicEvent` + `FromJSON`, `processAnthropicEvent` accumulator, `interpretAnthropicStream`, `streamAnthropic` + `anthropicErrorFromHttp`, `LLMProvider` instance → Task 2.
- `streamerForProvider` Anthropic arm (generalized `withKey`), `config check` real probe, `Config.defaultAnthropicModel`/`fallbackModel` → Task 3.
- Fixture-replay + unit tests → Tasks 1, 2, 3; acceptance + milestone → Task 4.

**Type/name consistency:** `buildAnthropicRequestBody`/`messagesToAnthropic`/`toolToAnthropicSchema`/`defaultAnthropicMaxTokens` defined in Task 1 (Schema) and consumed by `streamAnthropic` (Task 2) and tests; `AnthropicEvent`/`BlockStart`/`BlockDelta`/`AnthropicAccum`/`emptyAccum`/`decodeEvent`/`processAnthropicEvent`/`interpretAnthropicStream`/`anthropicErrorFromHttp` defined and exported in Task 2 and used by `AnthropicSpec` (Task 2); `defaultAnthropic`/`streamAnthropic` consumed by `streamerForProvider` (Task 3); `defaultAnthropicModel` defined/exported in Task 3 (Config) and used by `probeModel` (Run, Task 3); `LLMRequest` field names (`reqModel`/`reqMessages`/`reqTools`/`reqSystemPrompt`/`reqMaxTokens`) and accessors (`callId`/`toolName`/`arguments`/`unToolArgs`/`resultCallId`/`content`) match `OpenCode.Types`/`OpenCode.LLM.Types`; `Streamer = LLMRequest -> ConduitT () StreamEvent (ResourceT IO) ()`, so `streamAnthropic . defaultAnthropic :: ApiKey -> Streamer` fits `withKey`.

**Placeholder scan:** no TBD/TODO; every code step shows complete code (the Task 1 `lbsInfix` helper is shown in final form). The only "fill-in" is the M11 commit SHA in Task 4 Step 3, a concrete `git log` instruction matching the table convention.
