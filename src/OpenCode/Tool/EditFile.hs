-- | Tool: edit a file by replacing an exact unique substring.
module OpenCode.Tool.EditFile
  ( editFileTool
  , editFileSchema
  ) where

import Control.Exception (try, SomeException)
import Control.Monad.Except (throwError)
import Control.Monad.IO.Class (liftIO)
import Data.Aeson (Value, object, (.=))
import qualified Data.Algorithm.Diff as Diff
import qualified Data.ByteString as BS
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import qualified Data.Text.Encoding.Error as TextErr
import System.Directory (renameFile)

import OpenCode.App (AppError (..), AppM)
import OpenCode.Tool.Types
  ( EditFileInput (..)
  , SomeTool (..)
  , ToolDef (EditFileTool)
  )

-- | JSON Schema for the edit_file tool input.
editFileSchema :: Value
editFileSchema = object
  [ "type"       .= ("object" :: Text)
  , "properties" .= object
      [ "path"      .= object
          [ "type"        .= ("string" :: Text)
          , "description" .= ("Path to the file to edit" :: Text)
          ]
      , "oldString" .= object
          [ "type"        .= ("string" :: Text)
          , "description" .= ("Exact substring to find (must match exactly once)" :: Text)
          ]
      , "newString" .= object
          [ "type"        .= ("string" :: Text)
          , "description" .= ("Replacement text" :: Text)
          ]
      ]
  , "required"   .= (["path", "oldString", "newString"] :: [Text])
  ]

editFileTool :: SomeTool
editFileTool = SomeTool
  { toolDef     = EditFileTool
  , toolName    = "edit_file"
  , toolDesc    = "Replace a unique substring in a file. Errors if the substring is missing or matches more than once."
  , toolSchema  = editFileSchema
  , toolExecute = editFileExec
  , toolRender  = id
  }

-- ---------------------------------------------------------------------------
-- Executor
-- ---------------------------------------------------------------------------

editFileExec :: EditFileInput -> AppM Text
editFileExec EditFileInput { efiPath = path, efiOldString = oldStr, efiNewString = newStr } = do
  readResult <- liftIO (try (BS.readFile path) :: IO (Either SomeException BS.ByteString))
  case readResult of
    Left ex -> throwError (ToolError "edit_file" (Text.pack ("read failed: " <> show ex)))
    Right raw -> do
      let before = Text.decodeUtf8With TextErr.lenientDecode raw
          n      = countOccurrences oldStr before
      case n of
        0 -> throwError (ToolError "edit_file" "not found")
        k | k > 1 -> throwError (ToolError "edit_file"
                                  (Text.pack ("ambiguous: " <> show k <> " matches")))
        _ -> do
          let after = Text.replace oldStr newStr before
              tmp   = path <> ".tmp"
          writeResult <- liftIO $ try $ do
            BS.writeFile tmp (Text.encodeUtf8 after)
            renameFile tmp path
          case writeResult :: Either SomeException () of
            Left ex -> throwError (ToolError "edit_file"
                                    (Text.pack ("write failed: " <> show ex)))
            Right () -> pure (renderDiff before after)

-- | Count non-overlapping occurrences of a substring.
countOccurrences :: Text -> Text -> Int
countOccurrences needle hay
  | Text.null needle = 0
  | otherwise        = length (Text.breakOnAll needle hay)

-- | Render a per-line diff between two Text values in a unified-ish style.
-- Unchanged lines: prefixed with two spaces.
-- Removed lines: prefixed with "- ".
-- Added lines: prefixed with "+ ".
renderDiff :: Text -> Text -> Text
renderDiff before after =
  let bs = Text.lines before
      as = Text.lines after
      groups = Diff.getGroupedDiff bs as
  in Text.unlines (concatMap renderGroup groups)
  where
    renderGroup (Diff.Both xs _) = map ("  " <>) xs
    renderGroup (Diff.First  xs) = map ("- " <>) xs
    renderGroup (Diff.Second xs) = map ("+ " <>) xs
