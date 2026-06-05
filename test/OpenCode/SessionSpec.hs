module OpenCode.SessionSpec (spec) where

import qualified Brick.BChan as BChan
import Control.Exception (bracket)
import qualified Control.Concurrent.STM as STM
import Control.Monad (when)
import Control.Monad.Except (runExceptT)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Reader (runReaderT)
import qualified Conduit
import Database.SQLite.Simple (close)
import System.Directory (doesFileExist, removeFile)
import Test.Hspec
import Data.Either (isLeft, isRight)
import qualified Data.List.NonEmpty as NE

import OpenCode.App (AppEnv (..))
import OpenCode.Config (Config (..), ProviderConfig (..))
import qualified OpenCode.DB as DB
import OpenCode.DB (openDb)
import OpenCode.LLM.Mock (staticStreamer, newScriptedStreamer)
import OpenCode.LLM.Types (LLMRequest (..), Streamer)
import OpenCode.Session (agentic, buildRequest, createSession, loadSession, abortSession, processUserMessageWith, streamerForProvider)
import OpenCode.Session.Events (RunState (..), SessionEvent (..))
import OpenCode.TestEnv (withTestEnv, drainBChan)
import OpenCode.Tool.Registry (defaultBuiltinRegistry)
import qualified Data.Text as Text
import OpenCode.Types
  ( ApiKey (..)
  , MessagePart (..)
  , ModelId (..)
  , ProviderId (..)
  , Role (..)
  , Session (..)
  , SessionId (..)
  , StreamEvent (..)
  , ToolResult (..)
  , Usage (..)
  , content
  , isError
  , msgParts
  , msgRole
  )

