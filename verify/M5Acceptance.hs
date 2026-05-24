module Main where

import qualified Brick.BChan as BChan
import qualified Control.Concurrent.STM as STM
import qualified Data.Aeson as Aeson
import Data.Aeson ((.=))
import qualified Data.Text as Text
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)

import OpenCode.App (AppEnv (..), askExecuteTool, runAppM)
import OpenCode.Tool.Registry (defaultBuiltinRegistry)

main :: IO ()
main = do
  chan     <- BChan.newBChan 100
  abortVar <- STM.newTVarIO False
  let env  = AppEnv
        { envConfig    = undefined
        , envDb        = undefined
        , envRegistry  = defaultBuiltinRegistry
        , envEventChan = chan
        , envAbort     = abortVar
        }
      args = Aeson.object
        [ "path"    .= ("/tmp/x" :: Text.Text)
        , "content" .= ("hi"     :: Text.Text)
        ]
  result <- runAppM env (askExecuteTool "write_file" args)
  case result of
    Right "wrote 2 bytes to /tmp/x" -> do
      contents <- readFile "/tmp/x"
      if contents == "hi"
        then putStrLn "M5 acceptance OK"
        else do
          hPutStrLn stderr ("FAIL: /tmp/x contains " <> show contents)
          exitFailure
    other -> do
      hPutStrLn stderr ("FAIL: unexpected result: " <> show other)
      exitFailure
