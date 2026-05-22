-- | Application monad, environment, and top-level entry point.
module OpenCode.App
  ( -- * Monad
    AppM
  , AppEnv (..)
  , AppError (..)
    -- * Running
  , runAppM
  , runApp
    -- * Helpers
  , liftIO'
  , throwAppError
  , askConfig
  ) where

import Control.Exception (SomeException, try)
import Control.Monad.Except (ExceptT, runExceptT, throwError)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Reader (ReaderT, asks, runReaderT)
import Data.Text (Text)
import Data.Text qualified as Text
import OpenCode.Config (Config)

-- ---------------------------------------------------------------------------
-- AppM
-- ---------------------------------------------------------------------------

-- | The application monad: @ReaderT AppEnv (ExceptT AppError IO)@.
--
-- Using a concrete transformer stack (not MTL typeclasses) keeps error
-- messages and instance resolution simple.
type AppM = ReaderT AppEnv (ExceptT AppError IO)

-- ---------------------------------------------------------------------------
-- Environment
--
-- Fields are added one per milestone:
--   M1: envConfig
--   M2: envDb
--   M4: envRegistry
--   M5: envEventChan, envAbort
-- ---------------------------------------------------------------------------

data AppEnv = AppEnv
  { envConfig :: Config
  -- envDb      :: Connection      -- added in M2
  -- envRegistry :: ToolRegistry   -- added in M4
  -- envEventChan :: BChan …       -- added in M5
  -- envAbort     :: TVar Bool     -- added in M5
  }

-- ---------------------------------------------------------------------------
-- Errors
-- ---------------------------------------------------------------------------

data AppError
  = ConfigError Text
  | LLMError Text
  | ToolError Text Text   -- ^ tool name, message
  | DatabaseError Text
  | MCPError Text
  | UnexpectedError Text
  deriving stock (Show, Eq)

-- ---------------------------------------------------------------------------
-- Runners
-- ---------------------------------------------------------------------------

runAppM :: AppEnv -> AppM a -> IO (Either AppError a)
runAppM env action = runExceptT (runReaderT action env)

-- | Top-level entry point — CLI dispatch added in M8.
runApp :: IO ()
runApp = putStrLn "opencode-hs: not yet implemented"

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

-- | Lift an IO action, converting any synchronous exception into
-- 'UnexpectedError' so it stays within the typed error channel.
liftIO' :: IO a -> AppM a
liftIO' action = do
  result <- liftIO (try @SomeException action)
  case result of
    Left  ex -> throwError (UnexpectedError (Text.pack (show ex)))
    Right a  -> pure a

-- | Lift a typed error into 'AppM'.
throwAppError :: AppError -> AppM a
throwAppError = throwError

-- | Read the 'Config' from the environment.
askConfig :: AppM Config
askConfig = asks envConfig
