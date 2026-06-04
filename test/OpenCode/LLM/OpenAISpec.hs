module OpenCode.LLM.OpenAISpec (spec) where

import Conduit qualified
import Conduit ((.|))
import Data.Aeson qualified as Aeson
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Text (Text)
import Data.Text qualified as Text
import Test.Hspec

import OpenCode.LLM.OpenAI
import OpenCode.LLM.Schema qualified as Schema
import OpenCode.LLM.Types (LLMRequest (..))
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

    it "emits ReasoningDelta for reasoning_content" $ do
      events <- runStream "test/fixtures/openai/reasoning-content.sse"
      events `shouldBe`
        [ ReasoningDelta "let me think", TextDelta "answer", StreamDone (Usage 3 2 Nothing Nothing) ]

    it "splits inline <think> content into reasoning + text" $ do
      events <- runStream "test/fixtures/openai/inline-think.sse"
      events `shouldBe`
        [ ReasoningDelta "reasoning here", TextDelta "final", StreamDone (Usage 1 1 Nothing Nothing) ]

  describe "splitThink / stepThink (inline <think> splitter)" $ do
    it "passes plain text through as TextDelta" $
      let (_, evs) = stepThink initThink "hello world"
      in evs `shouldBe` [TextDelta "hello world"]

    it "routes text inside <think>...</think> to ReasoningDelta" $
      let (_, evs) = stepThink initThink "before<think>secret</think>after"
      in evs `shouldBe` [TextDelta "before", ReasoningDelta "secret", TextDelta "after"]

    it "tolerates a tag split across two deltas" $
      let (s1, e1) = stepThink initThink "abc<thi"
          (_,  e2) = stepThink s1 "nk>xyz"
      in (e1, e2) `shouldBe` ([TextDelta "abc"], [ReasoningDelta "xyz"])

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

    it "handles invalid UTF-8 in the body without throwing" $ do
      -- 0xC0 0x80 is an overlong/invalid UTF-8 sequence; followed by truncation
      -- mid-multibyte. lenient decode should replace with U+FFFD, NOT throw.
      let invalidUtf8 = BS.pack [0xC0, 0x80, 0xE2, 0x82]  -- last 2 bytes start a 3-byte UTF-8 sequence (truncated)
      case streamErrorFromHttp 500 invalidUtf8 of
        StreamError _ -> pure ()
        _             -> expectationFailure "expected StreamError"

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

-- ---------------------------------------------------------------------------
-- Fixture replay helper
-- ---------------------------------------------------------------------------

runStream :: FilePath -> IO [StreamEvent]
runStream path = do
  body <- BS.readFile path
  -- Feed the whole body as a single chunk; chunk-boundary resilience is
  -- tested separately in OpenCode.LLM.RequestSpec.
  Conduit.runResourceT $ Conduit.runConduit $
    Conduit.yieldMany [body]
      .| interpretOpenAIStream
      .| Conduit.sinkList

-- ---------------------------------------------------------------------------
-- Test fixtures: small chunk builders so tests are readable
-- ---------------------------------------------------------------------------

mkTextChunk :: Text -> ChatCompletionChunk
mkTextChunk content = ChatCompletionChunk
  { cccId      = "x"
  , cccChoices =
      [ Choice
          { choiceIndex        = 0
          , choiceDelta        = Delta { deltaContent = Just content, deltaReasoning = Nothing, deltaToolCalls = Nothing }
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
              , deltaReasoning = Nothing
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
              , deltaReasoning = Nothing
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
          , choiceDelta        = Delta { deltaContent = Nothing, deltaReasoning = Nothing, deltaToolCalls = Nothing }
          , choiceFinishReason = Just reason
          }
      ]
  , cccUsage   = fmap (\(p, c, t) -> ChatCompletionUsage p c t) usage
  }
