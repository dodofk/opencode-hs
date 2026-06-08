module OpenCode.Tool.BashSpec (spec) where

import Control.Monad.Except (runExceptT)
import Control.Monad.Reader (runReaderT)
import qualified Data.Aeson as Aeson
import qualified Data.Aeson.KeyMap as KM
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Test.Hspec

import OpenCode.App (AppEnv (..), AppError)
import OpenCode.Tool.Bash
import OpenCode.Tool.Types

spec :: Spec
spec = describe "bashTool" $ do

  it "captures stdout from a simple echo command" $ do
    result <- runBash (BashInput "echo hi" Nothing)
    case result of
      Right t  -> do
        case Aeson.eitherDecodeStrict (Text.encodeUtf8 t) of
          Right (Aeson.Object o) -> do
            KM.lookup "stdout" o `shouldBe` Just (Aeson.String "hi\n")
            KM.lookup "exitCode" o `shouldBe` Just (Aeson.Number 0)
          other -> expectationFailure ("expected object, got " <> show other)
      Left err -> expectationFailure (show err)

  it "captures non-zero exit code and stderr separately" $ do
    result <- runBash (BashInput "sh -c 'echo a; echo b >&2; exit 7'" Nothing)
    case result of
      Right t -> case Aeson.eitherDecodeStrict (Text.encodeUtf8 t) of
        Right (Aeson.Object o) -> do
          KM.lookup "stdout"   o `shouldBe` Just (Aeson.String "a\n")
          KM.lookup "stderr"   o `shouldBe` Just (Aeson.String "b\n")
          KM.lookup "exitCode" o `shouldBe` Just (Aeson.Number 7)
        other -> expectationFailure ("expected object, got " <> show other)
      Left err -> expectationFailure (show err)

  it "terminates the process and returns exitCode -1 on timeout" $ do
    -- Use a 1-second timeout (overriding the 30s default) and sleep 5.
    result <- runBash (BashInput "sleep 5" (Just 1))
    case result of
      Right t -> case Aeson.eitherDecodeStrict (Text.encodeUtf8 t) of
        Right (Aeson.Object o) -> do
          KM.lookup "exitCode" o `shouldBe` Just (Aeson.Number (-1))
          case KM.lookup "stderr" o of
            Just (Aeson.String s) -> Text.unpack s `shouldContain` "timeout"
            other -> expectationFailure ("expected stderr string, got " <> show other)
        other -> expectationFailure ("expected object, got " <> show other)
      Left err -> expectationFailure (show err)

-- ---------------------------------------------------------------------------
-- Helper: dispatch bashTool through executeTool
-- ---------------------------------------------------------------------------

runBash :: BashInput -> IO (Either AppError Text)
runBash input = do
  let reg = registerTool bashTool emptyRegistry
      env = AppEnv
        { envConfig    = undefined
        , envDb        = undefined
        , envRegistry  = undefined
        , envEventChan = undefined
        , envAbort     = undefined
        , envMcp       = []
        , envSkills    = []
        }
      args = Aeson.toJSON input
  runExceptT (runReaderT (executeTool reg "bash" args) env)
