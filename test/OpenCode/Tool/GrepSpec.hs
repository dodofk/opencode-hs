module OpenCode.Tool.GrepSpec (spec) where

import Control.Monad.Except (runExceptT)
import Control.Monad.Reader (runReaderT)
import qualified Data.Aeson as Aeson
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as KM
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import qualified Data.Text.IO as Text
import System.FilePath ((</>))
import qualified System.Directory as Dir
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

import OpenCode.App (AppEnv (..), AppError)
import OpenCode.Tool.Grep
import OpenCode.Tool.Types
  ( GrepInput (..)
  , emptyRegistry
  , executeTool
  , registerTool
  )

spec :: Spec
spec = describe "grepTool" $ do

  it "finds a single needle in a fixture file" $
    withSystemTempDirectory "grep" $ \dir -> do
      let path = dir </> "fixture.txt"
      writeFile path "line one\nline two\nline three with needle\nline four\n"
      result <- runGrep (GrepInput "needle" (Just path) (Just False))
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
      result <- runGrep (GrepInput "missing" (Just path) (Just False))
      case result of
        Right t -> case Aeson.eitherDecodeStrict (Text.encodeUtf8 t) of
          Right ([] :: [Aeson.Value]) -> pure ()
          other -> expectationFailure ("expected empty list, got " <> show other)
        Left err -> expectationFailure (show err)

  it "recurses through a directory tree when path is a directory" $
    withSystemTempDirectory "grep" $ \dir -> do
      writeFile (dir </> "a.txt") "needle here\n"
      writeFile (dir </> "b.txt") "no match here\n"
      result <- runGrep (GrepInput "needle" (Just dir) (Just True))
      case result of
        Right t -> case Aeson.eitherDecodeStrict (Text.encodeUtf8 t) of
          Right (matches :: [Aeson.Value]) ->
            length matches `shouldSatisfy` (>= 1)
          Left e -> expectationFailure ("decode failed: " <> e)
        Left err -> expectationFailure (show err)

  it "decodes JSON without the recursive field (defaults to non-recursive)" $
    withSystemTempDirectory "grep" $ \dir -> do
      let path = dir </> "single.txt"
      writeFile path "needle here\n"
      -- Build the JSON args WITHOUT a "recursive" field. The schema marks it
      -- optional, so the LLM may omit it.
      let args = Aeson.object
            [ "pattern" Aeson..= ("needle" :: Text)
            , "path"    Aeson..= path
            ]
          reg = registerTool grepTool emptyRegistry
          env = AppEnv
            { envConfig    = undefined
            , envDb        = undefined
            , envRegistry  = undefined
            , envEventChan = undefined
            , envAbort     = undefined
            }
      result <- runExceptT $ runReaderT (executeTool reg "grep" args) env
      case result of
        Right t -> case Aeson.eitherDecodeStrict (Text.encodeUtf8 t) of
          Right (matches :: [Aeson.Value]) -> length matches `shouldBe` 1
          Left e  -> expectationFailure ("decode failed: " <> e)
        Left err -> expectationFailure (show err)

  it "matches unicode content in a file" $
    withSystemTempDirectory "grep" $ \dir -> do
      let path = dir </> "unicode.txt"
      -- Write UTF-8 content with CJK, emoji, and accented characters
      Text.writeFile path "hello world\n日本語のテスト\nsome café text\nrocket 🚀 launch\n"
      result <- runGrep (GrepInput "日本語" (Just path) (Just False))
      case result of
        Right t -> case Aeson.eitherDecodeStrict (Text.encodeUtf8 t) of
          Right (matches :: [Aeson.Value]) -> do
            length matches `shouldBe` 1
            case head matches of
              Aeson.Object o -> do
                KM.lookup (Key.fromText "line") o `shouldBe` Just (Aeson.Number 2)
                case KM.lookup (Key.fromText "text") o of
                  Just (Aeson.String s) -> s `shouldSatisfy` Text.isInfixOf "日本語のテスト"
                  other -> expectationFailure ("expected text string, got " <> show other)
              other -> expectationFailure ("expected object, got " <> show other)
          Left e -> expectationFailure ("decode failed: " <> e)
        Left err -> expectationFailure (show err)

  it "matches unicode content with emoji pattern" $
    withSystemTempDirectory "grep" $ \dir -> do
      let path = dir </> "emoji.txt"
      Text.writeFile path "line one\nlaunch 🚀 now\nline three\n"
      result <- runGrep (GrepInput "🚀" (Just path) (Just False))
      case result of
        Right t -> case Aeson.eitherDecodeStrict (Text.encodeUtf8 t) of
          Right (matches :: [Aeson.Value]) -> do
            length matches `shouldBe` 1
            case head matches of
              Aeson.Object o ->
                KM.lookup (Key.fromText "line") o `shouldBe` Just (Aeson.Number 2)
              other -> expectationFailure ("expected object, got " <> show other)
          Left e -> expectationFailure ("decode failed: " <> e)
        Left err -> expectationFailure (show err)

  it "finds matches in a file with a unicode filename" $
    withSystemTempDirectory "grep" $ \dir -> do
      let path = dir </> "données.txt"
      Text.writeFile path "première ligne\ndeuxième ligne\ntroisième ligne\n"
      result <- runGrep (GrepInput "deuxième" (Just path) (Just False))
      case result of
        Right t -> case Aeson.eitherDecodeStrict (Text.encodeUtf8 t) of
          Right (matches :: [Aeson.Value]) -> do
            length matches `shouldBe` 1
            case head matches of
              Aeson.Object o -> do
                KM.lookup (Key.fromText "line") o `shouldBe` Just (Aeson.Number 2)
                case KM.lookup (Key.fromText "file") o of
                  Just (Aeson.String s) -> Text.unpack s `shouldContain` "données.txt"
                  other -> expectationFailure ("expected file string, got " <> show other)
              other -> expectationFailure ("expected object, got " <> show other)
          Left e -> expectationFailure ("decode failed: " <> e)
        Left err -> expectationFailure (show err)

  it "recursively finds unicode content in files with CJK filenames" $
    withSystemTempDirectory "grep" $ \dir -> do
      let subdir = dir </> "子目录"
      Dir.createDirectory subdir
      Text.writeFile (subdir </> "文件.txt") "这里有中文内容\n搜索目标\n"
      Text.writeFile (dir </> "plain.txt") "no match\n"
      result <- runGrep (GrepInput "搜索目标" (Just dir) (Just True))
      case result of
        Right t -> case Aeson.eitherDecodeStrict (Text.encodeUtf8 t) of
          Right (matches :: [Aeson.Value]) -> do
            length matches `shouldBe` 1
            case head matches of
              Aeson.Object o -> do
                KM.lookup (Key.fromText "line") o `shouldBe` Just (Aeson.Number 2)
                case KM.lookup (Key.fromText "file") o of
                  Just (Aeson.String s) -> Text.unpack s `shouldContain` "文件.txt"
                  other -> expectationFailure ("expected file string, got " <> show other)
              other -> expectationFailure ("expected object, got " <> show other)
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