spec :: Spec
spec = do
  describe "createSession" $ do

    it "creates a session with the given model and returns it" $
      withFreshEnv $ \env -> do
        result <- runExceptT $ runReaderT
          (createSession (ModelId OpenAI "gpt-4o")) env
        case result of
          Right s -> do
            sessionModel s    `shouldBe` ModelId OpenAI "gpt-4o"
            sessionTitle s    `shouldBe` "untitled"
          Left e -> expectationFailure (show e)

    it "persists the session so it can be retrieved" $
      withFreshEnv $ \env -> do
        result <- runExceptT $ runReaderT
          (createSession (ModelId OpenAI "gpt-4o")) env
        case result of
          Right s -> do
            loaded <- runExceptT $ runReaderT (loadSession (sessionId s)) env
            loaded `shouldBe` Right (Just s)
          Left e -> expectationFailure (show e)

  describe "loadSession" $ do

    it "returns Nothing for an unknown SessionId" $
      withFreshEnv $ \env -> do
        result <- runExceptT $ runReaderT
          (loadSession (SessionId "no-such-session")) env
        result `shouldBe` Right Nothing

  describe "agentic (text-only, one round)" $ do

    it "builds an assistant message from a scripted text-only stream" $ do
      withTestEnv $ \env session -> do
        let streamer = staticStreamer
              [ TextDelta "Hello"
              , TextDelta " world"
              , StreamDone (Usage 5 2 Nothing Nothing)
              ]
        result <- runExceptT $ runReaderT
          (agentic streamer (sessionModel session) (sessionId session) []) env
        case result of
          Right msgs -> do
            length msgs `shouldBe` 1
            let m = head msgs
            msgRole m `shouldBe` RoleAssistant
            NE.toList (msgParts m) `shouldBe` [TextPart "Hello world"]
          Left err -> expectationFailure (show err)

    it "persists the assistant message to the DB" $ do
      withTestEnv $ \env session -> do
        let streamer = staticStreamer [TextDelta "hi", StreamDone (Usage 1 1 Nothing Nothing)]
        _ <- runExceptT $ runReaderT
          (agentic streamer (sessionModel session) (sessionId session) []) env
        stored <- DB.getMessages (envDb env) (sessionId session)
        length stored `shouldBe` 1
        msgRole (head stored) `shouldBe` RoleAssistant

  describe "agentic (streaming)" $ do

    it "emits PartialText for each TextDelta during the stream" $
      withTestEnv $ \env session -> do
        let streamer = staticStreamer
              [ TextDelta "Hel", TextDelta "lo"
              , StreamDone (Usage 1 1 Nothing Nothing)
              ]
        _    <- runExceptT $ runReaderT (agentic streamer (sessionModel session) (sessionId session) []) env
        evts <- drainBChan (envEventChan env)
        [t | PartialText t <- evts] `shouldBe` ["Hel", "lo"]

    it "emits PartialReasoning for each ReasoningDelta during the stream" $
      withTestEnv $ \env session -> do
        let streamer = staticStreamer
              [ ReasoningDelta "thinking", TextDelta "hi"
              , StreamDone (Usage 1 1 Nothing Nothing) ]
        _    <- runExceptT $ runReaderT (agentic streamer (sessionModel session) (sessionId session) []) env
        evts <- drainBChan (envEventChan env)
        [t | PartialReasoning t <- evts] `shouldBe` ["thinking"]

    it "does not surface an empty-response error when the round produced reasoning" $
      withTestEnv $ \env session -> do
        let streamer = staticStreamer
              [ ReasoningDelta "just thinking", StreamDone (Usage 0 0 Nothing Nothing) ]
        _    <- runExceptT $ runReaderT (agentic streamer (sessionModel session) (sessionId session) []) env
        evts <- drainBChan (envEventChan env)
        [() | ErrorOccurred _ <- evts] `shouldBe` []

  describe "agentic (error surfacing)" $ do

    it "persists a provider StreamError as an ErrorPart, no transient ErrorOccurred" $
      withTestEnv $ \env session -> do
        let streamer = staticStreamer [StreamError "minimax: 429: rate limited"]
        _    <- runExceptT $ runReaderT (agentic streamer (sessionModel session) (sessionId session) []) env
        evts <- drainBChan (envEventChan env)
        [m | ErrorOccurred m <- evts] `shouldBe` []
        stored <- DB.getMessages (envDb env) (sessionId session)
        let parts = concatMap (NE.toList . msgParts) stored
        [e | ErrorPart e <- parts] `shouldBe` ["minimax: 429: rate limited"]
        [s | RunStateChanged s <- evts] `shouldSatisfy` endsWith Idle

    it "persists partial text alongside a mid-stream error" $
      withTestEnv $ \env session -> do
        let streamer = staticStreamer
              [ TextDelta "partial answer", StreamError "connection reset by peer" ]
        _ <- runExceptT $ runReaderT (agentic streamer (sessionModel session) (sessionId session) []) env
        stored <- DB.getMessages (envDb env) (sessionId session)
        let parts = concatMap (NE.toList . msgParts) stored
        [t | TextPart t  <- parts] `shouldBe` ["partial answer"]
        [e | ErrorPart e <- parts] `shouldBe` ["connection reset by peer"]

    it "surfaces an empty first-round response as an ErrorOccurred event" $
      withTestEnv $ \env session -> do
        -- 200 OK but no text and no tool call (e.g. a reasoning model that
        -- streamed only thinking) must not look like a frozen no-response.
        let streamer = staticStreamer [StreamDone (Usage 0 0 Nothing Nothing)]
        _    <- runExceptT $ runReaderT (agentic streamer (sessionModel session) (sessionId session) []) env
        evts <- drainBChan (envEventChan env)
        length [() | ErrorOccurred _ <- evts] `shouldBe` 1
        [s | RunStateChanged s <- evts] `shouldSatisfy` endsWith Idle

  describe "agentic (with tool execution, multi-round)" $ do

    it "emits RoundStarted for each round, 1-based, with the round cap" $
      withTestEnv $ \env session -> do
        let toolArgs = "{\"path\":\"/tmp/m12-round.txt\",\"content\":\"hi\"}"
            round1 =
              [ ToolCallStart "c1" "write_file"
              , ToolCallArgDelta "c1" toolArgs
              , ToolCallEnd "c1"
              , StreamDone (Usage 1 1 Nothing Nothing) ]
            round2 = [ TextDelta "done", StreamDone (Usage 1 1 Nothing Nothing) ]
        streamer <- newScriptedStreamer [round1, round2]
        _    <- runExceptT $ runReaderT (agentic streamer (sessionModel session) (sessionId session) []) env
        evts <- drainBChan (envEventChan env)
        [ (c, t) | RoundStarted c t <- evts ] `shouldBe` [(1, 10), (2, 10)]

    it "executes a tool call and recurses for the next round" $
      withTestEnv $ \env session -> do
        let toolArgs = "{\"path\":\"/tmp/m6-test.txt\",\"content\":\"hi\"}"
            round1 =
              [ ToolCallStart "c1" "write_file"
              , ToolCallArgDelta "c1" toolArgs
              , ToolCallEnd "c1"
              , StreamDone (Usage 50 15 Nothing Nothing)
              ]
            round2 =
              [ TextDelta "Done."
              , StreamDone (Usage 5 2 Nothing Nothing)
              ]
        streamer <- newScriptedStreamer [round1, round2]
        result <- runExceptT $ runReaderT
          (agentic streamer (sessionModel session) (sessionId session) []) env
        case result of
          Right msgs -> do
            length msgs `shouldBe` 2   -- assistant msg 1 (tool call + result) + assistant msg 2 (text)
            let m1 = head msgs
            msgRole m1 `shouldBe` RoleAssistant
            any isToolCall   (NE.toList (msgParts m1)) `shouldBe` True
            any isToolResult (NE.toList (msgParts m1)) `shouldBe` True
            let m2 = msgs !! 1
            msgRole m2 `shouldBe` RoleAssistant
            NE.toList (msgParts m2) `shouldBe` [TextPart "Done."]
          Left err -> expectationFailure (show err)
        contents <- readFile "/tmp/m6-test.txt"
        contents `shouldBe` "hi"

  describe "agentic (abort)" $ do

    it "aborts mid-stream into a text-only message, skipping a fully-arrived tool call" $
      withTestEnv $ \env session -> do
        let path = "/tmp/m9-abort-skip.txt"
        removeIfExists path
        let streamer = abortingAfterToolCall (envAbort env) path
        result <- runExceptT $ runReaderT (agentic streamer (sessionModel session) (sessionId session) []) env
        case result of
          Right msgs -> do
            length msgs `shouldBe` 1
            NE.toList (msgParts (head msgs)) `shouldBe` [TextPart "after"]
          Left err -> expectationFailure (show err)
        -- the write_file tool must NOT have run
        exists <- doesFileExist path
        exists `shouldBe` False
        -- the text-only message was persisted
        stored <- DB.getMessages (envDb env) (sessionId session)
        length stored `shouldBe` 1

    it "stops before the next round when envAbort is set during a tool round" $
      withTestEnv $ \env session -> do
        let path = "/tmp/m9-between-rounds.txt"
        removeIfExists path
        let streamer = abortAfterToolRound (envAbort env) path
        result <- runExceptT $ runReaderT (agentic streamer (sessionModel session) (sessionId session) []) env
        case result of
          Right msgs -> length msgs `shouldBe` 1   -- round 1 only; no recursion into round 2
          Left err   -> expectationFailure (show err)
        -- the tool DID run in round 1 (between-rounds abort only prevents the NEXT round)
        exists <- doesFileExist path
        exists `shouldBe` True

    it "abortSession sets the envAbort flag" $
      withTestEnv $ \env _session -> do
        flagBefore <- STM.readTVarIO (envAbort env)
        flagBefore `shouldBe` False
        _ <- runExceptT $ runReaderT abortSession env
        flagAfter <- STM.readTVarIO (envAbort env)
        flagAfter `shouldBe` True

  describe "processUserMessage" $ do

    it "persists the user message and drives one agentic round (via Mock)" $
      withTestEnv $ \env session -> do
        let scripted = [TextDelta "Hello, you!", StreamDone (Usage 3 4 Nothing Nothing)]
            streamer = staticStreamer scripted
        result <- runExceptT $ runReaderT
          (processUserMessageWith streamer (sessionModel session) (sessionId session) "hi there") env
        case result of
          Right () -> pure ()
          Left err -> expectationFailure (show err)
        msgs <- DB.getMessages (envDb env) (sessionId session)
        length msgs `shouldBe` 2     -- user + assistant
        msgRole (head msgs)         `shouldBe` RoleUser
        msgRole (msgs !! 1)         `shouldBe` RoleAssistant

  describe "agentic (tool error handling)" $ do

    it "sets isError = True when the tool dispatch fails" $
      withTestEnv $ \env session -> do
        -- Reference a tool that doesn't exist in the registry.
        let round1 =
              [ ToolCallStart "c1" "no_such_tool"
              , ToolCallArgDelta "c1" "{}"
              , ToolCallEnd "c1"
              , StreamDone (Usage 5 1 Nothing Nothing)
              ]
        streamer <- newScriptedStreamer [round1]
        result <- runExceptT $ runReaderT
          (agentic streamer (sessionModel session) (sessionId session) []) env
        case result of
          Right msgs -> do
            length msgs `shouldBe` 1
            let m = head msgs
                resultParts = [tr | ToolResultPart tr <- NE.toList (msgParts m)]
            length resultParts `shouldBe` 1
            isError (head resultParts) `shouldBe` True
            Text.unpack (content (head resultParts)) `shouldContain` "unknown tool"
          Left err -> expectationFailure (show err)

  describe "streamerForProvider" $ do
    it "returns a streamer when the OpenAI key is present" $
      isRight (streamerForProvider (cfgWith (Just (ApiKey "k")) Nothing) OpenAI)
        `shouldBe` True
    it "fails when the OpenAI key is absent" $
      isLeft (streamerForProvider (cfgWith Nothing Nothing) OpenAI) `shouldBe` True
    it "returns a streamer when the MiniMax key is present" $
      isRight (streamerForProvider (cfgWith Nothing (Just (ApiKey "k"))) MiniMax)
        `shouldBe` True
    it "fails when the MiniMax key is absent" $
      isLeft (streamerForProvider (cfgWith Nothing Nothing) MiniMax) `shouldBe` True
    it "fails when the Anthropic key is absent" $
      isLeft (streamerForProvider (cfgWith Nothing Nothing) Anthropic) `shouldBe` True
    it "returns a streamer when the Anthropic key is present" $
      isRight (streamerForProvider cfgAnthropic Anthropic) `shouldBe` True

  describe "buildRequest (model threading)" $
    it "uses the supplied model, not the config default" $
      withTestEnv $ \env _session ->
        reqModel (buildRequest env (ModelId Anthropic "claude-opus-4-5") [])
          `shouldBe` "claude-opus-4-5"

  where
    isToolCall (ToolCallPart _)     = True
    isToolCall _                    = False
    isToolResult (ToolResultPart _) = True
    isToolResult _                  = False

