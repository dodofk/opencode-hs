-- | Tool: execute a shell command with a timeout.
module OpenCode.Tool.Bash
  ( bashTool
  , bashSchema
  ) where

import Control.Concurrent (forkIO)
import Control.Exception (SomeException, try)
import Control.Monad.Except (throwError)
import Control.Monad.IO.Class (liftIO)
import Data.Aeson (Value, object, (.=))
import qualified Data.Aeson as Aeson
import qualified Data.ByteString.Lazy as BSL
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import qualified Data.Text.Encoding.Error as TextErr
import System.Exit (ExitCode (..))
import qualified System.IO as IO
import qualified System.Process as Proc
import System.Timeout (timeout)

import OpenCode.App (AppError (..), AppM)
import OpenCode.Tool.Types
  ( BashInput (..)
  , BashOutput (..)
  , SomeTool (..)
  , ToolDef (BashTool)
  )

-- ---------------------------------------------------------------------------
-- Tool value
-- ---------------------------------------------------------------------------

bashTool :: SomeTool
bashTool = SomeTool
  { toolDef     = BashTool
  , toolName    = "bash"
  , toolDesc    = "Execute a shell command. Stdin is closed; stdout and stderr are captured. Default 30-second timeout (overridable via timeout field, in seconds)."
  , toolSchema  = bashSchema
  , toolExecute = bashExec
  , toolRender  = renderBashOutput
  }

renderBashOutput :: BashOutput -> Text
renderBashOutput = Text.decodeUtf8With TextErr.lenientDecode . BSL.toStrict . Aeson.encode

-- ---------------------------------------------------------------------------
-- JSON Schema
-- ---------------------------------------------------------------------------

bashSchema :: Value
bashSchema = object
  [ "type"       .= ("object" :: Text)
  , "properties" .= object
      [ "command" .= object
          [ "type"        .= ("string" :: Text)
          , "description" .= ("Shell command to execute" :: Text)
          ]
      , "timeout" .= object
          [ "type"        .= ("integer" :: Text)
          , "description" .= ("Timeout in seconds (default 30)" :: Text)
          ]
      ]
  , "required"   .= (["command"] :: [Text])
  ]

-- ---------------------------------------------------------------------------
-- Executor
-- ---------------------------------------------------------------------------

defaultTimeoutSecs :: Int
defaultTimeoutSecs = 30

bashExec :: BashInput -> AppM BashOutput
bashExec BashInput { biCommand = cmd, biTimeout = mTimeout } = do
  let secs   = fromMaybe defaultTimeoutSecs mTimeout
      micros = secs * 1_000_000
  attempt <- liftIO (try (runBashIO micros cmd) :: IO (Either SomeException BashOutput))
  case attempt of
    Right out -> pure out
    Left ex   -> throwError (ToolError "bash" (Text.pack ("bash failed: " <> show ex)))

runBashIO :: Int -> Text -> IO BashOutput
runBashIO micros cmd = do
  let cp = (Proc.shell (Text.unpack cmd))
        { Proc.std_in  = Proc.NoStream
        , Proc.std_out = Proc.CreatePipe
        , Proc.std_err = Proc.CreatePipe
        }
  (_, mhOut, mhErr, ph) <- Proc.createProcess cp
  let hOut = fromJustH "stdout handle missing" mhOut
      hErr = fromJustH "stderr handle missing" mhErr
  outRef <- newIORef Text.empty
  errRef <- newIORef Text.empty
  _ <- forkIO (drainHandle hOut outRef)
  _ <- forkIO (drainHandle hErr errRef)
  mExit <- timeout micros (Proc.waitForProcess ph)
  case mExit of
    Just ec -> do
      stdoutVal <- readIORef outRef
      stderrVal <- readIORef errRef
      pure BashOutput
        { boStdout   = stdoutVal
        , boStderr   = stderrVal
        , boExitCode = exitToInt ec
        }
    Nothing -> do
      Proc.terminateProcess ph
      _ <- Proc.waitForProcess ph
      stdoutVal <- readIORef outRef
      pure BashOutput
        { boStdout   = stdoutVal
        , boStderr   = "timeout after " <> Text.pack (show (micros `div` 1_000_000)) <> "s"
        , boExitCode = -1
        }
  where
    fromJustH _   (Just h) = h
    fromJustH msg Nothing  = error ("OpenCode.Tool.Bash: " <> msg)

drainHandle :: IO.Handle -> IORef Text -> IO ()
drainHandle h ref = do
  bs <- BSL.hGetContents h
  let txt = Text.decodeUtf8With TextErr.lenientDecode (BSL.toStrict bs)
  atomicModifyIORef' ref (const (txt, ()))
  IO.hClose h

exitToInt :: ExitCode -> Int
exitToInt ExitSuccess     = 0
exitToInt (ExitFailure n) = n
