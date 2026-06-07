-- | Startup wiring for MCP servers: connect each enabled server, fold its tools
-- (and synthesized resource tools) into the registry, and collect diagnostics
-- for servers that fail to start. Shutdown is the caller's responsibility (via
-- 'bracket' in 'OpenCode.Run').
module OpenCode.MCP.Startup
  ( McpDiagnostic (..)
  , startMcp
  , mcpRegistryAdditions
  ) where

import Data.Text (Text)

import OpenCode.Config (Config (..), McpServerConfig (..))
import OpenCode.MCP.Adapters (clientSomeTools)
import OpenCode.MCP.Client (McpClient, connect, renderMcpError)
import OpenCode.Tool.Types (ToolRegistry, registerTool)

data McpDiagnostic = McpDiagnostic
  { mdServer :: Text, mdReason :: Text }
  deriving stock (Show, Eq)

-- | Connect every enabled server. Returns the live clients and a diagnostic per
-- server that failed (skipped). Never throws.
startMcp :: Config -> IO ([McpClient], [McpDiagnostic])
startMcp cfg = go (filter (mcsEnabled . snd) (mcpServers cfg)) [] []
  where
    go [] cs ds = pure (reverse cs, reverse ds)
    go ((name, sc) : rest) cs ds = do
      r <- connect name sc
      case r of
        Right c -> go rest (c : cs) ds
        Left e  -> go rest cs (McpDiagnostic name (renderMcpError e) : ds)

-- | Fold every client's tools (real + synthesized resource tools) into a
-- registry. Precedence on a name clash: MCP tools are inserted over @reg0@, so
-- an MCP tool overrides a same-named built-in, and the first client (then a
-- real tool over its synthesized resource tools) wins. Names are namespaced
-- @\<server>_\<tool>@, so clashes are unlikely in practice.
mcpRegistryAdditions :: [McpClient] -> ToolRegistry -> ToolRegistry
mcpRegistryAdditions cs reg0 =
  foldr registerTool reg0 (concatMap clientSomeTools cs)
