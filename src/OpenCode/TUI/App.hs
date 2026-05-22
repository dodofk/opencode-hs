-- | Brick App definition, event handling, and TUI entry point.
module OpenCode.TUI.App
  ( startTUI
  ) where

import OpenCode.App (AppEnv)
import OpenCode.Types (SessionId)

-- | Start the brick TUI for an existing session.
-- Implemented in M7.
startTUI :: AppEnv -> SessionId -> IO ()
startTUI _ _ = error "OpenCode.TUI.App.startTUI: not yet implemented"
