-- | SQLite persistence layer for sessions and messages.
module OpenCode.DB
  ( -- * Connection
    openDb
  , defaultDbPath
    -- * Schema
  , createSchema
    -- * Sessions
  , insertSession
  , getSession
  , listSessions
  , newSessionId
    -- * Messages
  , insertMessage
  , getMessages
  , newMessageId
  ) where

import Control.Monad (forM_, unless, when)
import qualified Data.Aeson as Aeson
import Data.Aeson (FromJSON, ToJSON)
import qualified Data.ByteString.Lazy as BSL
import qualified Data.List.NonEmpty as NE
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Data.Time (UTCTime)
import Database.SQLite.Simple
  ( Connection
  , Only (..)
  , Query
  , execute
  , execute_
  , open
  , query
  , query_
  , withTransaction
  )
import qualified Data.UUID as UUID
import qualified Data.UUID.V4 as UUID
import System.Directory (XdgDirectory (XdgData), createDirectoryIfMissing, getXdgDirectory)
import System.FilePath (takeDirectory, (</>))

import OpenCode.Types
  ( Message (..)
  , MessageId (..)
  , MessagePart
  , Role (..)
  , Session (..)
  , SessionId (..)
  )

-- ---------------------------------------------------------------------------
-- Connection
-- ---------------------------------------------------------------------------

-- | Open a connection. Creates the parent directory if missing.
-- Runs 'createSchema' once on open (idempotent on subsequent opens).
openDb :: FilePath -> IO Connection
openDb path = do
  -- Skip mkdir for the SQLite in-memory sentinel.
  -- NOTE: only the plain ":memory:" sentinel is handled here; URI-mode
  -- in-memory paths (e.g. "file::memory:?cache=shared") are not used
  -- in this project. Revisit if that changes.
  when (path /= ":memory:") $
    createDirectoryIfMissing True (takeDirectory path)
  conn <- open path
  createSchema conn
  pure conn

-- ---------------------------------------------------------------------------
-- Schema migrations
-- ---------------------------------------------------------------------------

-- | Apply any pending schema migrations. Idempotent and atomic:
-- the read of applied versions and the application of new migrations
-- happen inside a single transaction.
createSchema :: Connection -> IO ()
createSchema conn = withTransaction conn $ do
  execute_ conn
    "CREATE TABLE IF NOT EXISTS migrations \
    \(version INTEGER PRIMARY KEY, applied_at TEXT NOT NULL)"
  applied <- map fromOnly <$> query_ conn
    "SELECT version FROM migrations" :: IO [Int]
  forM_ allMigrations $ \(v, stmts) ->
    unless (v `elem` applied) $ do
      mapM_ (execute_ conn) stmts
      execute conn
        "INSERT INTO migrations (version, applied_at) \
        \VALUES (?, datetime('now'))"
        (Only v)

-- | Ordered list of schema migrations. Append new versions; never
-- edit a version that has shipped.
allMigrations :: [(Int, [Query])]
allMigrations =
  [ ( 1
    , [ "CREATE TABLE sessions \
        \( id         TEXT PRIMARY KEY \
        \, title      TEXT NOT NULL \
        \, model_id   TEXT NOT NULL \
        \, created_at TEXT NOT NULL )"
      , "CREATE TABLE messages \
        \( id         TEXT PRIMARY KEY \
        \, session_id TEXT NOT NULL REFERENCES sessions(id) \
        \, role       TEXT NOT NULL \
        \, parts      TEXT NOT NULL \
        \, created_at TEXT NOT NULL )"
      ]
    )
  ]

-- ---------------------------------------------------------------------------
-- Stubs (filled in later tasks of M2)
-- ---------------------------------------------------------------------------

-- | Insert a session row. Caller supplies the id; use 'newSessionId' to mint one.
insertSession :: Connection -> Session -> IO ()
insertSession conn s = execute conn
  "INSERT INTO sessions (id, title, model_id, created_at) \
  \VALUES (?, ?, ?, ?)"
  ( unSessionId (sessionId s)
  , sessionTitle s
  , encodeJsonText (sessionModel s)
  , sessionCreated s
  )

