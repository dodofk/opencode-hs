module OpenCode.ErrorPathSpec (spec) where

import Control.Exception (try)
import Control.Monad.Except (runExceptT)
import Control.Monad.Reader (runReaderT)
import qualified Data.List.NonEmpty as NE
import qualified Data.Text as T
import Data.Time (getCurrentTime)
import Database.SQLite.Simple (SQLError (..), execute_)
import Database.SQLite3 (Error (ErrorBusy))
import System.IO.Temp (withSystemTempDirectory)
import System.FilePath ((</>))
import Test.Hspec

import OpenCode.App.Types (AppEnv (..))
import qualified OpenCode.DB as DB
import OpenCode.LLM.Mock (newScriptedStreamer, staticStreamer)
import OpenCode.Run (renderDbError)
import OpenCode.Session (processUserMessageWith)
import OpenCode.TestEnv (withTestEnv)
import OpenCode.Types
  ( Message (..), MessagePart (..), ModelId (..), ProviderId (..), Role (..)
  , Session (..), SessionId (..), StreamEvent (..), ToolResult (..), Usage (..)
  , isError, msgParts, msgRole )

spec :: Spec
spec = describe "error paths" $ do

  it "(a) bad API key: error persists, user message intact, no exception" $
    withTestEnv $ \env session -> do
      let streamer = staticStreamer
            [ StreamError "openai: 401: invalid api key", StreamDone (Usage 0 0 Nothing Nothing) ]
      result <- runExceptT $ runReaderT
        (processUserMessageWith streamer (sessionId session) "hello") env
      result `shouldBe` Right ()
      stored <- DB.getMessages (envDb env) (sessionId session)
      msgRole (head stored) `shouldBe` RoleUser
      let parts = concatMap (NE.toList . msgParts) stored
      any (\p -> case p of ErrorPart e -> "401" `T.isInfixOf` e; _ -> False) parts
        `shouldBe` True

  it "(b) tool failure mid-loop: round 1 isError, loop still runs round 2" $
    withTestEnv $ \env session -> do
      let round1 =
            [ ToolCallStart "c1" "no_such_tool", ToolCallArgDelta "c1" "{}"
            , ToolCallEnd "c1", StreamDone (Usage 1 1 Nothing Nothing) ]
          round2 = [ TextDelta "recovered", StreamDone (Usage 1 1 Nothing Nothing) ]
      streamer <- newScriptedStreamer [round1, round2]
      _ <- runExceptT $ runReaderT
        (processUserMessageWith streamer (sessionId session) "go") env
      stored <- DB.getMessages (envDb env) (sessionId session)
      let results = [ r | m <- stored, ToolResultPart r <- NE.toList (msgParts m) ]
          texts   = [ t | m <- stored, TextPart t <- NE.toList (msgParts m) ]
      any isError results `shouldBe` True
      ("recovered" `elem` texts) `shouldBe` True

  it "(c) DB locked: insert throws ErrorBusy, renderDbError stays clean" $
    withSystemTempDirectory "m12db" $ \dir -> do
      let path = dir </> "sessions.db"
      connA <- DB.openDb path
      connB <- DB.openDb path
      execute_ connA "PRAGMA busy_timeout = 0"
      execute_ connB "PRAGMA busy_timeout = 0"
      execute_ connA "BEGIN IMMEDIATE"
      execute_ connA "INSERT INTO migrations (version, applied_at) VALUES (999, 'x')"
      now <- getCurrentTime
      let s = Session (SessionId "s-busy") "t" (ModelId OpenAI "gpt-4o") now
      outcome <- try (DB.insertSession connB s) :: IO (Either SQLError ())
      case outcome of
        Left e  -> do
          sqlError e `shouldBe` ErrorBusy
          renderDbError e `shouldSatisfy` T.isInfixOf "database error"
        Right _ -> expectationFailure "expected SQLITE_BUSY"

  it "(d) streaming drop: partial text + error both persist" $
    withTestEnv $ \env session -> do
      let streamer = staticStreamer
            [ TextDelta "partial answer", StreamError "connection reset by peer" ]
      _ <- runExceptT $ runReaderT
        (processUserMessageWith streamer (sessionId session) "q") env
      stored <- DB.getMessages (envDb env) (sessionId session)
      let parts = concatMap (NE.toList . msgParts) stored
      ("partial answer" `elem` [t | TextPart t <- parts]) `shouldBe` True
      any (\p -> case p of ErrorPart e -> "connection reset" `T.isInfixOf` e; _ -> False) parts
        `shouldBe` True
