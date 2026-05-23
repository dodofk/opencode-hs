-- | SQLite persistence layer for sessions and messages.
{-# OPTIONS_GHC -Wno-unused-imports #-}
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

import Control.Monad (forM_, when)
import qualified Data.Aeson as Aeson
import Data.Aeson (FromJSON, ToJSON)
import qualified Data.ByteString.Lazy as BSL
import Data.List.NonEmpty (NonEmpty)
import qualified Data.List.NonEmpty as NE
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import qualified Data.UUID as UUID
import qualified Data.UUID.V4 as UUID
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
import System.Directory
  ( XdgDirectory (XdgData)
  , createDirectoryIfMissing
  , getXdgDirectory
  )
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
    when (v `notElem` applied) $ do
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

insertSession :: Connection -> Session -> IO ()
insertSession _ _ = error "OpenCode.DB.insertSession: not yet implemented"

getSession :: Connection -> SessionId -> IO (Maybe Session)
getSession _ _ = error "OpenCode.DB.getSession: not yet implemented"

listSessions :: Connection -> IO [Session]
listSessions _ = error "OpenCode.DB.listSessions: not yet implemented"

insertMessage :: Connection -> SessionId -> Message -> IO ()
insertMessage _ _ _ = error "OpenCode.DB.insertMessage: not yet implemented"

getMessages :: Connection -> SessionId -> IO [Message]
getMessages _ _ = error "OpenCode.DB.getMessages: not yet implemented"

newSessionId :: IO SessionId
newSessionId = error "OpenCode.DB.newSessionId: not yet implemented"

newMessageId :: IO MessageId
newMessageId = error "OpenCode.DB.newMessageId: not yet implemented"

defaultDbPath :: IO FilePath
defaultDbPath = error "OpenCode.DB.defaultDbPath: not yet implemented"

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
