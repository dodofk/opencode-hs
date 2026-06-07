module OpenCode.Tool.GrepSpec (spec) where

import Control.Monad.Except (runExceptT)
import Control.Monad.Reader (runReaderT)
import qualified Data.Aeson as Aeson
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString as BS
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import System.FilePath ((</>))
import qualified GHC.IO.Encoding as Enc
import qualified System.Directory as Dir
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

import OpenCode.App (AppEnv (..), AppError)
import OpenCode.Tool.Grep
import OpenCode.Tool.Types
  ( GrepInput (..)
  , GrepMatch (..)
  , emptyRegistry
  , executeTool
  , registerTool
  )

spec :: Spec
spec = describe "grepTool" $ do

  -- Make these tests independent of the ambient locale. Unicode file *content*
  -- is written as raw UTF-8 bytes (see 'writeFileUtf8'), and unicode *paths*
  -- (CJK / accented file and directory names) are encoded and decoded as UTF-8
  -- regardless of LANG. Without this, fixtures fail under a non-UTF-8 locale
  -- such as LC_ALL=C, whose default filesystem encoding cannot represent
  -- non-Latin code points.
  runIO (Enc.setLocaleEncoding Enc.utf8 >> Enc.setFileSystemEncoding Enc.utf8)

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
            , envMcp       = []
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
      writeFileUtf8 path "hello world\n日本語のテスト\nsome café text\nrocket 🚀 launch\n"
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
      writeFileUtf8 path "line one\nlaunch 🚀 now\nline three\n"
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
      writeFileUtf8 path "première ligne\ndeuxième ligne\ntroisième ligne\n"
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
      writeFileUtf8 (subdir </> "文件.txt") "这里有中文内容\n搜索目标\n"
      writeFileUtf8 (dir </> "plain.txt") "no match\n"
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

  -- The tests above run through 'grepExec', which uses ripgrep whenever it is
  -- on PATH (CI and most dev boxes) — so the pure-Haskell fallback walk, and
  -- the 'recursive' flag that only the fallback consumes, are never exercised
  -- there. These drive 'grepFallback' directly to cover that path on unicode.

  it "fallback: matches unicode content via a recursive walk over a CJK-named subdir" $
    withSystemTempDirectory "grep" $ \dir -> do
      let subdir = dir </> "子目录"
      Dir.createDirectory subdir
      writeFileUtf8 (subdir </> "文件.txt") "这里有中文内容\n搜索目标\n"
      writeFileUtf8 (dir </> "plain.txt") "no match\n"
      matches <- grepFallback "搜索目标" dir True
      map gmLine matches `shouldBe` [2]
      case matches of
        [m] -> do
          gmFile m `shouldContain` "文件.txt"
          gmText m `shouldSatisfy` Text.isInfixOf "搜索目标"
        _   -> expectationFailure ("expected exactly one match, got " <> show matches)

  it "fallback: recursive flag gates directory descent" $
    withSystemTempDirectory "grep" $ \dir -> do
      let subdir = dir </> "子目录"
      Dir.createDirectory subdir
      writeFileUtf8 (dir </> "top.txt")     "需要 at top\n"
      writeFileUtf8 (subdir </> "文件.txt") "需要 nested\n"
      shallow <- grepFallback "需要" dir False
      deep    <- grepFallback "需要" dir True
      map gmLine shallow `shouldBe` [1]   -- only top.txt is scanned
      length deep        `shouldBe` 2     -- top.txt + 子目录/文件.txt

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

-- | Write file content as raw UTF-8 bytes, independent of the process locale
-- (unlike 'Data.Text.IO.writeFile', which encodes through the handle's locale
-- encoding and throws under a non-UTF-8 locale).
writeFileUtf8 :: FilePath -> Text -> IO ()
writeFileUtf8 path = BS.writeFile path . Text.encodeUtf8

runGrep :: GrepInput -> IO (Either AppError Text)
runGrep input = do
  let reg = registerTool grepTool emptyRegistry
      env = AppEnv
        { envConfig    = undefined
        , envDb        = undefined
        , envRegistry  = undefined
        , envEventChan = undefined
        , envAbort     = undefined
        , envMcp       = []
        }
      args = Aeson.toJSON input
  runExceptT (runReaderT (executeTool reg "grep" args) env)
