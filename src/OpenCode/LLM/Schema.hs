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
