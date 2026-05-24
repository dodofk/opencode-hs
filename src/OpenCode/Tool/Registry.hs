-- | The default built-in tool registry.
-- Aggregates all 6 M5+M7 built-in tools (read/write/edit file, bash, glob, grep).
module OpenCode.Tool.Registry
  ( defaultBuiltinRegistry
  ) where

import OpenCode.Tool.Bash (bashTool)
import OpenCode.Tool.EditFile (editFileTool)
import OpenCode.Tool.Glob (globTool)
import OpenCode.Tool.Grep (grepTool)
import OpenCode.Tool.ReadFile (readFileTool)
import OpenCode.Tool.Types (ToolRegistry, emptyRegistry, registerTool)
import OpenCode.Tool.WriteFile (writeFileTool)

defaultBuiltinRegistry :: ToolRegistry
defaultBuiltinRegistry =
    registerTool readFileTool
  $ registerTool writeFileTool
  $ registerTool editFileTool
  $ registerTool bashTool
  $ registerTool globTool
  $ registerTool grepTool emptyRegistry
