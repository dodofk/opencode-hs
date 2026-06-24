module OpenCode.Tool.GitHubFile
  ( githubFileTool
  , githubFileSchema
  ) where

import Control.Monad.Except (throwError)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Reader (asks)
import Data.Aeson (FromJSON (..), Value, object, (.:), (.:?), (.=), withObject)
import qualified Data.Aeson as Aeson
import qualified Data.ByteString.Base64 as B64
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as TextEnc
import Data.Text.Encoding.Error (lenientDecode)

import OpenCode.App.Error (AppError (..))
import OpenCode.App.Types (AppEnv (..), AppM)
import OpenCode.Config (ToolsConfig (..))
import OpenCode.Net.Http
  ( HttpBackend, HttpError (..), HttpRequest
  , defaultRequest, withHeader, withQuery )
import OpenCode.Tool.GitHubSearch (githubHeaders)
import OpenCode.Tool.Types (SomeTool (..), ToolDef (DynamicTool))

-- ---------------------------------------------------------------------------
-- Input
-- ---------------------------------------------------------------------------

data GitHubFileInput = GitHubFileInput
  { gfiRepo :: Text
  , gfiPath :: Text
  , gfiRef  :: Maybe Text
  }

instance FromJSON GitHubFileInput where
  parseJSON = withObject "GitHubFileInput" $ \o -> GitHubFileInput
    <$> o .:  "repo"
    <*> o .:  "path"
    <*> o .:? "ref"

-- ---------------------------------------------------------------------------
-- Response
-- ---------------------------------------------------------------------------

data GitHubContents = GitHubContents
  { gcContent  :: Text
  , _gcEncoding :: Text
  }
instance FromJSON GitHubContents where
  parseJSON = withObject "GitHubContents" $ \o -> GitHubContents
    <$> (o .:? "content" Aeson..!= "")
    <*> (o .:? "encoding" Aeson..!= "base64")

decodeFileContent :: Text -> Either String Text
decodeFileContent b64text = do
  let cleaned = TextEnc.encodeUtf8 (Text.filter (/= '\n') b64text)
  bytes <- B64.decode cleaned
  Right (TextEnc.decodeUtf8With lenientDecode bytes)

fileUrl :: GitHubFileInput -> Text
fileUrl input =
  "https://api.github.com/repos/" <> gfiRepo input
    <> "/contents/" <> gfiPath input

-- ---------------------------------------------------------------------------
-- Schema & tool
-- ---------------------------------------------------------------------------

githubFileSchema :: Value
githubFileSchema = object
  [ "type" .= ("object" :: Text)
  , "properties" .= object
      [ "repo" .= object [ "type" .= ("string" :: Text), "description" .= ("owner/name" :: Text) ]
      , "path" .= object [ "type" .= ("string" :: Text), "description" .= ("path within the repo" :: Text) ]
      , "ref"  .= object [ "type" .= ("string" :: Text), "description" .= ("git ref (default branch if omitted)" :: Text) ]
      ]
  , "required" .= (["repo", "path"] :: [Text])
  ]

githubFileTool :: SomeTool
githubFileTool = SomeTool
  { toolDef     = DynamicTool
  , toolName    = "github_fetch_file"
  , toolDesc    = "Fetch a file's text from a GitHub repo via the contents API."
  , toolSchema  = githubFileSchema
  , toolExecute = githubFileExec
  , toolRender  = id
  }

-- ---------------------------------------------------------------------------
-- Executor
-- ---------------------------------------------------------------------------

applyHeaders :: [(Text, Text)] -> HttpRequest -> HttpRequest
applyHeaders hs r = foldr (\(k, v) acc -> withHeader k v acc) r hs

githubFileExec :: Value -> AppM Text
githubFileExec args = do
  input <- case Aeson.fromJSON args of
    Aeson.Success i -> pure i
    Aeson.Error e   -> throwError (ToolError "github_fetch_file" (Text.pack e))
  backend <- asks envHttpBackend
  mKey <- asks (githubKey . envTools)
  case mKey of
    Nothing -> throwError (ToolError "github_fetch_file"
      "GitHub tools require GITHUB_TOKEN (env) or tools.githubToken (config.yaml).")
    Just key -> do
      let base = defaultRequest (fileUrl input) & applyHeaders (githubHeaders key)
          req  = case gfiRef input of
            Nothing  -> base
            Just ref -> base & withQuery "ref" ref
      runIt backend req
  where
    (&) :: a -> (a -> b) -> b
    x & f = f x

runIt :: HttpBackend -> HttpRequest -> AppM Text
runIt backend req = do
  result <- liftIO (backend req)
  case result of
    Left err -> throwError (ToolError "github_fetch_file"
      ("HTTP " <> Text.pack (show (heStatus err)) <> ": " <> heBody err))
    Right body -> case Aeson.eitherDecodeStrict body of
      Left e    -> throwError (ToolError "github_fetch_file" ("decode error: " <> Text.pack e))
      Right cnt -> case decodeFileContent (gcContent cnt) of
        Left e   -> throwError (ToolError "github_fetch_file" ("base64 decode failed: " <> Text.pack e))
        Right tx -> pure (truncateFile tx)

truncateFile :: Text -> Text
truncateFile t
  | Text.length t > 10000 = Text.take 10000 t <> "\n[...truncated...]"
  | otherwise = t
