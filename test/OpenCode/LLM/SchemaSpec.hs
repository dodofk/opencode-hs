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
