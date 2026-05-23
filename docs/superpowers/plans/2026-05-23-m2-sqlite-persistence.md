# M2 — SQLite Persistence Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add round-trippable SQLite persistence for `Session` and `Message`, with an idempotent migration system and id-generation helpers, wiring the open `Connection` into `AppEnv`.

**Architecture:** A single `OpenCode.DB` module owns connection management, schema versioning (via a `migrations` table), and CRUD against two tables: `sessions` (one row per session) and `messages` (one row per message, with `parts` JSON-encoded as text). Timestamps use ISO8601 via `sqlite-simple`'s built-in `UTCTime` instances. `ModelId` is JSON-encoded in `sessions.model_id`. `Role` is stored as the plain strings `"user" | "assistant" | "tool"` for schema readability. UUIDs for new ids are minted via `Data.UUID.V4.nextRandom`.

**Tech stack:** `sqlite-simple 0.4.18+`, `aeson 2.1+`, `uuid 1.3+`, `time 1.12+`, `directory 1.3+`. Tests use `hspec` + `QuickCheck` against `:memory:` SQLite (with temp-file fallback for one path-construction check). All deps already listed in `package.yaml`.

---

## File structure

| Path | Action | Responsibility |
| ---- | ------ | -------------- |
| `src/OpenCode/DB.hs` | replace stubs | Connection, schema migrations, session+message CRUD, id/path helpers |
| `src/OpenCode/App.hs` | edit | Add `envDb :: Connection` field to `AppEnv` |
| `test/OpenCode/DBSpec.hs` | create | All tests for the DB module (auto-discovered by `hspec-discover`) |

No changes to `package.yaml` / `opencode-hs.cabal` — every required dep is already present. The Wno-unused-top-binds GHC flag in `package.yaml` allows the helpers to compile before they're called by other modules.

---

## Schema

```sql
CREATE TABLE migrations (
  version    INTEGER PRIMARY KEY,
  applied_at TEXT NOT NULL
);

CREATE TABLE sessions (
  id         TEXT PRIMARY KEY,
  title      TEXT NOT NULL,
  model_id   TEXT NOT NULL,   -- JSON-encoded ModelId
  created_at TEXT NOT NULL    -- ISO8601 UTC
);

CREATE TABLE messages (
  id         TEXT PRIMARY KEY,
  session_id TEXT NOT NULL REFERENCES sessions(id),
  role       TEXT NOT NULL,   -- "user" | "assistant" | "tool"
  parts      TEXT NOT NULL,   -- JSON-encoded NonEmpty MessagePart
  created_at TEXT NOT NULL    -- ISO8601 UTC
);
```

`messages.session_id` declares the foreign key for documentation, but `PRAGMA foreign_keys = ON` is NOT enabled in M2 — enforcement would force test orderings without adding value at this stage; revisit in M12.

---

## Toolchain note

`stack`/`ghc` are not on the default `$PATH` in non-interactive shells on this machine — they're at `~/.ghcup/bin`. Every shell command below prefixes with `export PATH="$HOME/.ghcup/bin:$PATH" &&`.

---

## Task 1 — `openDb` + `createSchema` with migration tracking

**Files:**
- Create: `test/OpenCode/DBSpec.hs`
- Modify: `src/OpenCode/DB.hs`

- [ ] **Step 1.1: Create the failing test file**

Write `test/OpenCode/DBSpec.hs`:

```haskell
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
```

- [ ] **Step 1.2: Run tests to confirm they fail**

```
export PATH="$HOME/.ghcup/bin:$PATH" && stack test --match "OpenCode.DB"
```

Expected: the test executable links, then **fails** at `openDb` with `OpenCode.DB.openDb: not yet implemented (M2)`. (The stub in `src/OpenCode/DB.hs:21` raises this error.)

- [ ] **Step 1.3: Replace `src/OpenCode/DB.hs` with implementation skeleton**

Rewrite the file (NOT a partial edit — overwrite). Note: stubs for the not-yet-implemented functions are kept so the module compiles in isolation; they're replaced in later tasks.

