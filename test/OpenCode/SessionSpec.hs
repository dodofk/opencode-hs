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
import OpenCode.LLM.Mock (staticStreamer)
import OpenCode.Session (agentic, createSession, loadSession)
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
