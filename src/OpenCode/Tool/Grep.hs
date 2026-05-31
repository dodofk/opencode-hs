-- | Tool: search file contents for a substring. Uses ripgrep if available,
-- falls back to a pure-Haskell directory walk.
module OpenCode.Tool.Grep
  ( grepTool
  , grepSchema
    -- * Internals (exported for testing)
  , grepFallback
  ) where

import Control.Exception (SomeException, try)
import Control.Monad.Except (throwError)
import Control.Monad.IO.Class (liftIO)
import Data.Aeson (Value, object, (.=))
import qualified Data.Aeson as Aeson
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BSL
import Data.List (sort)
import Data.Maybe (fromMaybe, isJust, mapMaybe)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import qualified Data.Text.Encoding.Error as TextErr
import qualified System.Directory as Dir
import System.Exit (ExitCode (..))
import qualified System.FilePath as FP
import qualified System.Process as Proc

import OpenCode.App (AppError (..))
import OpenCode.App.Types (AppM)
import OpenCode.Tool.Types
  ( GrepInput (..)
  , GrepMatch (..)
  , SomeTool (..)
  , ToolDef (GrepTool)
  )

-- ---------------------------------------------------------------------------
-- Tool value
-- ---------------------------------------------------------------------------

grepTool :: SomeTool
grepTool = SomeTool
  { toolDef     = GrepTool
  , toolName    = "grep"
  , toolDesc    = "Search file contents for a substring. Uses ripgrep (rg) if on PATH, else falls back to a directory walk. Results capped at 500 matches."
  , toolSchema  = grepSchema
  , toolExecute = grepExec
  , toolRender  = renderMatches
  }

renderMatches :: [GrepMatch] -> Text
renderMatches = Text.decodeUtf8With TextErr.lenientDecode . BSL.toStrict . Aeson.encode

-- ---------------------------------------------------------------------------
-- JSON Schema
-- ---------------------------------------------------------------------------

grepSchema :: Value
grepSchema = object
  [ "type"       .= ("object" :: Text)
  , "properties" .= object
      [ "pattern" .= object
          [ "type"        .= ("string" :: Text)
          , "description" .= ("Substring to search for (literal, not regex)" :: Text)
          ]
      , "path"    .= object
          [ "type"        .= ("string" :: Text)
          , "description" .= ("File or directory to search (default: current directory)" :: Text)
          ]
      , "recursive" .= object
          [ "type"        .= ("boolean" :: Text)
          , "description" .= ("Recurse into subdirectories when path is a directory" :: Text)
          ]
      ]
  , "required"   .= (["pattern"] :: [Text])
  ]

-- ---------------------------------------------------------------------------
-- Executor
-- ---------------------------------------------------------------------------

maxMatches :: Int
maxMatches = 500

grepExec :: GrepInput -> AppM [GrepMatch]
grepExec GrepInput { griPattern = pat, griPath = mPath, griRecursive = mRecursive } = do
  let path      = fromMaybe "." mPath
      recursive = fromMaybe False mRecursive   -- default: non-recursive
  attempt <- liftIO $ try $ do
    rgAvailable <- isJust <$> Dir.findExecutable "rg"
    if rgAvailable
      then grepWithRg pat path
      else grepFallback pat path recursive
  case attempt :: Either SomeException [GrepMatch] of
    Left ex       -> throwError (ToolError "grep" (Text.pack ("grep failed: " <> show ex)))
    Right matches -> pure (take maxMatches matches)

-- ---------------------------------------------------------------------------
-- ripgrep path
-- ---------------------------------------------------------------------------

grepWithRg :: Text -> FilePath -> IO [GrepMatch]
grepWithRg pat path = do
  let args = ["--json", "--fixed-strings", Text.unpack pat, path]
  (exitCode, stdoutStr, _stderrStr) <-
    Proc.readProcessWithExitCode "rg" args ""
  case exitCode of
    ExitSuccess   -> pure (parseRgOutput stdoutStr)
    ExitFailure 1 -> pure []  -- rg exits 1 when no matches; not an error
    ExitFailure n -> error ("rg exited with " <> show n)

-- | Parse ripgrep's --json output: one JSON object per line; we keep only
-- objects of type "match" and extract path/line_number/lines.text.
parseRgOutput :: String -> [GrepMatch]
parseRgOutput out =
  let bsLines = filter (not . BS.null) (BS.split 10 (Text.encodeUtf8 (Text.pack out)))
  in mapMaybe lineToMatch bsLines
  where
    lineToMatch :: BS.ByteString -> Maybe GrepMatch
    lineToMatch bs = case Aeson.eitherDecodeStrict bs of
      Left _   -> Nothing
      Right (Aeson.Object o) ->
        case KM.lookup "type" o of
          Just (Aeson.String "match") -> do
            dataObj <- case KM.lookup "data" o of
              Just (Aeson.Object d) -> Just d
              _                     -> Nothing
            pathTxt <- case KM.lookup "path" dataObj of
              Just (Aeson.Object pObj) -> case KM.lookup "text" pObj of
                Just (Aeson.String s) -> Just (Text.unpack s)
                _                     -> Nothing
              _                        -> Nothing
            lineNum <- case KM.lookup "line_number" dataObj of
              Just (Aeson.Number n) -> Just (floor n :: Int)
              _                     -> Nothing
            lineTxt <- case KM.lookup "lines" dataObj of
              Just (Aeson.Object lObj) -> case KM.lookup "text" lObj of
                Just (Aeson.String s) -> Just s
                _                     -> Nothing
              _                        -> Nothing
            Just GrepMatch
              { gmFile = pathTxt
              , gmLine = lineNum
              , gmText = stripTrailingNewline lineTxt
              }
          _ -> Nothing
      Right _ -> Nothing

    stripTrailingNewline t = case Text.unsnoc t of
      Just (rest, '\n') -> rest
      _                 -> t

-- ---------------------------------------------------------------------------
-- Fallback path (no ripgrep)
-- ---------------------------------------------------------------------------

grepFallback :: Text -> FilePath -> Bool -> IO [GrepMatch]
grepFallback pat path recursive = do
  isFile <- Dir.doesFileExist path
  isDir  <- Dir.doesDirectoryExist path
  files <-
    if isFile then pure [path]
    else if isDir then enumerateFiles recursive path
    else pure []
  concat <$> mapM (grepFile pat) files

enumerateFiles :: Bool -> FilePath -> IO [FilePath]
enumerateFiles recursive root = do
  entries <- Dir.listDirectory root
  let qualified = map (root FP.</>) entries
  results <- mapM expand qualified
  pure (sort (concat results))
  where
    expand p = do
      isDir <- Dir.doesDirectoryExist p
      if isDir && recursive
        then enumerateFiles recursive p
        else do
          isFile <- Dir.doesFileExist p
          pure [p | isFile]

grepFile :: Text -> FilePath -> IO [GrepMatch]
grepFile pat path = do
  attempt <- try (BS.readFile path) :: IO (Either SomeException BS.ByteString)
  case attempt of
    Left _    -> pure []
    Right raw -> do
      let content = Text.decodeUtf8With TextErr.lenientDecode raw
          ls      = zip [1 :: Int ..] (Text.lines content)
          hits    = [(n, line) | (n, line) <- ls, pat `Text.isInfixOf` line]
      pure [GrepMatch { gmFile = path, gmLine = n, gmText = line } | (n, line) <- hits]
