-- | SQLite persistence layer for sessions and messages.
-- Full implementation in M2; stubs here satisfy the type-checker.
module OpenCode.DB
  ( openDb
  , createSchema
  , insertSession
  , getSession
  , listSessions
  , insertMessage
  , getMessages
  ) where

import Database.SQLite.Simple (Connection)
import OpenCode.Types (Message, Session, SessionId)

-- ---------------------------------------------------------------------------
-- Stubs (implemented in M2)
-- ---------------------------------------------------------------------------

openDb :: FilePath -> IO Connection
openDb = error "OpenCode.DB.openDb: not yet implemented (M2)"

createSchema :: Connection -> IO ()
createSchema _ = pure ()

insertSession :: Connection -> Session -> IO ()
insertSession _ _ = pure ()

getSession :: Connection -> SessionId -> IO (Maybe Session)
getSession _ _ = pure Nothing

listSessions :: Connection -> IO [Session]
listSessions _ = pure []

insertMessage :: Connection -> SessionId -> Message -> IO ()
insertMessage _ _ _ = pure ()

getMessages :: Connection -> SessionId -> IO [Message]
getMessages _ _ = pure []
