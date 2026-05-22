-- | SQLite persistence layer for sessions and messages.
module OpenCode.DB
  ( openDb
  , createSchema
  , insertSession
  , getSession
  , listSessions
  , insertMessage
  , getMessages
  ) where

import Data.Time (UTCTime)
import Database.SQLite.Simple (Connection)
import OpenCode.Types

-- ---------------------------------------------------------------------------
-- Session record
-- ---------------------------------------------------------------------------

data SessionRow = SessionRow
  { rowId        :: SessionId
  , rowTitle     :: String
  , rowModelId   :: ModelId
  , rowCreatedAt :: UTCTime
  }
  deriving stock (Show, Eq)

-- ---------------------------------------------------------------------------
-- Stubs (implemented in M2)
-- ---------------------------------------------------------------------------

openDb :: FilePath -> IO Connection
openDb = error "OpenCode.DB.openDb: not yet implemented"

createSchema :: Connection -> IO ()
createSchema _ = pure ()

insertSession :: Connection -> SessionRow -> IO ()
insertSession _ _ = pure ()

getSession :: Connection -> SessionId -> IO (Maybe SessionRow)
getSession _ _ = pure Nothing

listSessions :: Connection -> IO [SessionRow]
listSessions _ = pure []

insertMessage :: Connection -> SessionId -> Message -> IO ()
insertMessage _ _ _ = pure ()

getMessages :: Connection -> SessionId -> IO [Message]
getMessages _ _ = pure []
