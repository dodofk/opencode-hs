module OpenCode.SessionSpec (spec) where

import qualified Brick.BChan as BChan
import Control.Exception (bracket)
import qualified Control.Concurrent.STM as STM
import Control.Monad.Except (runExceptT)
import Control.Monad.Reader (runReaderT)
import Database.SQLite.Simple (close)
import Test.Hspec
import qualified Data.List.NonEmpty as NE

import OpenCode.App (AppEnv (..))
import OpenCode.Config (Config (..), ProviderConfig (..))
import qualified OpenCode.DB as DB
import OpenCode.DB (openDb)
import OpenCode.LLM.Mock (staticStreamer, newScriptedStreamer)
import OpenCode.Session (agentic, createSession, loadSession, abortSession, processUserMessage, processUserMessageWith)
import OpenCode.TestEnv (withTestEnv)
import OpenCode.Tool.Registry (defaultBuiltinRegistry)
import OpenCode.Types
  ( ApiKey (..)
  , MessagePart (..)
  , ModelId (..)
  , ProviderId (..)
  , Role (..)
  , Session (..)
  , SessionId (..)
  , StreamEvent (..)
  , Usage (..)
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
          (agentic streamer (sessionId session) []) env
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
          (agentic streamer (sessionId session) []) env
        stored <- DB.getMessages (envDb env) (sessionId session)
        length stored `shouldBe` 1
        msgRole (head stored) `shouldBe` RoleAssistant

  describe "agentic (with tool execution, multi-round)" $ do

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
          (agentic streamer (sessionId session) []) env
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

    it "stops after the current round when envAbort is set" $
      withTestEnv $ \env session -> do
        -- Set the abort flag BEFORE invoking agentic.
        STM.atomically $ STM.writeTVar (envAbort env) True
        -- Script two rounds: round 1 has a tool call (would normally trigger
        -- recursion); round 2 has text. With abort set, round 2 must not run.
        let round1 =
              [ ToolCallStart "c1" "write_file"
              , ToolCallArgDelta "c1" "{\"path\":\"/tmp/m6-abort.txt\",\"content\":\"a\"}"
              , ToolCallEnd "c1"
              , StreamDone (Usage 10 5 Nothing Nothing)
              ]
            round2 =
              [ TextDelta "should not appear"
              , StreamDone (Usage 1 1 Nothing Nothing)
              ]
        streamer <- newScriptedStreamer [round1, round2]
        result <- runExceptT $ runReaderT
          (agentic streamer (sessionId session) []) env
        case result of
          Right msgs ->
            -- Only round 1's assistant message should be present.
            length msgs `shouldBe` 1
          Left err -> expectationFailure (show err)

    it "abortSession sets the envAbort flag" $
      withTestEnv $ \env _session -> do
        before <- STM.readTVarIO (envAbort env)
        before `shouldBe` False
        _ <- runExceptT $ runReaderT abortSession env
        after <- STM.readTVarIO (envAbort env)
        after `shouldBe` True

  describe "processUserMessage" $ do

    it "persists the user message and drives one agentic round (via Mock)" $
      withTestEnv $ \env session -> do
        let scripted = [TextDelta "Hello, you!", StreamDone (Usage 3 4 Nothing Nothing)]
            streamer = staticStreamer scripted
        result <- runExceptT $ runReaderT
          (processUserMessageWith streamer (sessionId session) "hi there") env
        case result of
          Right () -> pure ()
          Left err -> expectationFailure (show err)
        msgs <- DB.getMessages (envDb env) (sessionId session)
        length msgs `shouldBe` 2     -- user + assistant
        msgRole (head msgs)         `shouldBe` RoleUser
        msgRole (msgs !! 1)         `shouldBe` RoleAssistant

  where
    isToolCall (ToolCallPart _)     = True
    isToolCall _                    = False
    isToolResult (ToolResultPart _) = True
    isToolResult _                  = False

-- ---------------------------------------------------------------------------
-- Helper: env with an empty in-memory DB (no starter session)
-- ---------------------------------------------------------------------------

withFreshEnv :: (AppEnv -> IO a) -> IO a
withFreshEnv action = bracket (openDb ":memory:") close $ \conn -> do
  chan     <- BChan.newBChan 100
  abortVar <- STM.newTVarIO False
  let cfg = Config
        { providers    = ProviderConfig
            { openaiKey    = Just (ApiKey "sk-test-stub")
            , anthropicKey = Nothing
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
