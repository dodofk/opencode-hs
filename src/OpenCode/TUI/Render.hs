-- | Brick draw functions: convert AppState into a list of Widgets.
module OpenCode.TUI.Render
  ( drawUI
  ) where

import Brick (Widget)
import OpenCode.TUI.Types (AppState (..), ResourceName)

-- | Top-level draw function passed to 'Brick.Main.App'.
-- Implemented in M7.
drawUI :: AppState -> [Widget ResourceName]
drawUI _ = []