-- | A streamer that fully emits a write_file tool call, THEN flips the abort
-- flag, THEN emits one text delta. The fold processes the text delta, observes
-- the abort, and stops — so the (complete) tool call sits in the aborted prefix
-- and must be skipped by the text-only finalize path.
abortingAfterToolCall :: STM.TVar Bool -> FilePath -> Streamer
abortingAfterToolCall abortVar path _req = do
  Conduit.yield (ToolCallStart "c1" "write_file")
  Conduit.yield (ToolCallArgDelta "c1"
    (Text.pack ("{\"path\":\"" <> path <> "\",\"content\":\"x\"}")))
  Conduit.yield (ToolCallEnd "c1")
  liftIO (STM.atomically (STM.writeTVar abortVar True))
  Conduit.yield (TextDelta "after")
  Conduit.yield (StreamDone (Usage 1 1 Nothing Nothing))

removeIfExists :: FilePath -> IO ()
removeIfExists p = do
  e <- doesFileExist p
  when e (removeFile p)

-- | True when the list is non-empty and its last element equals the given one.
endsWith :: Eq a => a -> [a] -> Bool
endsWith x xs = not (null xs) && last xs == x

-- | A streamer that emits a complete write_file tool round, then flips the
-- abort flag AFTER the stream ends (before the next round would start). The
-- stream itself completes un-aborted, so round 1's tool runs; the
-- between-rounds abort check then stops the loop before round 2. The same
-- streamer is returned on every call, but the abort check prevents a 2nd call.
abortAfterToolRound :: STM.TVar Bool -> FilePath -> Streamer
abortAfterToolRound abortVar path _req = do
  Conduit.yield (ToolCallStart "c1" "write_file")
  Conduit.yield (ToolCallArgDelta "c1"
    (Text.pack ("{\"path\":\"" <> path <> "\",\"content\":\"y\"}")))
  Conduit.yield (ToolCallEnd "c1")
  Conduit.yield (StreamDone (Usage 1 1 Nothing Nothing))
  liftIO (STM.atomically (STM.writeTVar abortVar True))

