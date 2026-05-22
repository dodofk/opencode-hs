-- | Application monad, environment, and top-level entry point.
module OpenCode.App
  ( -- * Monad
    AppM
  , AppEnv (..)
  , AppError (..)
    -- * Running
  , runAppM
  , runApp
  ) where

import Control.Monad.Except (ExceptT, runExceptT)
import Control.Monad.Reader (ReaderT, runReaderT)
import Data.Text (Text)

-- ---------------------------------------------------------------------------
-- AppM
-- ---------------------------------------------------------------------------

-- | The application monad: Reader over IO with typed errors.
--
-- @AppM a = AppEnv -> IO (Either AppError a)@
type AppM = ReaderT AppEnv (ExceptT AppError IO)

-- ---------------------------------------------------------------------------
-- Environment
-- ---------------------------------------------------------------------------

-- | Everything the application needs at runtime.
-- Components are added as milestones progress.
data AppEnv = AppEnv
  { -- placeholder until M1/M2 provide real fields
    envPlaceholder :: ()
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

-- | Top-level entry point — will be filled in during M8.
runApp :: IO ()
runApp = putStrLn "opencode-hs: not yet implemented"
