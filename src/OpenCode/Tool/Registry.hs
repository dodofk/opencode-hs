-- | The default built-in tool registry.
-- Aggregates all built-in tools (file, bash, glob, grep, web, github).
module OpenCode.Tool.Registry
  ( defaultBuiltinRegistry
  ) where

import OpenCode.Tool.Bash (bashTool)
import OpenCode.Tool.EditFile (editFileTool)
import OpenCode.Tool.GitHubFile (githubFileTool)
import OpenCode.Tool.GitHubIssue (githubIssueTool)
import OpenCode.Tool.GitHubSearch (githubSearchTool)
import OpenCode.Tool.Glob (globTool)
import OpenCode.Tool.Grep (grepTool)
import OpenCode.Tool.ReadFile (readFileTool)
import OpenCode.Tool.Types (ToolRegistry, emptyRegistry, registerTool)
import OpenCode.Tool.WebFetch (webFetchTool)
import OpenCode.Tool.WebSearch (webSearchTool)
import OpenCode.Tool.WriteFile (writeFileTool)

defaultBuiltinRegistry :: ToolRegistry
defaultBuiltinRegistry =
    registerTool readFileTool
  $ registerTool writeFileTool
  $ registerTool editFileTool
  $ registerTool bashTool
  $ registerTool globTool
  $ registerTool grepTool
  $ registerTool webSearchTool
  $ registerTool webFetchTool
  $ registerTool githubSearchTool
  $ registerTool githubIssueTool
  $ registerTool githubFileTool emptyRegistry
