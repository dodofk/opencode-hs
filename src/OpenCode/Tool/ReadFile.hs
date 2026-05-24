-- | Tool: read a file (or a line range within it).
module OpenCode.Tool.ReadFile
  ( readFileTool
  , readFileSchema
  ) where

import Control.Exception (try, SomeException)
import Control.Monad.Except (throwError)
import Control.Monad.IO.Class (liftIO)
import Data.Aeson (Value, object, (.=))
import qualified Data.ByteString as BS
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import qualified Data.Text.Encoding.Error as Text

import OpenCode.App (AppError (..), AppM)
import OpenCode.Tool.Types
  ( ReadFileInput (..)
  , SomeTool (..)
  , ToolDef (ReadFileTool)
  )

-- | JSON Schema for the read_file tool input.
readFileSchema :: Value
readFileSchema = object
  [ "type"       .= ("object" :: Text)
  , "properties" .= object
      [ "path"   .= object
          [ "type"        .= ("string" :: Text)
          , "description" .= ("Path to the file to read" :: Text)
          ]
      , "offset" .= object
          [ "type"        .= ("integer" :: Text)
          , "description" .= ("1-based starting line number (omit for start of file)" :: Text)
          ]
      , "limit"  .= object
          [ "type"        .= ("integer" :: Text)
          , "description" .= ("Maximum number of lines to read (omit for whole file)" :: Text)
          ]
      ]
  , "required"   .= (["path"] :: [Text])
  ]

-- | The read_file 'SomeTool' value.
readFileTool :: SomeTool
readFileTool = SomeTool
  { toolDef     = ReadFileTool
  , toolName    = "read_file"
  , toolDesc    = "Read a file from disk. Optionally read a line range via offset/limit. Refuses binary files."
  , toolSchema  = readFileSchema
  , toolExecute = readFileExec
  , toolRender  = id
  }

-- ---------------------------------------------------------------------------
-- Executor
-- ---------------------------------------------------------------------------

maxBytes :: Int
maxBytes = 100 * 1024     -- 100 KB

probeBytes :: Int
probeBytes = 8 * 1024     -- first 8 KB for binary detection

readFileExec :: ReadFileInput -> AppM Text
readFileExec ReadFileInput { rfiPath = path, rfiOffset = offset, rfiLimit = limit } = do
  rawResult <- liftIO (try (BS.readFile path) :: IO (Either SomeException BS.ByteString))
  case rawResult of
    Left ex -> throwError (ToolError "read_file" (Text.pack ("read failed: " <> show ex)))
    Right raw -> do
      let probe = BS.take probeBytes raw
      if BS.elem 0 probe
        then throwError (ToolError "read_file" "binary file refused")
        else do
          -- Decode using lenient UTF-8 — broken codepoints become U+FFFD,
          -- never throw.
          let decoded = Text.decodeUtf8With Text.lenientDecode raw
              sliced  = applyOffsetLimit offset limit decoded
              capped  = cap maxBytes sliced (BS.length raw)
          pure capped

-- | Slice text by 1-based line offset + line count. If either bound is Nothing,
-- the corresponding end is unbounded. The output preserves trailing newlines.
applyOffsetLimit :: Maybe Int -> Maybe Int -> Text -> Text
applyOffsetLimit offset limit t =
  let allLines = Text.lines t
      startIdx = maybe 0 (\o -> max 0 (o - 1)) offset
      after    = drop startIdx allLines
      window   = maybe after (`take` after) limit
  in Text.unlines window

-- | Cap text at the given byte budget. If truncation occurs, append a marker
-- noting how many more bytes were skipped (computed against the original raw
-- byte length, not the decoded UTF-8 character length).
cap :: Int -> Text -> Int -> Text
cap budget t rawLen =
  let utf8len = BS.length (Text.encodeUtf8 t)
  in if utf8len <= budget
       then t
       else
         let kept = Text.decodeUtf8With Text.lenientDecode (BS.take budget (Text.encodeUtf8 t))
             dropped = rawLen - budget
         in kept <> Text.pack ("\n[truncated: " <> show dropped <> " more bytes]")
