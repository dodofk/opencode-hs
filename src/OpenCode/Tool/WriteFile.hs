-- | Tool: write (or overwrite) a file atomically.
module OpenCode.Tool.WriteFile
  ( writeFileTool
  , writeFileSchema
  ) where

import Control.Exception (try, SomeException)
import Control.Monad.Except (throwError)
import Control.Monad.IO.Class (liftIO)
import Data.Aeson (Value, object, (.=))
import qualified Data.ByteString as BS
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import System.Directory (createDirectoryIfMissing, renameFile)
import System.FilePath (takeDirectory)

import OpenCode.App (AppError (..), AppM)
import OpenCode.Tool.Types
  ( SomeTool (..)
  , ToolDef (WriteFileTool)
  , WriteFileInput (..)
  )

-- | JSON Schema for the write_file tool input.
writeFileSchema :: Value
writeFileSchema = object
  [ "type"       .= ("object" :: Text)
  , "properties" .= object
      [ "path"    .= object
          [ "type"        .= ("string" :: Text)
          , "description" .= ("Path to the file to write (parents created if missing)" :: Text)
          ]
      , "content" .= object
          [ "type"        .= ("string" :: Text)
          , "description" .= ("File contents (UTF-8)" :: Text)
          ]
      ]
  , "required"   .= (["path", "content"] :: [Text])
  ]

writeFileTool :: SomeTool
writeFileTool = SomeTool
  { toolDef     = WriteFileTool
  , toolName    = "write_file"
  , toolDesc    = "Write (or overwrite) a file atomically. Creates parent directories if missing."
  , toolSchema  = writeFileSchema
  , toolExecute = writeFileExec
  , toolRender  = id
  }

-- ---------------------------------------------------------------------------
-- Executor
-- ---------------------------------------------------------------------------

writeFileExec :: WriteFileInput -> AppM Text
writeFileExec WriteFileInput { wfiPath = path, wfiContent = content } = do
  let bytes = Text.encodeUtf8 content
      tmp   = path <> ".tmp"
  attempt <- liftIO $ try $ do
    createDirectoryIfMissing True (takeDirectory path)
    BS.writeFile tmp bytes
    renameFile tmp path
  case attempt :: Either SomeException () of
    Left ex  -> throwError (ToolError "write_file" (Text.pack ("write failed: " <> show ex)))
    Right () -> pure (Text.pack ("wrote " <> show (BS.length bytes) <> " bytes to " <> path))
