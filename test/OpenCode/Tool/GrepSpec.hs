module OpenCode.Tool.GrepSpec (spec) where

import Control.Monad.Except (runExceptT)
import Control.Monad.Reader (runReaderT)
import qualified Data.Aeson as Aeson
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as KM
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

import OpenCode.App (AppEnv (..), AppError)
import OpenCode.Tool.Grep
import OpenCode.Tool.Types

spec :: Spec
spec = describe "grepTool" $ do

  it "finds a single needle in a fixture file" $
    withSystemTempDirectory "grep" $ \dir -> do
      let path = dir </> "fixture.txt"
      writeFile path "line one\nline two\nline three with needle\nline four\n"
      result <- runGrep (GrepInput "needle" (Just path) False)
      case result of
        Right t -> case Aeson.eitherDecodeStrict (Text.encodeUtf8 t) of
          Right (matches :: [Aeson.Value]) -> do
            length matches `shouldBe` 1
            case head matches of
              Aeson.Object o -> do
                KM.lookup (Key.fromText "line") o `shouldBe` Just (Aeson.Number 3)
                case KM.lookup (Key.fromText "text") o of
                  Just (Aeson.String s) -> Text.unpack s `shouldContain` "needle"
                  other -> expectationFailure ("expected text string, got " <> show other)
              other -> expectationFailure ("expected object, got " <> show other)
          Left e -> expectationFailure ("decode failed: " <> e)
        Left err -> expectationFailure (show err)

  it "returns empty list when needle is not found" $
    withSystemTempDirectory "grep" $ \dir -> do
      let path = dir </> "no-match.txt"
      writeFile path "alpha\nbeta\ngamma\n"
      result <- runGrep (GrepInput "missing" (Just path) False)
      case result of
        Right t -> case Aeson.eitherDecodeStrict (Text.encodeUtf8 t) of
          Right ([] :: [Aeson.Value]) -> pure ()
          other -> expectationFailure ("expected empty list, got " <> show other)
        Left err -> expectationFailure (show err)

  it "recurses through a directory tree when path is a directory" $
    withSystemTempDirectory "grep" $ \dir -> do
      writeFile (dir </> "a.txt") "needle here\n"
      writeFile (dir </> "b.txt") "no match here\n"
      result <- runGrep (GrepInput "needle" (Just dir) True)
      case result of
        Right t -> case Aeson.eitherDecodeStrict (Text.encodeUtf8 t) of
          Right (matches :: [Aeson.Value]) ->
            length matches `shouldSatisfy` (>= 1)
          Left e -> expectationFailure ("decode failed: " <> e)
        Left err -> expectationFailure (show err)

-- ---------------------------------------------------------------------------
-- Helper
-- ---------------------------------------------------------------------------

runGrep :: GrepInput -> IO (Either AppError Text)
runGrep input = do
  let reg = registerTool grepTool emptyRegistry
      env = AppEnv
        { envConfig    = undefined
        , envDb        = undefined
        , envRegistry  = undefined
        , envEventChan = undefined
        , envAbort     = undefined
        }
      args = Aeson.toJSON input
  runExceptT (runReaderT (executeTool reg "grep" args) env)
