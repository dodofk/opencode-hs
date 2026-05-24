module Main where

import qualified Brick.BChan as BChan
import qualified Control.Concurrent.STM as STM
import Control.Monad (when)
import Control.Monad.Except (runExceptT)
import Control.Monad.Reader (runReaderT)
import qualified Data.Text.IO as TIO
import Database.SQLite.Simple (close)
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)

import OpenCode.App (AppEnv (..))
import OpenCode.Config (Config (..), ProviderConfig (..))
import OpenCode.DB (getMessages, openDb)
import OpenCode.LLM.Mock (newScriptedStreamer)
import OpenCode.Session (createSession, processUserMessageWith)
import OpenCode.Tool.Registry (defaultBuiltinRegistry)
import OpenCode.Types
  ( ApiKey (..)
  , ModelId (..)
  , ProviderId (..)
  , Session (..)
  , StreamEvent (..)
  , Usage (..)
  )

main :: IO ()
main = do
  conn     <- openDb ":memory:"
  chan     <- BChan.newBChan 100
  abortVar <- STM.newTVarIO False
  let cfg = Config
        { providers    = ProviderConfig
            { openaiKey    = Just (ApiKey "sk-test-stub")
            , anthropicKey = Nothing
            }
        , defaultModel = ModelId OpenAI "gpt-4o"
        }
      env = AppEnv
        { envConfig    = cfg
        , envDb        = conn
        , envRegistry  = defaultBuiltinRegistry
        , envEventChan = chan
        , envAbort     = abortVar
        }

  -- Script a mock that calls write_file in round 1 and emits text in round 2.
  let toolArgs = "{\"path\":\"/tmp/m6-x.txt\",\"content\":\"hello m6\"}"
      round1 =
        [ ToolCallStart "c1" "write_file"
        , ToolCallArgDelta "c1" toolArgs
        , ToolCallEnd "c1"
        , StreamDone (Usage 50 15 Nothing Nothing)
        ]
      round2 =
        [ TextDelta "Wrote it."
        , StreamDone (Usage 3 2 Nothing Nothing)
        ]
  streamer <- newScriptedStreamer [round1, round2]

  -- Create session and process a user message.
  sessionResult <- runExceptT $ runReaderT (createSession (ModelId OpenAI "gpt-4o")) env
  session <- case sessionResult of
    Right s  -> pure s
    Left err -> hPutStrLn stderr ("FAIL: createSession: " <> show err) *> exitFailure

  procResult <- runExceptT $ runReaderT
    (processUserMessageWith streamer (sessionId session) "please write the file") env
  case procResult of
    Right () -> pure ()
    Left err -> hPutStrLn stderr ("FAIL: processUserMessageWith: " <> show err) *> exitFailure

  -- Verify: file exists on disk.
  contents <- TIO.readFile "/tmp/m6-x.txt"
  when (contents /= "hello m6") $ do
    hPutStrLn stderr ("FAIL: /tmp/m6-x.txt contains " <> show contents)
    exitFailure

  -- Verify: getMessages returns 3 messages (user -> assistant-with-tool -> assistant-text).
  msgs <- getMessages conn (sessionId session)
  when (length msgs /= 3) $ do
    hPutStrLn stderr ("FAIL: expected 3 messages, got " <> show (length msgs))
    exitFailure

  close conn
  putStrLn "M6 acceptance OK"
