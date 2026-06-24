module OpenCode.Tool.GitHubSearch
  ( githubSearchTool
  , githubSearchSchema
  , githubHeaders
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
  , defaultRequest, withHeader, withQuery )
import OpenCode.Tool.Types (SomeTool (..), ToolDef (DynamicTool))
import OpenCode.Types (ApiKey (..))

-- ---------------------------------------------------------------------------
-- Input
-- ---------------------------------------------------------------------------

data GitHubSearchInput = GitHubSearchInput
  { gsiQuery :: Text
  , gsiLimit :: Maybe Int
  }

instance FromJSON GitHubSearchInput where
  parseJSON = withObject "GitHubSearchInput" $ \o -> GitHubSearchInput
    <$> o .:  "query"
    <*> o .:? "limit"

-- ---------------------------------------------------------------------------
-- Response
-- ---------------------------------------------------------------------------

newtype GitHubCodeResponse = GitHubCodeResponse { gcrItems :: [GitHubCodeItem] }
instance FromJSON GitHubCodeResponse where
  parseJSON = withObject "GitHubCodeResponse" $ \o -> GitHubCodeResponse
    <$> (o .:? "items" Aeson..!= [])

data GitHubCodeItem = GitHubCodeItem
  { gciPath :: Text
  , gciRepo :: Text
  , gciUrl  :: Text
  }
instance FromJSON GitHubCodeItem where
  parseJSON = withObject "GitHubCodeItem" $ \o -> do
    path <- o .: "path"
    repo <- o .: "repository" >>= (.: "full_name")
    url  <- o .: "html_url"
    pure GitHubCodeItem { gciPath = path, gciRepo = repo, gciUrl = url }

renderCodeResults :: [GitHubCodeItem] -> Text
renderCodeResults = Text.unlines . zipWith fmt [1 :: Int ..]
  where
    fmt i it = Text.pack (show i) <> ". " <> gciRepo it
            <> "/" <> gciPath it
            <> " : " <> gciUrl it

-- ---------------------------------------------------------------------------
-- Shared header builder
-- ---------------------------------------------------------------------------

githubHeaders :: ApiKey -> [(Text, Text)]
githubHeaders (ApiKey tok) =
  [ ("Authorization", "Bearer " <> tok)
  , ("Accept", "application/vnd.github+json")
  , ("User-Agent", "opencode-hs")
  ]

applyHeaders :: [(Text, Text)] -> HttpRequest -> HttpRequest
applyHeaders hs r = foldr (\(k, v) acc -> withHeader k v acc) r hs

-- ---------------------------------------------------------------------------
-- Schema & tool
-- ---------------------------------------------------------------------------

githubSearchSchema :: Value
githubSearchSchema = object
  [ "type" .= ("object" :: Text)
  , "properties" .= object
      [ "query" .= object
          [ "type" .= ("string" :: Text)
          , "description" .= ("GitHub code search query" :: Text)
          ]
      , "limit" .= object
          [ "type" .= ("integer" :: Text)
          , "description" .= ("Max results (default 10, max 30)" :: Text)
          ]
      ]
  , "required" .= (["query"] :: [Text])
  ]

githubSearchTool :: SomeTool
githubSearchTool = SomeTool
  { toolDef     = DynamicTool
  , toolName    = "github_search_code"
  , toolDesc    = "Search GitHub code. Returns repo/path + URL per match."
  , toolSchema  = githubSearchSchema
  , toolExecute = githubSearchExec
  , toolRender  = id
  }

-- ---------------------------------------------------------------------------
-- Executor
-- ---------------------------------------------------------------------------

githubSearchExec :: Value -> AppM Text
githubSearchExec args = do
  input <- case Aeson.fromJSON args of
    Aeson.Success i -> pure i
    Aeson.Error e   -> throwError (ToolError "github_search_code" (Text.pack e))
  backend <- asks envHttpBackend
  mKey <- asks (githubKey . envTools)
  case mKey of
    Nothing -> throwError (ToolError "github_search_code"
      "GitHub tools require GITHUB_TOKEN (env) or tools.githubToken (config.yaml).")
    Just key -> do
      let n = clampLimit (gsiLimit input)
          req = defaultRequest "https://api.github.com/search/code"
                  & withQuery "q" (gsiQuery input)
                  & withQuery "per_page" (Text.pack (show n))
                  & applyHeaders (githubHeaders key)
      runIt backend req
  where
    (&) :: a -> (a -> b) -> b
    x & f = f x

clampLimit :: Maybe Int -> Int
clampLimit = maybe 10 (\n -> max 1 (min 30 n))

runIt :: HttpBackend -> HttpRequest -> AppM Text
runIt backend req = do
  result <- liftIO (backend req)
  case result of
    Left err -> throwError (ToolError "github_search_code"
      ("HTTP " <> Text.pack (show (heStatus err)) <> ": " <> heBody err))
    Right body -> case Aeson.eitherDecodeStrict body of
      Left e   -> throwError (ToolError "github_search_code" ("decode error: " <> Text.pack e))
      Right rs -> pure (renderCodeResults (gcrItems rs))
