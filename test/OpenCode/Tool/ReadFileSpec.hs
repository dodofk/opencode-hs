module OpenCode.Tool.ReadFileSpec (spec) where

import Control.Monad.Except (runExceptT)
import Control.Monad.Reader (runReaderT)
import qualified Data.Aeson as Aeson
import qualified Data.ByteString as BS
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.IO as TIO
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

import OpenCode.App (AppEnv (..), AppError (..))
import OpenCode.Tool.ReadFile
import OpenCode.Tool.Types

spec :: Spec
spec = describe "readFileTool" $ do

  it "reads an entire small file" $
    withSystemTempDirectory "rf" $ \dir -> do
      let path = dir </> "hello.txt"
      TIO.writeFile path "hello\nworld\n"
      result <- runRead (ReadFileInput path Nothing Nothing)
      result `shouldBe` Right "hello\nworld\n"

  it "honours offset and limit" $
    withSystemTempDirectory "rf" $ \dir -> do
      let path = dir </> "fifty.txt"
          body = Text.unlines [Text.pack ("line " <> show n) | n <- [1 :: Int .. 50]]
      TIO.writeFile path body
      result <- runRead (ReadFileInput path (Just 10) (Just 5))
      case result of
        Right t  -> Text.lines t `shouldBe`
          [ "line 10", "line 11", "line 12", "line 13", "line 14" ]
        Left err -> expectationFailure (show err)

  it "refuses a file with a NUL byte in the first 8 KB (binary detection)" $
    withSystemTempDirectory "rf" $ \dir -> do
      let path = dir </> "bin.dat"
      BS.writeFile path (BS.pack [97, 98, 99, 0, 100, 101, 102])  -- abc\0def
      result <- runRead (ReadFileInput path Nothing Nothing)
      case result of
        Left (ToolError "read_file" msg) -> Text.unpack msg `shouldContain` "binary"
        _ -> expectationFailure ("expected binary-refusal ToolError, got " <> show result)

  it "truncates output at 100 KB and appends a marker" $
    withSystemTempDirectory "rf" $ \dir -> do
      let path = dir </> "big.txt"
          body = Text.replicate 150000 "a"  -- 150 KB of 'a'
      TIO.writeFile path body
      result <- runRead (ReadFileInput path Nothing Nothing)
      case result of
        Right t  -> do
          Text.length t `shouldSatisfy` (< 150000)
          Text.unpack t `shouldContain` "[truncated:"
        Left err -> expectationFailure (show err)

-- ---------------------------------------------------------------------------
-- Helper: dispatch readFileTool through executeTool
-- ---------------------------------------------------------------------------

runRead :: ReadFileInput -> IO (Either AppError Text)
runRead input = do
  let reg = registerTool readFileTool emptyRegistry
      env = AppEnv
        { envConfig    = undefined
        , envDb        = undefined
        , envRegistry  = undefined
        , envEventChan = undefined
        , envAbort     = undefined
        , envMcp         = []
        , envSkills      = []
        , envHttpBackend = undefined
        , envTools       = undefined
        }
      args = Aeson.toJSON input
  runExceptT (runReaderT (executeTool reg "read_file" args) env)
