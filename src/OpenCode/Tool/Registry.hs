-- | The default built-in tool registry.
-- Aggregates the three M5 file-I/O tools; M7 will extend this with bash, glob, grep.
module OpenCode.Tool.Registry
  ( defaultBuiltinRegistry
  ) where

import OpenCode.Tool.EditFile (editFileTool)
import OpenCode.Tool.ReadFile (readFileTool)
import OpenCode.Tool.Types (ToolRegistry, emptyRegistry, registerTool)
import OpenCode.Tool.WriteFile (writeFileTool)

defaultBuiltinRegistry :: ToolRegistry
defaultBuiltinRegistry =
    registerTool readFileTool
  $ registerTool writeFileTool
  $ registerTool editFileTool emptyRegistry
