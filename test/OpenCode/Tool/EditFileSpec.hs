module OpenCode.Tool.EditFileSpec (spec) where

import Control.Monad.Except (runExceptT)
import Control.Monad.Reader (runReaderT)
import qualified Data.Aeson as Aeson
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.IO as TIO
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

import OpenCode.App (AppEnv (..), AppError (..))
import OpenCode.Tool.EditFile
import OpenCode.Tool.Types

spec :: Spec
spec = describe "editFileTool" $ do

  it "replaces a unique match and returns a non-empty diff" $
    withSystemTempDirectory "ef" $ \dir -> do
      let path = dir </> "f.txt"
      TIO.writeFile path "alpha\nbeta\ngamma\n"
      result <- runEdit (EditFileInput path "beta" "BETA")
      case result of
        Right diff -> do
          Text.length diff `shouldSatisfy` (> 0)
          Text.unpack diff `shouldContain` "-"
          Text.unpack diff `shouldContain` "+"
        Left err   -> expectationFailure (show err)
      after <- TIO.readFile path
      after `shouldBe` "alpha\nBETA\ngamma\n"

  it "errors when the old string is not found" $
    withSystemTempDirectory "ef" $ \dir -> do
      let path = dir </> "f.txt"
      TIO.writeFile path "alpha\nbeta\n"
      result <- runEdit (EditFileInput path "MISSING" "X")
      case result of
        Left (ToolError "edit_file" msg) -> Text.unpack msg `shouldContain` "not found"
        _ -> expectationFailure ("expected not-found ToolError, got " <> show result)

  it "errors when the old string matches more than once" $
    withSystemTempDirectory "ef" $ \dir -> do
      let path = dir </> "f.txt"
      TIO.writeFile path "x\nx\nx\n"
      result <- runEdit (EditFileInput path "x" "y")
      case result of
        Left (ToolError "edit_file" msg) -> Text.unpack msg `shouldContain` "ambiguous"
        _ -> expectationFailure ("expected ambiguous ToolError, got " <> show result)

  it "leaves the file untouched on error" $
    withSystemTempDirectory "ef" $ \dir -> do
      let path = dir </> "f.txt"
      TIO.writeFile path "x\nx\n"
      _ <- runEdit (EditFileInput path "x" "y")   -- ambiguous; should not write
      after <- TIO.readFile path
      after `shouldBe` "x\nx\n"

-- ---------------------------------------------------------------------------
-- Helper
-- ---------------------------------------------------------------------------

runEdit :: EditFileInput -> IO (Either AppError Text)
runEdit input = do
  let reg = registerTool editFileTool emptyRegistry
      env = AppEnv { envConfig = undefined, envDb = undefined }
      args = Aeson.toJSON input
  runExceptT (runReaderT (executeTool reg "edit_file" args) env)