-- | Look up a session by id. Returns Nothing if no row matches.
getSession :: Connection -> SessionId -> IO (Maybe Session)
getSession conn (SessionId sid) = do
  rows <- query conn
    "SELECT id, title, model_id, created_at \
    \FROM sessions WHERE id = ?"
    (Only sid)
    :: IO [(Text, Text, Text, UTCTime)]
  -- PRIMARY KEY on sessions.id guarantees at most one match.
  case rows of
    []                              -> pure Nothing
    ((rid, title, modelTx, ts):_)   ->
      case decodeJsonText modelTx of
        Left err -> error ("OpenCode.DB.getSession: model_id decode failed: " <> err)
        Right m  -> pure (Just (Session (SessionId rid) title m ts))

-- | List all sessions, newest first.
listSessions :: Connection -> IO [Session]
listSessions conn = do
  rows <- query_ conn
    "SELECT id, title, model_id, created_at \
    \FROM sessions ORDER BY created_at DESC"
    :: IO [(Text, Text, Text, UTCTime)]
  pure (map toSession rows)
  where
    toSession (sid, title, modelTx, ts) = case decodeJsonText modelTx of
      Right m  -> Session (SessionId sid) title m ts
      Left err -> error ("OpenCode.DB.listSessions: model_id decode failed: " <> err)

-- | Insert a message belonging to the given session. Caller supplies the id;
-- use 'newMessageId' to mint one.
insertMessage :: Connection -> SessionId -> Message -> IO ()
insertMessage conn (SessionId sid) m = execute conn
  "INSERT INTO messages (id, session_id, role, parts, created_at) \
  \VALUES (?, ?, ?, ?, ?)"
  ( unMessageId (msgId m)
  , sid
  , roleToText (msgRole m)
  , encodeJsonText (NE.toList (msgParts m))
  , msgCreated m
  )

-- | All messages for a session, oldest first (tiebreak by id).
getMessages :: Connection -> SessionId -> IO [Message]
getMessages conn (SessionId sid) = do
  rows <- query conn
    "SELECT id, role, parts, created_at \
    \FROM messages WHERE session_id = ? \
    \ORDER BY created_at ASC, id ASC"
    (Only sid)
    :: IO [(Text, Text, Text, UTCTime)]
  pure (map toMessage rows)
  where
    toMessage (mid, roleTx, partsTx, ts) =
      let role  = case textToRole roleTx of
            Right r  -> r
            Left err -> error ("OpenCode.DB.getMessages: role decode: " <> err)
          parts = case decodeJsonText partsTx :: Either String [MessagePart] of
            Right ps -> case NE.nonEmpty ps of
              Just ne -> ne
              Nothing -> error "OpenCode.DB.getMessages: empty parts list"
            Left err -> error ("OpenCode.DB.getMessages: parts decode: " <> err)
      in Message (MessageId mid) role parts ts

-- | Default location for the sessions database, per XDG.
-- On Linux/macOS: @$HOME/.local/share/opencode-hs/sessions.db@.
defaultDbPath :: IO FilePath
defaultDbPath = do
  dir <- getXdgDirectory XdgData "opencode-hs"
  pure (dir </> "sessions.db")

-- | Generate a fresh random SessionId (UUIDv4 in hyphenated form).
newSessionId :: IO SessionId
newSessionId = SessionId . UUID.toText <$> UUID.nextRandom

-- | Generate a fresh random MessageId (UUIDv4 in hyphenated form).
newMessageId :: IO MessageId
newMessageId = MessageId . UUID.toText <$> UUID.nextRandom

-- ---------------------------------------------------------------------------
-- JSON helpers (used by later tasks)
-- ---------------------------------------------------------------------------

encodeJsonText :: ToJSON a => a -> Text
encodeJsonText = Text.decodeUtf8 . BSL.toStrict . Aeson.encode

decodeJsonText :: FromJSON a => Text -> Either String a
decodeJsonText = Aeson.eitherDecodeStrict . Text.encodeUtf8

-- ---------------------------------------------------------------------------
-- Role text serialization (used by later tasks)
-- ---------------------------------------------------------------------------

roleToText :: Role -> Text
roleToText RoleUser      = "user"
roleToText RoleAssistant = "assistant"
roleToText RoleTool      = "tool"

textToRole :: Text -> Either String Role
textToRole "user"      = Right RoleUser
textToRole "assistant" = Right RoleAssistant
textToRole "tool"      = Right RoleTool
textToRole other       = Left ("unknown role: " <> Text.unpack other)
