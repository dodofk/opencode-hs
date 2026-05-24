-- | Application monad, environment, and top-level entry point.
-- This module re-exports the leaf types from 'OpenCode.App.Error' and
-- 'OpenCode.App.Types' so consumers can keep using 'OpenCode.App' as a
-- single entry point, while the leaf modules remain dependency-free of
-- 'OpenCode.Tool.*'.
module OpenCode.App
  ( -- * Re-exports
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
  , askExecuteTool
  ) where

import Control.Exception (SomeException, try)
import Control.Monad.Except (runExceptT, throwError)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Reader (asks, runReaderT)
import qualified Data.Aeson as Aeson
import qualified Data.Text as Text

import OpenCode.App.Error (AppError (..))
import OpenCode.App.Types (AppEnv (..), AppM)
import OpenCode.Config (Config)
import qualified OpenCode.Tool.Types as Tool

runAppM :: AppEnv -> AppM a -> IO (Either AppError a)
runAppM env action = runExceptT (runReaderT action env)

-- | Top-level entry point — CLI dispatch added in M8.
runApp :: IO ()
runApp = putStrLn "opencode-hs: not yet implemented"

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

-- | Dispatch a tool call by name, decoding the JSON arguments and rendering
-- the output. Reads the registry from 'envRegistry' so callers don't have to
-- thread it explicitly. Raises 'ToolError' on unknown name or decode failure.
askExecuteTool :: Text.Text -> Aeson.Value -> AppM Text.Text
askExecuteTool name args = do
  reg <- asks envRegistry
  Tool.executeTool reg name args
