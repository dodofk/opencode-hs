-- | Tool: read a file (or a line range within it).
module OpenCode.Tool.ReadFile
  ( readFileTool
  ) where

import Data.Text (Text)
import OpenCode.Tool.Types (SomeTool)

-- | 'SomeTool' entry for the read_file tool.
-- Implemented in M4.
readFileTool :: SomeTool
readFileTool = error "OpenCode.Tool.ReadFile.readFileTool: not yet implemented"

_suppress :: Text
_suppress = "placeholder"