```haskell
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
  -- ":memory:" has no real parent directory; skip the mkdir.
  when (path /= ":memory:") $
    createDirectoryIfMissing True (takeDirectory path)
  conn <- open path
  createSchema conn
  pure conn

-- ---------------------------------------------------------------------------
-- Schema migrations
-- ---------------------------------------------------------------------------

-- | Apply any pending schema migrations. Idempotent.
createSchema :: Connection -> IO ()
createSchema conn = do
  execute_ conn
    "CREATE TABLE IF NOT EXISTS migrations \
    \(version INTEGER PRIMARY KEY, applied_at TEXT NOT NULL)"
  applied <- map fromOnly <$> query_ conn
    "SELECT version FROM migrations" :: IO [Int]
  forM_ allMigrations $ \(v, stmts) ->
    when (v `notElem` applied) $ withTransaction conn $ do
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
-- Stubs (filled in later tasks)
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
```

Note: GHC will warn about unused imports (`NonEmpty`, `NE`, `UUID`, `MessagePart`, `MessageId`, helpers, role functions) and unused top-level bindings (`encodeJsonText`, `decodeJsonText`, `roleToText`, `textToRole`). `Wno-unused-top-binds` in `package.yaml` allows this for now. The unused-import warning is not suppressed — if the build fails on that, prefix the imports with `_` via the alias `import qualified X as _X`. Simpler alternative: tighten the imports task-by-task as you introduce the call sites in Tasks 2 onward. **For Task 1 only, you may add `-Wno-unused-imports` for `OpenCode.DB` via a `{-# OPTIONS_GHC -Wno-unused-imports #-}` pragma at the top of the file; remove it once Task 4 lands and all imports are referenced.**

- [ ] **Step 1.4: Run tests to confirm they pass**

```
export PATH="$HOME/.ghcup/bin:$PATH" && stack test --match "OpenCode.DB"
```

Expected: all five `createSchema` specs pass; existing 36 tests still pass.

- [ ] **Step 1.5: Commit**

```
git add src/OpenCode/DB.hs test/OpenCode/DBSpec.hs
git commit -m "M2: openDb + createSchema with migration tracking"
```

---

## Task 2 — `insertSession` + `getSession`

**Files:**
- Modify: `src/OpenCode/DB.hs`
- Modify: `test/OpenCode/DBSpec.hs`

- [ ] **Step 2.1: Append session round-trip tests to `DBSpec.hs`**

Add imports near the top of `test/OpenCode/DBSpec.hs`:

```haskell
import Data.Time (UTCTime (..), fromGregorian)

import OpenCode.Types
  ( ModelId (..)
  , ProviderId (..)
  , Session (..)
  , SessionId (..)
  )
```

Add at the bottom of the `spec` do-block:

```haskell
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
```

And add a fixtures section at the bottom of the file:

```haskell
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
```

- [ ] **Step 2.2: Run tests to confirm new specs fail**

```
export PATH="$HOME/.ghcup/bin:$PATH" && stack test --match "insertSession / getSession"
```

Expected: 3 failures, each pointing at `OpenCode.DB.insertSession: not yet implemented` or `OpenCode.DB.getSession: not yet implemented`.

- [ ] **Step 2.3: Implement `insertSession` and `getSession`**

In `src/OpenCode/DB.hs`, replace the two stubs:

```haskell
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
  case rows of
    []                           -> pure Nothing
    ((rid, title, modelTx, ts):_) ->
      case decodeJsonText modelTx of
        Left err -> error ("OpenCode.DB.getSession: model_id decode failed: " <> err)
        Right m  -> pure (Just (Session (SessionId rid) title m ts))
```

You will also need to add `UTCTime` to the existing time import in `OpenCode/DB.hs`:

```haskell
import Data.Time (UTCTime)
```

- [ ] **Step 2.4: Run tests to confirm they pass**

```
export PATH="$HOME/.ghcup/bin:$PATH" && stack test --match "OpenCode.DB"
```

Expected: all `createSchema` + `insertSession / getSession` specs pass.

- [ ] **Step 2.5: Commit**

```
git add src/OpenCode/DB.hs test/OpenCode/DBSpec.hs
git commit -m "M2: insertSession + getSession round-trip"
```

---

## Task 3 — `listSessions` with ordering

**Files:**
- Modify: `src/OpenCode/DB.hs`
- Modify: `test/OpenCode/DBSpec.hs`

- [ ] **Step 3.1: Append `listSessions` tests**

Add to `spec` in `test/OpenCode/DBSpec.hs`:

```haskell
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
```

- [ ] **Step 3.2: Run tests to confirm new specs fail**

```
export PATH="$HOME/.ghcup/bin:$PATH" && stack test --match "listSessions"
```

