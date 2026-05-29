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

import qualified Brick.BChan as BChan
import qualified Control.Concurrent.STM as STM
import Control.Exception (SomeException, try)
import Control.Monad.Except (runExceptT, throwError)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Reader (asks, runReaderT)
import qualified Data.Aeson as Aeson
import qualified Data.Text as Text
import Data.Time (getCurrentTime)
import Database.SQLite.Simple (Connection)
import System.Environment (getArgs)

import OpenCode.App.Error (AppError (..))
import OpenCode.App.Types (AppEnv (..), AppM)
import OpenCode.Config (Config (..), loadConfig)
import qualified OpenCode.DB as DB
import qualified OpenCode.Tool.Types as Tool
import OpenCode.TUI.App (startTUI)
import OpenCode.Types
  ( ModelId
  , Session (..)
  )

runAppM :: AppEnv -> AppM a -> IO (Either AppError a)
runAppM env action = runExceptT (runReaderT action env)

-- | Top-level entry point. With no CLI arguments, launch the TUI on a fresh
-- session (M8). Full subcommand parsing arrives in M10.
--
-- The tool registry is supplied by the caller ('app/Main.hs') because
-- 'OpenCode.Tool.Registry' transitively depends on this module.
runApp :: Tool.ToolRegistry -> IO ()
runApp registry = do
  args <- getArgs
  case args of
    [] -> launchTUI registry
    _  -> putStrLn
      "opencode-hs: CLI commands arrive in M10. Run with no arguments for the TUI."

-- | Build a fresh 'AppEnv', mint a new session, and hand off to the TUI.
launchTUI :: Tool.ToolRegistry -> IO ()
launchTUI registry = do
  cfgResult <- loadConfig
  case cfgResult of
    Left err  -> putStrLn ("opencode-hs: config error: " <> show err)
    Right cfg -> do
      dbPath   <- DB.defaultDbPath
      conn     <- DB.openDb dbPath
      chan     <- BChan.newBChan 100
      abortVar <- STM.newTVarIO False
      let env = AppEnv
            { envConfig    = cfg
            , envDb        = conn
            , envRegistry  = registry
            , envEventChan = chan
            , envAbort     = abortVar
            }
      session <- newSession conn (defaultModel cfg)
      startTUI env session

-- | Create and persist a new "untitled" session. Mirrors
-- 'OpenCode.Session.createSession' but lives here to avoid an import cycle
-- (@OpenCode.Session@ depends on this module).
newSession :: Connection -> ModelId -> IO Session
newSession conn m = do
  sid <- DB.newSessionId
  now <- getCurrentTime
  let session = Session
        { sessionId      = sid
        , sessionTitle   = "untitled"
        , sessionModel   = m
        , sessionCreated = now
        }
  DB.insertSession conn session
  pure session

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