-- ---------------------------------------------------------------------------
-- Helper: env with an empty in-memory DB (no starter session)
-- ---------------------------------------------------------------------------

cfgWith :: Maybe ApiKey -> Maybe ApiKey -> Config
cfgWith oa mm = Config
  { providers    = ProviderConfig
      { openaiKey = oa, anthropicKey = Nothing, minimaxKey = mm }
  , defaultModel = ModelId OpenAI "gpt-4o"
  }

cfgAnthropic :: Config
cfgAnthropic = Config
  { providers    = ProviderConfig
      { openaiKey = Nothing, anthropicKey = Just (ApiKey "k"), minimaxKey = Nothing }
  , defaultModel = ModelId Anthropic "claude-opus-4-5"
  }

withFreshEnv :: (AppEnv -> IO a) -> IO a
withFreshEnv action = bracket (openDb ":memory:") close $ \conn -> do
  chan     <- BChan.newBChan 100
  abortVar <- STM.newTVarIO False
  let cfg = Config
        { providers    = ProviderConfig
            { openaiKey    = Just (ApiKey "sk-test-stub")
            , anthropicKey = Nothing
            , minimaxKey   = Nothing
            }
        , defaultModel = ModelId OpenAI "gpt-4o"
        }
      env = AppEnv
        { envConfig    = cfg
        , envDb        = conn
        , envRegistry  = defaultBuiltinRegistry
        , envEventChan = chan
        , envAbort     = abortVar
        }
  action env
