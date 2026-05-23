module OpenCode.DBSpec (spec) where

import Control.Exception (bracket)
import Data.Text (Text)
import Database.SQLite.Simple
  ( Connection
  , Only (..)
  , close
  , query_
  )
import Test.Hspec

import OpenCode.DB

-- | Helper: open an in-memory DB with schema applied; close on exit.
withInMemoryDb :: (Connection -> IO a) -> IO a
withInMemoryDb = bracket (openDb ":memory:") close

spec :: Spec
spec = do
  describe "createSchema" $ do

    it "creates the migrations, sessions, and messages tables" $
      withInMemoryDb $ \conn -> do
        names <- map fromOnly <$> query_ conn
          "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name"
          :: IO [Text]
        -- May include sqlite_sequence etc; assert ours are present.
        names `shouldSatisfy` (\xs ->
          all (`elem` xs) ["messages", "migrations", "sessions"])

    it "sessions table has the SPEC §3.6 columns" $
      withInMemoryDb $ \conn -> do
        cols <- query_ conn "PRAGMA table_info(sessions)"
          :: IO [(Int, Text, Text, Int, Maybe Text, Int)]
        map (\(_, n, _, _, _, _) -> n) cols
          `shouldBe` ["id", "title", "model_id", "created_at"]

    it "messages table has the SPEC §3.6 columns" $
      withInMemoryDb $ \conn -> do
        cols <- query_ conn "PRAGMA table_info(messages)"
          :: IO [(Int, Text, Text, Int, Maybe Text, Int)]
        map (\(_, n, _, _, _, _) -> n) cols
          `shouldBe` ["id", "session_id", "role", "parts", "created_at"]

    it "is idempotent — calling createSchema twice does not raise" $
      withInMemoryDb $ \conn -> do
        createSchema conn   -- second call (openDb already ran it once)
        createSchema conn
        -- If we got here, no exception was thrown.
        pure ()

    it "records the migration version in the migrations table" $
      withInMemoryDb $ \conn -> do
        versions <- map fromOnly <$> query_ conn
          "SELECT version FROM migrations ORDER BY version"
          :: IO [Int]
        versions `shouldBe` [1]

    it "does not re-record a migration that is already applied" $
      withInMemoryDb $ \conn -> do
        -- openDb already ran createSchema once (recording v=1).
        createSchema conn  -- second invocation: must be a no-op.
        versions <- map fromOnly <$> query_ conn
          "SELECT version FROM migrations"
          :: IO [Int]
        length versions `shouldBe` 1
