{-# LANGUAGE OverloadedStrings #-}
-- | Shared test harness for the in-repo @opencode-mcp-mock@ stdio server:
-- locate the built executable and run an action against a connected client.
module OpenCode.McpMock
  ( mockServerPath
  , withMock
  ) where

import Control.Exception (bracket)
import qualified Data.Text as T
import System.Directory (doesFileExist)
import System.Environment (lookupEnv)
import System.FilePath ((</>))

import Paths_opencode_hs (getBinDir)
import OpenCode.Config (McpServerConfig (..))
import OpenCode.MCP.Client (McpClient, connect, renderMcpError, shutdown)

-- | Locate the built mock server: honor OPENCODE_MCP_MOCK, else look in the
-- package's bin dir (stack builds executables before running the test suite).
mockServerPath :: IO (Maybe FilePath)
mockServerPath = do
  override <- lookupEnv "OPENCODE_MCP_MOCK"
  case override of
    Just p  -> pure (Just p)
    Nothing -> do
      bin <- getBinDir
      let p = bin </> "opencode-mcp-mock"
      ok <- doesFileExist p
      pure (if ok then Just p else Nothing)

-- | Connect to the mock server, run an action with the live client, and shut
-- the server down afterwards ('bracket'-style).
withMock :: (McpClient -> IO a) -> IO a
withMock k = do
  mp <- mockServerPath
  case mp of
    Nothing   -> error "opencode-mcp-mock not found (build it with `stack build`)"
    Just path -> do
      let cfg = McpServerConfig { mcsCommand = path, mcsArgs = [], mcsEnv = [], mcsEnabled = True }
      r <- connect "mock" cfg
      case r of
        Left e  -> error ("mock connect failed: " <> T.unpack (renderMcpError e))
        Right c -> bracket (pure c) shutdown k
