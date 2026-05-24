-- | Tool: match files against a glob pattern.
module OpenCode.Tool.Glob
  ( globTool
  , globSchema
  ) where

import Control.Exception (SomeException, try)
import Control.Monad.Except (throwError)
import Control.Monad.IO.Class (liftIO)
import Data.Aeson (Value, object, (.=))
import qualified Data.Aeson as Aeson
import qualified Data.ByteString.Lazy as BSL
import Data.List (sort)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import qualified Data.Text.Encoding.Error as TextErr
import qualified System.Directory as Dir
import qualified System.FilePath as FP
import System.FilePath ((</>))
import qualified System.FilePath.Glob as Glob

import OpenCode.App.Error (AppError (..))
import OpenCode.App.Types (AppM)
import OpenCode.Tool.Types
  ( GlobInput (..)
  , SomeTool (..)
  , ToolDef (GlobTool)
  )

-- ---------------------------------------------------------------------------
-- Tool value
-- ---------------------------------------------------------------------------

globTool :: SomeTool
globTool = SomeTool
  { toolDef     = GlobTool
  , toolName    = "glob"
  , toolDesc    = "Match files against a glob pattern (e.g. '**/*.hs'). Results sorted, capped at 500 entries with a truncated marker. Excludes paths matching a sibling .gitignore (simple line-prefix exclusion)."
  , toolSchema  = globSchema
  , toolExecute = globExec
  , toolRender  = renderPaths
  }

renderPaths :: [FilePath] -> Text
renderPaths = Text.decodeUtf8With TextErr.lenientDecode . BSL.toStrict . Aeson.encode

-- ---------------------------------------------------------------------------
-- JSON Schema
-- ---------------------------------------------------------------------------

globSchema :: Value
globSchema = object
  [ "type"       .= ("object" :: Text)
  , "properties" .= object
      [ "pattern" .= object
          [ "type"        .= ("string" :: Text)
          , "description" .= ("Glob pattern (e.g. '**/*.hs')" :: Text)
          ]
      , "root"    .= object
          [ "type"        .= ("string" :: Text)
          , "description" .= ("Root directory to search from (default: current directory)" :: Text)
          ]
      ]
  , "required"   .= (["pattern"] :: [Text])
  ]

-- ---------------------------------------------------------------------------
-- Executor
-- ---------------------------------------------------------------------------

maxMatches :: Int
maxMatches = 500

truncatedMarker :: FilePath
truncatedMarker = "\x2026truncated"

globExec :: GlobInput -> AppM [FilePath]
globExec GlobInput { giPattern = pat, giRoot = mRoot } = do
  let root = fromMaybe "." mRoot
  attempt <- liftIO (try (runGlobIO root (Text.unpack pat))
                      :: IO (Either SomeException [FilePath]))
  case attempt of
    Left ex          -> throwError (ToolError "glob" (Text.pack ("glob failed: " <> show ex)))
    Right rawMatches -> do
      ignorePrefixes <- liftIO (readGitignore root)
      let filtered = filter (not . isIgnored ignorePrefixes) rawMatches
          sorted   = sort filtered
      pure $ if length sorted > maxMatches
        then take maxMatches sorted ++ [truncatedMarker]
        else sorted

-- | Run the glob lookup and return root-relative paths.
runGlobIO :: FilePath -> String -> IO [FilePath]
runGlobIO root patternStr = do
  matches <- Glob.glob (root </> patternStr)
  pure (map (FP.makeRelative root) matches)

-- | Read the .gitignore at @root/.gitignore@ if it exists. Each non-empty,
-- non-comment line becomes a path prefix that matches are filtered against.
-- Trailing slashes are stripped for matching.
readGitignore :: FilePath -> IO [String]
readGitignore root = do
  let path = root </> ".gitignore"
  exists <- Dir.doesFileExist path
  if not exists
    then pure []
    else do
      contents <- readFile path
      pure
        [ stripTrailingSlash line
        | line <- lines contents
        , not (null line)
        , head line /= '#'
        ]
  where
    stripTrailingSlash s
      | not (null s) && last s == '/' = init s
      | otherwise                     = s

-- | Does the path's first segment match any .gitignore prefix?
isIgnored :: [String] -> FilePath -> Bool
isIgnored prefixes path = any matchesPrefix prefixes
  where
    matchesPrefix prefix =
      case FP.splitDirectories path of
        (firstSeg : _) -> firstSeg == prefix
        []             -> False