Expected: 2 failures from `OpenCode.DB.listSessions: not yet implemented`.

- [ ] **Step 3.3: Implement `listSessions`**

In `src/OpenCode/DB.hs`, replace the stub:

```haskell
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
```

- [ ] **Step 3.4: Run tests to confirm pass**

```
export PATH="$HOME/.ghcup/bin:$PATH" && stack test --match "OpenCode.DB"
```

Expected: all DB specs pass so far.

- [ ] **Step 3.5: Commit**

```
git add src/OpenCode/DB.hs test/OpenCode/DBSpec.hs
git commit -m "M2: listSessions ordered by created_at DESC"
```

---

## Task 4 — `insertMessage` + `getMessages` (with MessagePart coverage)

**Files:**
- Modify: `src/OpenCode/DB.hs`
- Modify: `test/OpenCode/DBSpec.hs`

- [ ] **Step 4.1: Append message round-trip tests**

Add imports to `test/OpenCode/DBSpec.hs`:

```haskell
import qualified Data.List.NonEmpty as NE

import OpenCode.Types
  ( Message (..)
  , MessageId (..)
  , MessagePart (..)
  , Role (..)
  , ToolArgs (..)
  , ToolCall (..)
  , ToolResult (..)
  )
```

(Merge with existing `OpenCode.Types` import — keep one consolidated import list.)

Add to `spec`:

```haskell
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
                  [ TextPart "thinking…"
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
            m2 = mk 2 60
            m3 = mk 3 120
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
```

Also add `import qualified Data.Text as Text` if not already present.

- [ ] **Step 4.2: Run tests to confirm new specs fail**

```
export PATH="$HOME/.ghcup/bin:$PATH" && stack test --match "insertMessage / getMessages"
```

Expected: 4 failures from `OpenCode.DB.insertMessage: not yet implemented` / `getMessages`.

- [ ] **Step 4.3: Implement `insertMessage` and `getMessages`**

In `src/OpenCode/DB.hs`, replace the two stubs:

```haskell
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
```

If you added the `{-# OPTIONS_GHC -Wno-unused-imports #-}` pragma in Task 1, you can now safely remove it — every import in `OpenCode/DB.hs` is referenced.

- [ ] **Step 4.4: Run tests to confirm pass**

```
export PATH="$HOME/.ghcup/bin:$PATH" && stack test --match "OpenCode.DB"
```

Expected: all DB specs pass (createSchema, insertSession/getSession, listSessions, insertMessage/getMessages).

- [ ] **Step 4.5: Commit**

```
git add src/OpenCode/DB.hs test/OpenCode/DBSpec.hs
git commit -m "M2: insertMessage + getMessages with JSON parts and ordering"
```

---

## Task 5 — Property-based round-trip for Message

**Files:**
- Modify: `test/OpenCode/DBSpec.hs`

- [ ] **Step 5.1: Add QuickCheck generators and property**

Add imports to `test/OpenCode/DBSpec.hs`:

```haskell
import Data.Time (Day (..), secondsToDiffTime)
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck
  ( Gen
  , choose
  , elements
  , forAll
  , ioProperty
  , listOf1
  , oneof
  , resize
  )
```

Add to the bottom of the file (after the fixtures section):

```haskell
-- ---------------------------------------------------------------------------
-- Generators
-- ---------------------------------------------------------------------------

genUtcTime :: Gen UTCTime
genUtcTime = do
  day  <- ModifiedJulianDay <$> choose (40000, 70000)
  secs <- secondsToDiffTime <$> choose (0, 86399)
  pure (UTCTime day secs)

genText :: Gen Text
genText = Text.pack
  <$> listOf1 (elements (['a'..'z'] ++ ['0'..'9'] ++ " \n.,_-"))

genShortText :: Gen Text
genShortText = Text.pack
  <$> resize 12 (listOf1 (elements (['a'..'z'] ++ ['0'..'9'])))

genRole :: Gen Role
genRole = elements [RoleUser, RoleAssistant, RoleTool]

genToolCall :: Gen ToolCall
genToolCall = ToolCall
  <$> genShortText
  <*> genShortText
  <*> (ToolArgs <$> genText)

genToolResult :: Gen ToolResult
genToolResult = ToolResult
  <$> genShortText
  <*> genText
  <*> elements [True, False]

genMessagePart :: Gen MessagePart
genMessagePart = oneof
  [ TextPart        <$> genText
  , ToolCallPart    <$> genToolCall
  , ToolResultPart  <$> genToolResult
  , ErrorPart       <$> genText
  ]

genMessage :: Gen Message
genMessage = Message
  <$> (MessageId <$> genShortText)
  <*> genRole
  <*> (NE.fromList <$> resize 4 (listOf1 genMessagePart))
  <*> genUtcTime
```

