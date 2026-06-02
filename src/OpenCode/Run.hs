-- | Top-level application wiring. Sits above 'OpenCode.App', 'OpenCode.Session',
-- and the TUI so it can build the environment and launch the interface without
-- inducing an import cycle — which is why this logic no longer lives in
-- 'OpenCode.App'.
module OpenCode.Run
  ( runApp
  ) where

import qualified Brick.BChan as BChan
import qualified Control.Concurrent.STM as STM
import System.Environment (getArgs)

import OpenCode.App (AppEnv (..), runAppM)
import OpenCode.Config (Config (..), loadConfig)
import qualified OpenCode.DB as DB
import OpenCode.Session (createSession)
import qualified OpenCode.Tool.Types as Tool
import OpenCode.TUI.App (startTUI)

-- | Entry point. No CLI arguments → launch the TUI on a fresh session (M8/M9).
-- Full subcommand parsing arrives in M10.
runApp :: Tool.ToolRegistry -> IO ()
runApp registry = do
  args <- getArgs
  case args of
    [] -> launchTUI registry
    _  -> putStrLn
      "opencode-hs: CLI commands arrive in M10. Run with no arguments for the TUI."

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
      sessionResult <- runAppM env (createSession (defaultModel cfg))
      case sessionResult of
        Left err      -> putStrLn ("opencode-hs: session error: " <> show err)
        Right session -> startTUI env session
