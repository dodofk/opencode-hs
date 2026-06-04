module OpenCode.LLM.SchemaSpec (spec) where

import Data.Aeson (Value (..), object, (.=))
import qualified Data.Aeson as Aeson
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as LBS
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
      case result of
        (a : t : _) -> do
          asKM a `shouldSatisfy` KM.member "tool_calls"
          asKM t `shouldSatisfy` KM.member "tool_call_id"
        _ -> expectationFailure "expected two converted messages"

    it "emits the tool result for an assistant message that bundles call+result" $ do
      -- buildAssistantMessage packs the ToolCallPart and its ToolResultPart into
      -- ONE assistant message; both the tool_call and the matching tool result
      -- must reach the wire, else the provider rejects "tool call and result not
      -- match".
      let msgs =
            [ Message (MessageId "m1") RoleAssistant
                (NE.fromList
                  [ ToolCallPart   (ToolCall "c1" "bash" (ToolArgs "{}"))
                  , ToolResultPart (ToolResult "c1" "ok" False)
                  ]) t0
            ]
          result = messagesToOpenAI "" msgs
      length result `shouldBe` 2
      case result of
        (a : t : _) -> do
          asKM a `shouldSatisfy` KM.member "tool_calls"
          KM.lookup "role"         (asKM t) `shouldBe` Just (String "tool")
          KM.lookup "tool_call_id" (asKM t) `shouldBe` Just (String "c1")
          KM.lookup "content"      (asKM t) `shouldBe` Just (String "ok")
        _ -> expectationFailure "expected assistant + tool messages"

    it "emits one tool result per call for a multi-tool assistant message" $ do
      let msgs =
            [ Message (MessageId "m1") RoleAssistant
                (NE.fromList
                  [ ToolCallPart   (ToolCall "c1" "bash" (ToolArgs "{}"))
                  , ToolResultPart (ToolResult "c1" "a" False)
                  , ToolCallPart   (ToolCall "c2" "bash" (ToolArgs "{}"))
                  , ToolResultPart (ToolResult "c2" "b" False)
                  ]) t0
            ]
          result = messagesToOpenAI "" msgs
      -- 1 assistant message (2 tool_calls) + 2 tool messages
      length result `shouldBe` 3
      [ KM.lookup "tool_call_id" (asKM t)
        | t <- drop 1 result ] `shouldBe` [Just (String "c1"), Just (String "c2")]

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
          Aeson.encode a `shouldSatisfy` lbsInfix "\"type\":\"tool_use\""
          Aeson.encode a `shouldSatisfy` lbsInfix "\"input\":{\"command\":\"ls\"}"
          Aeson.encode u `shouldSatisfy` lbsInfix "\"tool_use_id\":\"c1\""
          Aeson.encode u `shouldSatisfy` lbsInfix "\"type\":\"tool_result\""
          Aeson.encode u `shouldNotSatisfy` lbsInfix "is_error"
        _ -> expectationFailure "expected assistant + user messages"

    it "marks a failed tool result with is_error" $ do
      let msgs =
            [ Message (MessageId "m1") RoleAssistant
                (NE.fromList
                  [ ToolCallPart   (ToolCall "c1" "bash" (ToolArgs "{}"))
                  , ToolResultPart (ToolResult "c1" "boom" True)
                  ]) t0
            ]
      Aeson.encode (Aeson.toJSON (messagesToAnthropic msgs))
        `shouldSatisfy` lbsInfix "\"is_error\":true"

    it "serialises multiple tool calls in one assistant message in order" $ do
      let msgs =
            [ Message (MessageId "m1") RoleAssistant
                (NE.fromList
                  [ ToolCallPart   (ToolCall "c1" "bash" (ToolArgs "{}"))
                  , ToolResultPart (ToolResult "c1" "a" False)
                  , ToolCallPart   (ToolCall "c2" "bash" (ToolArgs "{}"))
                  , ToolResultPart (ToolResult "c2" "b" False)
                  ]) t0
            ]
          result = messagesToAnthropic msgs
      length result `shouldBe` 2          -- one assistant turn + one user turn
      let assistantEnc = Aeson.encode (head result)
          userEnc      = Aeson.encode (result !! 1)
      assistantEnc `shouldSatisfy` lbsInfix "\"id\":\"c1\""
      assistantEnc `shouldSatisfy` lbsInfix "\"id\":\"c2\""
      userEnc `shouldSatisfy` lbsInfix "\"tool_use_id\":\"c1\""
      userEnc `shouldSatisfy` lbsInfix "\"tool_use_id\":\"c2\""

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

lbsInfix :: LBS.ByteString -> LBS.ByteString -> Bool
lbsInfix needle hay = LBS.toStrict needle `BS.isInfixOf` LBS.toStrict hay