Add the property inside `spec`:

```haskell
  describe "property — message round-trip" $
    prop "any generated Message round-trips through SQLite byte-for-byte" $
      forAll genMessage $ \m -> ioProperty $
        bracket (openDb ":memory:") close $ \conn -> do
          let sid = SessionId "prop-sess"
          insertSession conn (sampleSession sid)
          insertMessage conn sid m
          msgs <- getMessages conn sid
          pure (msgs == [m])
```

(Default `prop` uses `maxSuccess = 100`, matching the acceptance criterion.)

- [ ] **Step 5.2: Run the property test**

```
export PATH="$HOME/.ghcup/bin:$PATH" && stack test --match "property — message round-trip"
```

Expected: PASS with `+++ OK, passed 100 tests.`

- [ ] **Step 5.3: Commit**

```
git add test/OpenCode/DBSpec.hs
git commit -m "M2: property test — 100 random Messages round-trip through SQLite"
```

---

## Task 6 — `defaultDbPath`, `newSessionId`, `newMessageId`

**Files:**
- Modify: `src/OpenCode/DB.hs`
- Modify: `test/OpenCode/DBSpec.hs`

- [ ] **Step 6.1: Add helper tests**

Add imports to `test/OpenCode/DBSpec.hs`:

```haskell
import Data.List (isSuffixOf, nub)
import System.FilePath ((</>))
```

Add to `spec`:

```haskell
  describe "helpers" $ do

    it "defaultDbPath ends with opencode-hs/sessions.db" $ do
      p <- defaultDbPath
      (("opencode-hs" </> "sessions.db") `isSuffixOf` p) `shouldBe` True

    it "newSessionId yields a non-empty Text" $ do
      SessionId t <- newSessionId
      Text.length t `shouldSatisfy` (> 0)

    it "newSessionId is collision-free across 100 calls" $ do
      sids <- mapM (const newSessionId) [1 :: Int .. 100]
      length sids `shouldBe` length (nub sids)

    it "newMessageId yields a non-empty Text" $ do
      MessageId t <- newMessageId
      Text.length t `shouldSatisfy` (> 0)
```

- [ ] **Step 6.2: Run tests to confirm fail**

```
export PATH="$HOME/.ghcup/bin:$PATH" && stack test --match "helpers"
```

Expected: 4 failures from `OpenCode.DB.{defaultDbPath,newSessionId,newMessageId}: not yet implemented`.

- [ ] **Step 6.3: Implement the helpers**

In `src/OpenCode/DB.hs`, replace the three stubs:

```haskell
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
```

- [ ] **Step 6.4: Run tests to confirm pass**

```
export PATH="$HOME/.ghcup/bin:$PATH" && stack test --match "OpenCode.DB"
```

Expected: every DB spec passes; total spec count now includes helpers.

- [ ] **Step 6.5: Commit**

```
git add src/OpenCode/DB.hs test/OpenCode/DBSpec.hs
git commit -m "M2: defaultDbPath, newSessionId, newMessageId helpers"
```

---

## Task 7 — Add `envDb` to `AppEnv`

**Files:**
- Modify: `src/OpenCode/App.hs`

- [ ] **Step 7.1: Add `envDb :: Connection` field to `AppEnv`**

Open `src/OpenCode/App.hs`. The current definition is:

```haskell
data AppEnv = AppEnv
  { envConfig :: Config
  -- envDb      :: Connection      -- added in M2
  ...
  }
```

Replace it with:

```haskell
data AppEnv = AppEnv
  { envConfig :: Config
  , envDb     :: Connection
  -- envRegistry :: ToolRegistry   -- added in M5
  -- envEventChan :: BChan …       -- added in M6
  -- envAbort     :: TVar Bool     -- added in M6
  }
```

Add the import at the top of the same file:

```haskell
import Database.SQLite.Simple (Connection)
```

- [ ] **Step 7.2: Build the whole project to ensure no callers broke**

```
export PATH="$HOME/.ghcup/bin:$PATH" && stack build
```

