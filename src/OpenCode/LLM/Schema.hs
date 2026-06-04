-- | OpenAI-specific JSON shape conversions.
-- Pure: produces 'Aeson.Value's that the HTTP layer encodes.
module OpenCode.LLM.Schema
  ( toolToOpenAISchema
  , messagesToOpenAI
  , buildOpenAIRequestBody
  , toolToAnthropicSchema
  , messagesToAnthropic
  , buildAnthropicRequestBody
  ) where

import Data.Aeson (Value (..), object, (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KM
import Data.List.NonEmpty qualified as NE
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TextEnc

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
  let sysMsg = [object ["role" .= ("system" :: Text), "content" .= systemPrompt]
               | not (T.null systemPrompt)]
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
              -- 'buildAssistantMessage' bundles each ToolCallPart with its
              -- ToolResultPart in this one assistant message, so emit the
              -- assistant tool_calls *and* the matching role:"tool" results
              -- right after it — the API rejects a tool_call with no result.
              object
                  [ "role"       .= ("assistant" :: Text)
                  , "content"    .= Aeson.Null
                  , "tool_calls" .= map toolCallToOpenAI toolCalls
                  ]
              : map toolResultToOpenAI toolResults
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

-- ---------------------------------------------------------------------------
-- Anthropic shapes
-- ---------------------------------------------------------------------------

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
toolResultBlock tr = object $
  [ "type"        .= ("tool_result" :: Text)
  , "tool_use_id" .= resultCallId tr
  , "content"     .= content tr
  ]
  <> [ "is_error" .= True | isError tr ]   -- Anthropic flags failed tool results

-- | Decode raw JSON-text tool arguments into a Value object for tool_use.input;
-- a non-decodable blob falls back to an empty object.
decodeArgs :: ToolArgs -> Value
decodeArgs a = fromMaybe (object []) (Aeson.decodeStrict (TextEnc.encodeUtf8 (unToolArgs a)))
