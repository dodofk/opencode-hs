module Main where

import qualified Brick.BChan as BChan
import qualified Control.Concurrent.STM as STM
import qualified Data.Aeson as Aeson
import qualified Data.Aeson.KeyMap as KM
import Data.Aeson ((.=))
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
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
      args = Aeson.object [ "command" .= ("echo hi" :: Text.Text) ]
  result <- runAppM env (askExecuteTool "bash" args)
  case result of
    Right resultText ->
      case Aeson.eitherDecodeStrict (Text.encodeUtf8 resultText) of
        Right (Aeson.Object o) ->
          case KM.lookup "stdout" o of
            Just (Aeson.String s) ->
              if s == "hi\n"
                then putStrLn "M7 acceptance OK"
                else do
                  hPutStrLn stderr ("FAIL: stdout was " <> show s)
                  exitFailure
            other -> do
              hPutStrLn stderr ("FAIL: no stdout string field: " <> show other)
              exitFailure
        other -> do
          hPutStrLn stderr ("FAIL: result not a JSON object: " <> show other)
          exitFailure
    Left err -> do
      hPutStrLn stderr ("FAIL: askExecuteTool returned " <> show err)
      exitFailure