Expected: clean build, no warnings. (No site currently constructs an `AppEnv`, so adding a field is mechanically safe; we still build to be sure.)

- [ ] **Step 7.3: Run the full test suite**

```
export PATH="$HOME/.ghcup/bin:$PATH" && stack test
```

Expected: all tests pass (the prior 36 from M0/M1 plus every DB spec added in this milestone).

- [ ] **Step 7.4: Commit**

```
git add src/OpenCode/App.hs
git commit -m "M2: wire Connection into AppEnv as envDb"
```

---

## Task 8 — Acceptance verification

**Files:** none (verification only)

- [ ] **Step 8.1: Confirm `stack test --match "OpenCode.DB"` passes**

```
export PATH="$HOME/.ghcup/bin:$PATH" && stack test --match "OpenCode.DB"
```

Expected: all DB specs report PASS; final line `N examples, 0 failures` where N ≥ 14 (5 createSchema + 3 insertSession/getSession + 2 listSessions + 4 insertMessage/getMessages + 1 property + 4 helpers).

- [ ] **Step 8.2: Confirm the property test ran 100 iterations**

```
export PATH="$HOME/.ghcup/bin:$PATH" && stack test --match "property — message round-trip" 2>&1 | grep "passed"
```

Expected output contains: `+++ OK, passed 100 tests.`

- [ ] **Step 8.3: Inspect a real on-disk schema with `sqlite3`**

The unit tests in Task 1 (`sessions table has the SPEC §3.6 columns` / `messages table has the SPEC §3.6 columns`) already assert the columns programmatically. As an additional manual confirmation per the M2 acceptance criterion, write a one-shot verify script:

Create `test/Driver/VerifySchema.hs`:

```haskell
module Main where

import Database.SQLite.Simple (close)
import OpenCode.DB (openDb)

main :: IO ()
main = openDb "/tmp/m2-verify.db" >>= close
```

Add to `package.yaml` (under `executables:`):

```yaml
  m2-verify-schema:
    main:         VerifySchema.hs
    source-dirs:  test/Driver
    dependencies:
      - opencode-hs
      - sqlite-simple
```

Run:

```
export PATH="$HOME/.ghcup/bin:$PATH" && rm -f /tmp/m2-verify.db && stack run m2-verify-schema && sqlite3 /tmp/m2-verify.db ".schema"
```

Expected output contains (in some order; whitespace may vary):

```
CREATE TABLE migrations (version INTEGER PRIMARY KEY, applied_at TEXT NOT NULL);
CREATE TABLE sessions ( id         TEXT PRIMARY KEY, title      TEXT NOT NULL, model_id   TEXT NOT NULL, created_at TEXT NOT NULL );
CREATE TABLE messages ( id         TEXT PRIMARY KEY, session_id TEXT NOT NULL REFERENCES sessions(id), role       TEXT NOT NULL, parts      TEXT NOT NULL, created_at TEXT NOT NULL );
```

Confirm columns match SPEC §3.6. Keep the driver in tree — it's small, builds with the project, and is the documented way to spot-check the schema on disk.

- [ ] **Step 8.4: Confirm git history is clean**

```
git status && git log --oneline -8
```

Expected: working tree clean; the most recent 7 commits are the per-task commits from this plan (Tasks 1–7).

- [ ] **Step 8.5: Update `MILESTONES.md` status snapshot**

In `MILESTONES.md`, change the M2 row of the Status snapshot table from:

```
| M2  | SQLite Persistence                     | pending   | —                  |
```

to (substitute `<sha>` with the head commit short SHA, e.g. from `git log -1 --pretty=%h`):

```
| M2  | SQLite Persistence                     | done      | `<sha>`            |
```

Commit:

```
git add MILESTONES.md
git commit -m "M2: mark milestone done in status snapshot"
```

---

## Out of scope for M2 (do NOT add)

- Foreign key enforcement (`PRAGMA foreign_keys = ON`) — deferred to M12.
- Indexes beyond the primary keys — none needed at v1 scale; revisit if profiling shows a problem.
- A `deleteSession` / `deleteMessage` API — no caller yet.
- WAL mode / pragma tuning — not in spec.
- An `AppM`-level wrapper around the DB functions — `OpenCode.DB` exposes plain `IO`; callers in M6 (Session loop) will lift through `liftIO'` from `OpenCode.App`.
- Anything from M3 (CI), M4 (LLM), M5+ (tools, session, TUI).
