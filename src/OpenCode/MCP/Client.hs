{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE OverloadedStrings #-}

-- | A minimal MCP client over stdio: spawn a server process, perform the
-- @initialize@ handshake, and make @tools/call@ / @resources/read@ /
-- @prompts/get@ requests. Newline-delimited JSON-RPC. One 'MVar' serializes
-- request/response per server; calls are wrapped in a per-call timeout.
module OpenCode.MCP.Client
  ( McpError (..)
  , renderMcpError
  , McpClient (..)
  , connect
  , callTool
  , readResource
  , getPrompt
  , shutdown
  ) where

import Control.Concurrent (forkIO)
import Control.Concurrent.MVar (MVar, newMVar, withMVar)
import Control.Exception (SomeException, catch, try)
import Control.Monad (void)
import Data.Aeson (FromJSON, Value, object, (.=))
import qualified Data.Aeson as Aeson
import qualified Data.Aeson.Key as Key
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BL
import Data.Bifunctor (bimap)
import Data.Either (fromRight)
import Data.IORef (IORef, atomicModifyIORef', newIORef)
import Data.Text (Text)
import qualified Data.Text as T
import System.Environment (getEnvironment)
import System.IO
  ( BufferMode (LineBuffering), Handle, hClose, hFlush, hIsEOF, hSetBuffering )
import System.Process
  ( CreateProcess (..), ProcessHandle, StdStream (CreatePipe)
  , createProcess, proc, terminateProcess, waitForProcess )
import System.Timeout (timeout)

import OpenCode.Config (McpServerConfig (..))
import OpenCode.MCP.Protocol

-- | Per-call timeout (microseconds): 30 seconds.
callTimeoutMicros :: Int
callTimeoutMicros = 30 * 1000000

data McpError
  = SpawnFailed Text
  | HandshakeFailed Text
  | CallTimeout Text
  | CallFailed Text
  deriving stock (Show, Eq)

renderMcpError :: McpError -> Text
renderMcpError = \case
  SpawnFailed m     -> "spawn failed: " <> m
  HandshakeFailed m -> "handshake failed: " <> m
  CallTimeout m     -> "timed out: " <> m
  CallFailed m      -> m

data McpClient = McpClient
  { mcName      :: Text
  , mcCaps      :: McpCapabilities
  , mcTools     :: [McpToolDef]
  , mcResources :: [McpResource]
  , mcPrompts   :: [McpPrompt]
  , mcIn        :: Handle
  , mcOut       :: Handle
  , mcProc      :: ProcessHandle
  , mcLock      :: MVar ()
  , mcNextId    :: IORef Int
  }

-- ---------------------------------------------------------------------------
-- Connect / handshake
-- ---------------------------------------------------------------------------

connect :: Text -> McpServerConfig -> IO (Either McpError McpClient)
connect name cfg = do
  spawned <- try (spawnServer cfg)
  case (spawned :: Either SomeException (Handle, Handle, Handle, ProcessHandle)) of
    Left e -> pure (Left (SpawnFailed (T.pack (show e))))
    Right (hin, hout, herr, ph) -> do
      hSetBuffering hin LineBuffering
      _    <- forkIO (drainHandle herr)
      lock <- newMVar ()
      idr  <- newIORef 0
      let base = McpClient name emptyCaps [] [] [] hin hout ph lock idr
      r <- try (handshake base)
      case (r :: Either SomeException (Either McpError McpClient)) of
        Left e          -> killProc ph hin hout >> pure (Left (HandshakeFailed (T.pack (show e))))
        Right (Left er) -> killProc ph hin hout >> pure (Left er)
        Right (Right c) -> pure (Right c)

spawnServer :: McpServerConfig -> IO (Handle, Handle, Handle, ProcessHandle)
spawnServer cfg = do
  parentEnv <- getEnvironment
  let cp = (proc (mcsCommand cfg) (map T.unpack (mcsArgs cfg)))
        { std_in  = CreatePipe
        , std_out = CreatePipe
        , std_err = CreatePipe
        , env     = Just (mergeEnv parentEnv (mcsEnv cfg))
        }
  (mIn, mOut, mErr, ph) <- createProcess cp
  case (mIn, mOut, mErr) of
    (Just hin, Just hout, Just herr) -> pure (hin, hout, herr, ph)
    _ -> ioError (userError "createProcess did not return all pipes")

mergeEnv :: [(String, String)] -> [(Text, Text)] -> [(String, String)]
mergeEnv parent overrides =
  let ov     = map (bimap T.unpack T.unpack) overrides
      ovKeys = map fst ov
  in filter ((`notElem` ovKeys) . fst) parent ++ ov

handshake :: McpClient -> IO (Either McpError McpClient)
handshake c = do
  let initParams = object
        [ "protocolVersion" .= ("2024-11-05" :: Text)
        , "capabilities"    .= object []
        , "clientInfo"      .= object
            [ "name" .= ("opencode-hs" :: Text), "version" .= ("0.1" :: Text) ]
        ]
  ir <- call c "initialize" initParams
  case ir of
    Left e        -> pure (Left e)
    Right resVal  -> case Aeson.fromJSON resVal :: Aeson.Result InitializeResult of
      Aeson.Error msg       -> pure (Left (HandshakeFailed (T.pack msg)))
      Aeson.Success initRes -> do
        sendNotification c "notifications/initialized" (object [])
        let caps = initCapabilities initRes
        tools <- if capTools caps
                   then listOrEmpty (call c "tools/list" (object [])) decodeToolsList
                   else pure []
        ress  <- if capResources caps
                   then listOrEmpty (call c "resources/list" (object [])) decodeResourcesList
                   else pure []
        prms  <- if capPrompts caps
                   then listOrEmpty (call c "prompts/list" (object [])) decodePromptsList
                   else pure []
        pure (Right c { mcCaps = caps, mcTools = tools, mcResources = ress, mcPrompts = prms })

-- | Run a list call; an error or decode failure degrades to an empty list (a
-- broken list endpoint must not fail the whole handshake).
listOrEmpty :: IO (Either McpError Value) -> (Value -> Either Text [a]) -> IO [a]
listOrEmpty act decode = do
  r <- act
  pure $ case r of
    Left _  -> []
    Right v -> fromRight [] (decode v)

-- ---------------------------------------------------------------------------
-- Typed requests
-- ---------------------------------------------------------------------------

callTool :: McpClient -> Text -> Value -> IO (Either McpError CallToolResult)
callTool c name args = do
  r <- call c "tools/call" (object ["name" .= name, "arguments" .= args])
  pure (r >>= decodeAs "tools/call")

readResource :: McpClient -> Text -> IO (Either McpError ReadResourceResult)
readResource c uri = do
  r <- call c "resources/read" (object ["uri" .= uri])
  pure (r >>= decodeAs "resources/read")

getPrompt :: McpClient -> Text -> [(Text, Text)] -> IO (Either McpError GetPromptResult)
getPrompt c name args = do
  let argObj = object [ Key.fromText k .= v | (k, v) <- args ]
  r <- call c "prompts/get" (object ["name" .= name, "arguments" .= argObj])
  pure (r >>= decodeAs "prompts/get")

decodeAs :: FromJSON a => Text -> Value -> Either McpError a
decodeAs ctx v = case Aeson.fromJSON v of
  Aeson.Error e   -> Left (CallFailed (ctx <> ": " <> T.pack e))
  Aeson.Success a -> Right a

-- ---------------------------------------------------------------------------
-- Low-level request/response
-- ---------------------------------------------------------------------------

call :: McpClient -> Text -> Value -> IO (Either McpError Value)
call c method params = withMVar (mcLock c) $ \_ -> do
  i <- atomicModifyIORef' (mcNextId c) (\n -> (n + 1, n + 1))
  res <- timeout callTimeoutMicros $ do
    BL.hPut (mcIn c) (encodeRequest (JsonRpcRequest i method params) <> "\n")
    hFlush (mcIn c)
    awaitResponse c i
  pure $ case res of
    Nothing        -> Left (CallTimeout method)
    Just outcome   -> outcome

awaitResponse :: McpClient -> Int -> IO (Either McpError Value)
awaitResponse c expectId = loop
  where
    loop = do
      eof <- hIsEOF (mcOut c)
      if eof
        then pure (Left (CallFailed "server closed the connection"))
        else do
          line <- BS.hGetLine (mcOut c)
          if BS.null line
            then loop
            else case parseResponse line of
              Left _              -> loop          -- skip log/garbage line
              Right (Left _ntf)   -> loop          -- skip notification
              Right (Right resp)
                | respId resp /= expectId -> loop  -- stale id; keep reading
                | otherwise -> pure $ case respResult resp of
                    Left jerr -> Left (CallFailed (errMessage jerr))
                    Right v   -> Right v

-- | Send a fire-and-forget notification. NOTE: bypasses 'mcLock'; only safe to
-- call from the sequential handshake path, not concurrently with a 'call'.
sendNotification :: McpClient -> Text -> Value -> IO ()
sendNotification c method params = do
  BL.hPut (mcIn c) (encodeNotification (JsonRpcNotification method params) <> "\n")
  hFlush (mcIn c)

-- ---------------------------------------------------------------------------
-- Teardown / helpers
-- ---------------------------------------------------------------------------

shutdown :: McpClient -> IO ()
shutdown c = killProc (mcProc c) (mcIn c) (mcOut c)

killProc :: ProcessHandle -> Handle -> Handle -> IO ()
killProc ph hin hout = do
  ignore (hClose hin)
  ignore (hClose hout)
  ignore (terminateProcess ph)
  ignore (void (waitForProcess ph))
  where ignore act = act `catch` \(_ :: SomeException) -> pure ()

-- | Read and discard a handle until EOF (used for the server's stderr).
drainHandle :: Handle -> IO ()
drainHandle h = loop `catch` \(_ :: SomeException) -> pure ()
  where
    loop = do
      eof <- hIsEOF h
      if eof then pure () else BS.hGetLine h >> loop
