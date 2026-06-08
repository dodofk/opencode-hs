module OpenCode.Tool.GlobSpec (spec) where

import Control.Monad.Except (runExceptT)
import Control.Monad.Reader (runReaderT)
import Control.Monad (forM_)
import qualified Data.Aeson as Aeson
import Data.List (sort)
import Data.Text (Text)
import qualified Data.Text.Encoding as Text
import System.Directory (createDirectoryIfMissing)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

import OpenCode.App (AppEnv (..), AppError)
import OpenCode.Tool.Glob
import OpenCode.Tool.Types

spec :: Spec
spec = describe "globTool" $ do

  it "matches Haskell files via **/*.hs and returns them sorted" $
    withSystemTempDirectory "glob" $ \dir -> do
      writeFile (dir </> "foo.hs") "module Foo where"
      writeFile (dir </> "bar.txt") "not haskell"
      createDirectoryIfMissing True (dir </> "sub")
      writeFile (dir </> "sub" </> "baz.hs") "module Sub.Baz where"
      result <- runGlob (GlobInput "**/*.hs" (Just dir))
      case result of
        Right t -> case Aeson.eitherDecodeStrict (Text.encodeUtf8 t) of
          Right (matches :: [FilePath]) -> do
            let stripped = sort (map basename matches)
            stripped `shouldContain` ["foo.hs"]
            stripped `shouldContain` ["baz.hs"]
            stripped `shouldNotContain` ["bar.txt"]
          Left e -> expectationFailure ("decode failed: " <> e)
        Left err -> expectationFailure (show err)

  it "caps results at 500 entries and appends a truncated marker" $
    withSystemTempDirectory "glob" $ \dir -> do
      forM_ [(1 :: Int) .. 600] $ \i ->
        writeFile (dir </> ("file" <> show i <> ".hs")) ""
      result <- runGlob (GlobInput "*.hs" (Just dir))
      case result of
        Right t -> case Aeson.eitherDecodeStrict (Text.encodeUtf8 t) of
          Right (matches :: [FilePath]) -> do
            length matches `shouldBe` 501   -- 500 file paths + 1 truncated marker
            last matches `shouldBe` "\x2026truncated"
          Left e -> expectationFailure ("decode failed: " <> e)
        Left err -> expectationFailure (show err)

  it "excludes entries that line-prefix match a .gitignore" $
    withSystemTempDirectory "glob" $ \dir -> do
      writeFile (dir </> ".gitignore") "node_modules/\nbuild\n"
      writeFile (dir </> "keep.hs") ""
      createDirectoryIfMissing True (dir </> "node_modules")
      writeFile (dir </> "node_modules" </> "skip.hs") ""
      createDirectoryIfMissing True (dir </> "build")
      writeFile (dir </> "build" </> "also-skip.hs") ""
      result <- runGlob (GlobInput "**/*.hs" (Just dir))
      case result of
        Right t -> case Aeson.eitherDecodeStrict (Text.encodeUtf8 t) of
          Right (matches :: [FilePath]) -> do
            let stripped = map basename matches
            stripped `shouldContain` ["keep.hs"]
            stripped `shouldNotContain` ["skip.hs"]
            stripped `shouldNotContain` ["also-skip.hs"]
          Left e -> expectationFailure ("decode failed: " <> e)
        Left err -> expectationFailure (show err)

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

basename :: FilePath -> String
basename = reverse . takeWhile (/= '/') . reverse

runGlob :: GlobInput -> IO (Either AppError Text)
runGlob input = do
  let reg = registerTool globTool emptyRegistry
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
  runExceptT (runReaderT (executeTool reg "glob" args) env)
