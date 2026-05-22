-- | MCP (Model Context Protocol) client adapter.
-- Connects to stdio MCP servers and merges their tools into the registry.
module OpenCode.MCP
  ( McpClient (..)
  , connectMcpStdio
  ) where

import Data.Text (Text)
import OpenCode.Tool.Types (SomeTool)

-- ---------------------------------------------------------------------------
-- Types
-- ---------------------------------------------------------------------------

data McpClient = McpClient
  { listTools :: IO [SomeTool]
  , callTool  :: Text -> Text -> IO Text   -- ^ name args -> result
  }

-- ---------------------------------------------------------------------------
-- Stub (implemented in M6)
-- ---------------------------------------------------------------------------

connectMcpStdio :: FilePath -> [Text] -> IO McpClient
connectMcpStdio _ _ = error "OpenCode.MCP.connectMcpStdio: not yet implemented"
