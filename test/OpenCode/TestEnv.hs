-- | Shared test fixture: an 'AppEnv' backed by an in-memory SQLite DB, the
-- default builtin tool registry, a fresh 'BChan', and a fresh abort 'TVar'.
-- Used by the session-loop tests so each spec gets a clean environment.
module OpenCode.TestEnv
  ( withTestEnv
  ) where

import qualified Brick.BChan as BChan
import Control.Exception (bracket)
import qualified Control.Concurrent.STM as STM
import Data.Time (UTCTime (..), fromGregorian)
import Database.SQLite.Simple (close)

import OpenCode.App (AppEnv (..))
import OpenCode.Config (Config (..), ProviderConfig (..))
import OpenCode.DB (insertSession, newSessionId, openDb)
import OpenCode.Tool.Registry (defaultBuiltinRegistry)
import OpenCode.Types
  ( ApiKey (..)
  , ModelId (..)
  , ProviderId (..)
  , Session (..)
  )

-- | Set up an in-memory environment, create a starter session, run the
-- caller's action, then tear down. The caller gets the env and the
-- starter session.
withTestEnv :: (AppEnv -> Session -> IO a) -> IO a
withTestEnv action = bracket (openDb ":memory:") close $ \conn -> do
  chan     <- BChan.newBChan 100
  abortVar <- STM.newTVarIO False
  sid      <- newSessionId
  let cfg = Config
        { providers    = ProviderConfig
            { openaiKey    = Just (ApiKey "sk-test-stub")
            , anthropicKey = Nothing
            }
        , defaultModel = ModelId OpenAI "gpt-4o"
        }
      session = Session
        { sessionId      = sid
        , sessionTitle   = "test session"
        , sessionModel   = ModelId OpenAI "gpt-4o"
        , sessionCreated = UTCTime (fromGregorian 2026 5 24) 0
        }
  insertSession conn session
  let env = AppEnv
        { envConfig    = cfg
        , envDb        = conn
        , envRegistry  = defaultBuiltinRegistry
        , envEventChan = chan
        , envAbort     = abortVar
        }
  action env session
