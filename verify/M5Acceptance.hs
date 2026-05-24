module Main where

import qualified Data.Aeson as Aeson
import Data.Aeson ((.=))
import qualified Data.Text as Text
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)

import OpenCode.App (AppEnv (..), runAppM)
import OpenCode.Tool.Registry (defaultBuiltinRegistry)
import OpenCode.Tool.Types (executeTool)

main :: IO ()
main = do
  let env  = AppEnv
        { envConfig   = undefined
        , envDb       = undefined
        , envRegistry = defaultBuiltinRegistry
        }
      args = Aeson.object
        [ "path"    .= ("/tmp/x" :: Text.Text)
        , "content" .= ("hi"     :: Text.Text)
        ]
  result <- runAppM env (executeTool defaultBuiltinRegistry "write_file" args)
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
