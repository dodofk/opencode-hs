module OpenCode.SessionSpec (spec) where

import qualified Brick.BChan as BChan
import Control.Exception (bracket)
import qualified Control.Concurrent.STM as STM
import Control.Monad.Except (runExceptT)
import Control.Monad.Reader (runReaderT)
import Database.SQLite.Simple (close)
import Test.Hspec

import OpenCode.App (AppEnv (..))
import OpenCode.Config (Config (..), ProviderConfig (..))
import OpenCode.DB (openDb)
import OpenCode.Session (createSession, loadSession)
import OpenCode.Tool.Registry (defaultBuiltinRegistry)
import OpenCode.Types
  ( ApiKey (..)
  , ModelId (..)
  , ProviderId (..)
  , Session (..)
  , SessionId (..)
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
