module OpenCode.DBSpec (spec) where

import Control.Exception (bracket)
import qualified Data.List.NonEmpty as NE
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Time (UTCTime (..), fromGregorian)
import Database.SQLite.Simple
  ( Connection
  , Only (..)
  , close
  , query_
  )
import Test.Hspec

import OpenCode.DB
import OpenCode.Types
  ( Message (..)
  , MessageId (..)
  , MessagePart (..)
  , ModelId (..)
  , ProviderId (..)
  , Role (..)
  , Session (..)
  , SessionId (..)
  , ToolArgs (..)
  , ToolCall (..)
  , ToolResult (..)
  )

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

  describe "insertSession / getSession" $ do

    it "round-trips a session via insertSession then getSession" $
      withInMemoryDb $ \conn -> do
        let s = sampleSession (SessionId "s-1")
        insertSession conn s
        result <- getSession conn (SessionId "s-1")
        result `shouldBe` Just s

    it "returns Nothing for an unknown SessionId" $
      withInMemoryDb $ \conn -> do
        result <- getSession conn (SessionId "missing")
        result `shouldBe` Nothing

    it "round-trips a session with a non-default model" $
      withInMemoryDb $ \conn -> do
        let s = (sampleSession (SessionId "s-2"))
              { sessionModel = ModelId OpenAI "gpt-4o" }
        insertSession conn s
        result <- getSession conn (SessionId "s-2")
        result `shouldBe` Just s

  describe "listSessions" $ do

    it "returns an empty list when no sessions exist" $
      withInMemoryDb $ \conn -> do
        xs <- listSessions conn
        xs `shouldBe` []

    it "lists sessions ordered by created_at DESC (newest first)" $
      withInMemoryDb $ \conn -> do
        let s1 = (sampleSession (SessionId "old"))
              { sessionCreated = UTCTime (fromGregorian 2026 1 1) 0 }
            s2 = (sampleSession (SessionId "new"))
              { sessionCreated = UTCTime (fromGregorian 2026 5 1) 0 }
        insertSession conn s1
        insertSession conn s2
        xs <- listSessions conn
        map sessionId xs `shouldBe` [SessionId "new", SessionId "old"]

  describe "insertMessage / getMessages" $ do

    it "round-trips a single text message" $
      withInMemoryDb $ \conn -> do
        let sid = SessionId "s-msg-1"
        insertSession conn (sampleSession sid)
        let m = Message
              { msgId      = MessageId "m-1"
              , msgRole    = RoleUser
              , msgParts   = NE.fromList [TextPart "hello"]
              , msgCreated = t0
              }
        insertMessage conn sid m
        msgs <- getMessages conn sid
        msgs `shouldBe` [m]

    it "round-trips a message containing every MessagePart constructor" $
      withInMemoryDb $ \conn -> do
        let sid = SessionId "s-msg-2"
        insertSession conn (sampleSession sid)
        let m = Message
              { msgId      = MessageId "m-multi"
              , msgRole    = RoleAssistant
              , msgParts   = NE.fromList
                  [ TextPart "thinking\8230"
                  , ToolCallPart (ToolCall "c1" "bash" (ToolArgs "{\"cmd\":\"ls\"}"))
                  , ToolResultPart (ToolResult "c1" "file.txt\n" False)
                  , ErrorPart "boom"
                  ]
              , msgCreated = t0
              }
        insertMessage conn sid m
        msgs <- getMessages conn sid
        msgs `shouldBe` [m]

    it "preserves insertion order by created_at ASC" $
      withInMemoryDb $ \conn -> do
        let sid = SessionId "s-order"
        insertSession conn (sampleSession sid)
        let mk i secs = Message
              { msgId      = MessageId (Text.pack ("m-" <> show i))
              , msgRole    = RoleUser
              , msgParts   = NE.fromList [TextPart (Text.pack (show i))]
              , msgCreated = UTCTime (fromGregorian 2026 5 23)
                  (fromInteger secs)
              }
            m1 = mk (1 :: Int) 0
            m2 = mk (2 :: Int) 60
            m3 = mk (3 :: Int) 120
        -- Insert out of order; getMessages should reorder by created_at.
        insertMessage conn sid m3
        insertMessage conn sid m1
        insertMessage conn sid m2
        msgs <- getMessages conn sid
        map msgId msgs `shouldBe` [msgId m1, msgId m2, msgId m3]

    it "returns an empty list for a session with no messages" $
      withInMemoryDb $ \conn -> do
        let sid = SessionId "s-empty"
        insertSession conn (sampleSession sid)
        msgs <- getMessages conn sid
        msgs `shouldBe` []

-- ---------------------------------------------------------------------------
-- Fixtures
-- ---------------------------------------------------------------------------

t0 :: UTCTime
t0 = UTCTime (fromGregorian 2026 5 23) 0

sampleSession :: SessionId -> Session
sampleSession sid = Session
  { sessionId      = sid
  , sessionTitle   = "test session"
  , sessionModel   = ModelId Anthropic "claude-opus-4-7"
  , sessionCreated = t0
  }
