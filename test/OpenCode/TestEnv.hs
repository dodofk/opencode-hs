-- | Shared test fixture: an 'AppEnv' backed by an in-memory SQLite DB, the
-- default builtin tool registry, a fresh 'BChan', and a fresh abort 'TVar'.
-- Used by the session-loop tests so each spec gets a clean environment.
module OpenCode.TestEnv
  ( withTestEnv
  , drainBChan
  , newDummyEnv
  , newDummyEnvNoKey
  ) where

import qualified Brick.BChan as BChan
import Control.Exception (bracket)
import qualified Control.Concurrent.STM as STM
import Data.Time (UTCTime (..), fromGregorian)
import Database.SQLite.Simple (close)
import System.Timeout (timeout)

import OpenCode.App (AppEnv (..))
import OpenCode.Config (Config (..), ProviderConfig (..), ToolsConfig (..))
import OpenCode.DB (insertSession, newSessionId, openDb)
import OpenCode.Net.Http (runHttp)
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
            , minimaxKey   = Nothing
            }
        , defaultModel = ModelId OpenAI "gpt-4o"
        , mcpServers   = []
        , tools        = ToolsConfig Nothing Nothing
        }
      session = Session
        { sessionId      = sid
        , sessionTitle   = "test session"
        , sessionModel   = ModelId OpenAI "gpt-4o"
        , sessionCreated = UTCTime (fromGregorian 2026 5 24) 0
        }
  insertSession conn session
  let env = AppEnv
        { envConfig      = cfg
        , envDb          = conn
        , envRegistry    = defaultBuiltinRegistry
        , envEventChan   = chan
        , envAbort       = abortVar
        , envMcp         = []
        , envSkills      = []
        , envHttpBackend = runHttp
        , envTools       = ToolsConfig Nothing Nothing
        }
  action env session

-- | Drain every currently-buffered event from a 'BChan' without blocking
-- forever: read until a short timeout elapses with the channel empty. Callers
-- run the producer to completion *before* draining, so all events are already
-- present and the timeout only detects "empty".
drainBChan :: BChan.BChan a -> IO [a]
drainBChan chan = go []
  where
    go acc = do
      m <- timeout 100000 (BChan.readBChan chan)   -- 100ms
      case m of
        Just x  -> go (x : acc)
        Nothing -> pure (reverse acc)

-- | A non-bracketed in-memory 'AppEnv' for pure-state tests. The :memory:
-- connection is intentionally left open (reclaimed at process exit); the pure
-- functions under test never touch it. Pass the OpenAI key to include.
mkDummyEnv :: Maybe ApiKey -> IO AppEnv
mkDummyEnv mkey = do
  conn     <- openDb ":memory:"
  chan     <- BChan.newBChan 100
  abortVar <- STM.newTVarIO False
  let cfg = Config
        { providers    = ProviderConfig
            { openaiKey = mkey, anthropicKey = Nothing, minimaxKey = Nothing }
        , defaultModel = ModelId OpenAI "gpt-4o"
        , mcpServers   = []
        , tools        = ToolsConfig Nothing Nothing
        }
  pure AppEnv
    { envConfig    = cfg
    , envDb        = conn
    , envRegistry  = defaultBuiltinRegistry
    , envEventChan = chan
    , envAbort     = abortVar
    , envMcp         = []
    , envSkills      = []
    , envHttpBackend = runHttp
    , envTools       = ToolsConfig Nothing Nothing
    }

-- | Dummy env with a (stub) OpenAI key present.
newDummyEnv :: IO AppEnv
newDummyEnv = mkDummyEnv (Just (ApiKey "sk-test-stub"))

-- | Dummy env with no provider keys (drives the "no API key" error path).
newDummyEnvNoKey :: IO AppEnv
newDummyEnvNoKey = mkDummyEnv Nothing
