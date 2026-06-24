module OpenCode.Tool.GitHubIssue
  ( githubIssueTool
  , githubIssueSchema
  ) where

import Control.Monad.Except (throwError)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Reader (asks)
import Data.Aeson (FromJSON (..), Value, object, (.:), (.:?), (.=), withObject)
import qualified Data.Aeson as Aeson
import Data.Text (Text)
import qualified Data.Text as Text

import OpenCode.App.Error (AppError (..))
import OpenCode.App.Types (AppEnv (..), AppM)
import OpenCode.Config (ToolsConfig (..))
import OpenCode.Net.Http
  ( HttpBackend, HttpError (..), HttpRequest
  , defaultRequest, withHeader )
import OpenCode.Tool.GitHubSearch (githubHeaders)
import OpenCode.Tool.Types (SomeTool (..), ToolDef (DynamicTool))

-- ---------------------------------------------------------------------------
-- Input
-- ---------------------------------------------------------------------------

data GitHubIssueInput = GitHubIssueInput
  { giiRepo   :: Text
  , giiNumber :: Int
  , giiKind   :: Maybe Text
  }

instance FromJSON GitHubIssueInput where
  parseJSON = withObject "GitHubIssueInput" $ \o -> GitHubIssueInput
    <$> o .:  "repo"
    <*> o .:  "number"
    <*> o .:? "kind"

-- ---------------------------------------------------------------------------
-- Response
-- ---------------------------------------------------------------------------

data GitHubIssue = GitHubIssue
  { giTitle  :: Text
  , giState  :: Text
  , giAuthor :: Text
  , giBody   :: Text
  , giLabels :: [Text]
  }
instance FromJSON GitHubIssue where
  parseJSON = withObject "GitHubIssue" $ \o -> do
    labels <- o .:? "labels" Aeson..!= [] >>= traverse (.: "name")
    GitHubIssue
      <$> o .:  "title"
      <*> o .:  "state"
      <*> (o .: "user" >>= (.: "login"))
      <*> (o .:? "body" Aeson..!= "")
      <*> pure labels

renderIssue :: GitHubIssue -> Text
renderIssue i = Text.unlines
  [ "Title: " <> giTitle i
  , "State: " <> giState i
  , "Author: " <> giAuthor i
  , "Labels: " <> Text.intercalate ", " (giLabels i)
  , "Body:"
  , truncateBody (giBody i)
  ]
  where
    truncateBody b
      | Text.length b > 4000 = Text.take 4000 b <> "\n[...truncated...]"
      | otherwise = b

issueUrl :: GitHubIssueInput -> Text
issueUrl input =
  let seg = if giiKind input == Just "pr" then "pulls" else "issues"
  in "https://api.github.com/repos/" <> giiRepo input
     <> "/" <> seg <> "/" <> Text.pack (show (giiNumber input))

-- ---------------------------------------------------------------------------
-- Schema & tool
-- ---------------------------------------------------------------------------

githubIssueSchema :: Value
githubIssueSchema = object
  [ "type" .= ("object" :: Text)
  , "properties" .= object
      [ "repo"   .= object [ "type" .= ("string" :: Text), "description" .= ("owner/name, e.g. dodofk/opencode-hs" :: Text) ]
      , "number" .= object [ "type" .= ("integer" :: Text), "description" .= ("Issue or PR number" :: Text) ]
      , "kind"   .= object [ "type" .= ("string" :: Text), "description" .= ("\"issue\" (default) or \"pr\"" :: Text) ]
      ]
  , "required" .= (["repo", "number"] :: [Text])
  ]

githubIssueTool :: SomeTool
githubIssueTool = SomeTool
  { toolDef     = DynamicTool
  , toolName    = "github_read_issue"
  , toolDesc    = "Read a GitHub issue or PR by repo + number. kind defaults to issue."
  , toolSchema  = githubIssueSchema
  , toolExecute = githubIssueExec
  , toolRender  = id
  }

-- ---------------------------------------------------------------------------
-- Executor
-- ---------------------------------------------------------------------------

applyHeaders :: [(Text, Text)] -> HttpRequest -> HttpRequest
applyHeaders hs r = foldr (\(k, v) acc -> withHeader k v acc) r hs

githubIssueExec :: Value -> AppM Text
githubIssueExec args = do
  input <- case Aeson.fromJSON args of
    Aeson.Success i -> pure i
    Aeson.Error e   -> throwError (ToolError "github_read_issue" (Text.pack e))
  backend <- asks envHttpBackend
  mKey <- asks (githubKey . envTools)
  case mKey of
    Nothing -> throwError (ToolError "github_read_issue"
      "GitHub tools require GITHUB_TOKEN (env) or tools.githubToken (config.yaml).")
    Just key -> do
      let req = defaultRequest (issueUrl input)
                  & applyHeaders (githubHeaders key)
      runIt backend req
  where
    (&) :: a -> (a -> b) -> b
    x & f = f x

runIt :: HttpBackend -> HttpRequest -> AppM Text
runIt backend req = do
  result <- liftIO (backend req)
  case result of
    Left err -> throwError (ToolError "github_read_issue"
      ("HTTP " <> Text.pack (show (heStatus err)) <> ": " <> heBody err))
    Right body -> case Aeson.eitherDecodeStrict body of
      Left e   -> throwError (ToolError "github_read_issue" ("decode error: " <> Text.pack e))
      Right i  -> pure (renderIssue i)
