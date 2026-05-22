-- | Tool: search file contents (ripgrep or fallback).
module OpenCode.Tool.Grep
  ( grepTool
  ) where

import Data.Text (Text)
import OpenCode.Tool.Types (SomeTool)

grepTool :: SomeTool
grepTool = error "OpenCode.Tool.Grep.grepTool: not yet implemented"

_suppress :: Text
_suppress = "placeholder"
