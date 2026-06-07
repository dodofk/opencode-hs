-- | Application monad and environment. Depends on Tool.Types for the
-- registry; lives in a sibling-of-App module so Tool/* can import the
-- monad type (via 'AppM' re-exported from 'OpenCode.App') without a cycle.
module OpenCode.App.Types
  ( AppM
  , AppEnv (..)
  ) where

import Brick.BChan (BChan)
import Control.Concurrent.STM (TVar)
import Control.Monad.Except (ExceptT)
import Control.Monad.Reader (ReaderT)
import Database.SQLite.Simple (Connection)

import OpenCode.App.Error (AppError)
import OpenCode.Config (Config)
import OpenCode.MCP.Client (McpClient)
import OpenCode.Session.Events (SessionEvent)
import OpenCode.Tool.Types (ToolRegistry)

type AppM = ReaderT AppEnv (ExceptT AppError IO)

data AppEnv = AppEnv
  { envConfig    :: Config
  , envDb        :: Connection
  , envRegistry  :: ToolRegistry
  , envEventChan :: BChan SessionEvent
  , envAbort     :: TVar Bool
  , envMcp       :: [McpClient]
  }
