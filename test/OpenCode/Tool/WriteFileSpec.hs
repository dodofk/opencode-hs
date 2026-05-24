module OpenCode.Tool.WriteFileSpec (spec) where

import Control.Monad.Except (runExceptT)
import Control.Monad.Reader (runReaderT)
import qualified Data.Aeson as Aeson
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.IO as TIO
import System.Directory (doesFileExist)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

import OpenCode.App (AppEnv (..), AppError)
import OpenCode.Tool.Types
import OpenCode.Tool.WriteFile

spec :: Spec
spec = describe "writeFileTool" $ do

  it "writes a small file and reports the byte count" $
    withSystemTempDirectory "wf" $ \dir -> do
      let path = dir </> "out.txt"
      result <- runWrite (WriteFileInput path "hello")
      result `shouldBe` Right (Text.pack ("wrote 5 bytes to " <> path))
      contents <- TIO.readFile path
      contents `shouldBe` "hello"

  it "creates missing parent directories" $
    withSystemTempDirectory "wf" $ \dir -> do
      let path = dir </> "a" </> "b" </> "c.txt"
      result <- runWrite (WriteFileInput path "ok")
      case result of
        Right _ -> doesFileExist path >>= (`shouldBe` True)
        Left  e -> expectationFailure (show e)

  it "leaves no .tmp file after a successful write" $
    withSystemTempDirectory "wf" $ \dir -> do
      let path = dir </> "atomic.txt"
      _ <- runWrite (WriteFileInput path "data")
      doesFileExist (path <> ".tmp") >>= (`shouldBe` False)

  it "counts bytes in UTF-8 (multi-byte characters)" $
    withSystemTempDirectory "wf" $ \dir -> do
      let path    = dir </> "utf8.txt"
          content = "héllo"   -- é is 2 bytes in UTF-8 (6 bytes total)
      result <- runWrite (WriteFileInput path content)
      result `shouldBe` Right (Text.pack ("wrote 6 bytes to " <> path))

-- ---------------------------------------------------------------------------
-- Helper
-- ---------------------------------------------------------------------------

runWrite :: WriteFileInput -> IO (Either AppError Text)
runWrite input = do
  let reg = registerTool writeFileTool emptyRegistry
      env = AppEnv { envConfig = undefined, envDb = undefined, envRegistry = undefined }
      args = Aeson.toJSON input
  runExceptT (runReaderT (executeTool reg "write_file" args) env)
