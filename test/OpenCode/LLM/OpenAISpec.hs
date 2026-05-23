module OpenCode.LLM.OpenAISpec (spec) where

import Data.ByteString (ByteString)
import Data.Text (Text)
import Test.Hspec

import OpenCode.LLM.OpenAI
import OpenCode.Types (StreamEvent (..), Usage (..))

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
          case cccChoices c of
            [ch] -> do
              deltaContent (choiceDelta ch) `shouldBe` Just "Hello"
              deltaToolCalls (choiceDelta ch) `shouldBe` Nothing
              choiceFinishReason ch `shouldBe` Nothing
              cccUsage c `shouldBe` Nothing
            _ -> expectationFailure "expected exactly one choice"

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
          case cccChoices c of
            [ch] -> do
              choiceFinishReason ch `shouldBe` Just "stop"
              fmap ccUsagePromptTokens     (cccUsage c) `shouldBe` Just 10
              fmap ccUsageCompletionTokens (cccUsage c) `shouldBe` Just 2
            _ -> expectationFailure "expected exactly one choice"
        Left err -> expectationFailure err

    it "returns Left on malformed JSON" $
      case decodeChunk "{ not valid json" of
        Left _  -> pure ()
        Right _ -> expectationFailure "expected Left on bad JSON"

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
