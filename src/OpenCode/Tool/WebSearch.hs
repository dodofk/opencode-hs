module OpenCode.Tool.WebSearch
  ( webSearchTool
  , webSearchSchema
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
  ( HttpBackend, HttpError (..), HttpRequest, defaultRequest, withHeader, withQuery )
import OpenCode.Tool.Types (SomeTool (..), ToolDef (DynamicTool))
import OpenCode.Types (ApiKey (..))

-- ---------------------------------------------------------------------------
-- Input
-- ---------------------------------------------------------------------------

data WebSearchInput = WebSearchInput
  { wsiQuery :: Text
  , wsiCount :: Maybe Int
  }

instance FromJSON WebSearchInput where
  parseJSON = withObject "WebSearchInput" $ \o -> WebSearchInput
    <$> o .:  "query"
    <*> o .:? "count"

-- ---------------------------------------------------------------------------
-- Brave response shape
-- ---------------------------------------------------------------------------

newtype BraveResponse = BraveResponse { brWeb :: BraveWeb }
instance FromJSON BraveResponse where
  parseJSON = withObject "BraveResponse" $ \o -> BraveResponse <$> o .: "web"

newtype BraveWeb = BraveWeb { bwResults :: [BraveResult] }
instance FromJSON BraveWeb where
  parseJSON = withObject "BraveWeb" $ \o -> BraveWeb <$> o .:? "results" Aeson..!= []

data BraveResult = BraveResult
  { brTitle       :: Text
  , brUrl         :: Text
  , brDescription :: Text
  }
instance FromJSON BraveResult where
  parseJSON = withObject "BraveResult" $ \o -> BraveResult
    <$> o .:  "title"
    <*> o .:  "url"
    <*> (o .:? "description" Aeson..!= "")

-- ---------------------------------------------------------------------------
-- Rendering
-- ---------------------------------------------------------------------------

renderResults :: [BraveResult] -> Text
renderResults = Text.unlines . zipWith fmt [1 :: Int ..]
  where
    fmt i r = Text.pack (show i) <> ". " <> brTitle r
           <> " | " <> brUrl r
           <> " | " <> brDescription r

-- ---------------------------------------------------------------------------
-- Schema & tool
-- ---------------------------------------------------------------------------

webSearchSchema :: Value
webSearchSchema = object
  [ "type" .= ("object" :: Text)
  , "properties" .= object
      [ "query" .= object
          [ "type" .= ("string" :: Text)
          , "description" .= ("Search query" :: Text)
          ]
      , "count" .= object
          [ "type" .= ("integer" :: Text)
          , "description" .= ("Max results (default 5, max 20)" :: Text)
          ]
      ]
  , "required" .= (["query"] :: [Text])
  ]

webSearchTool :: SomeTool
webSearchTool = SomeTool
  { toolDef     = DynamicTool
  , toolName    = "web_search"
  , toolDesc    = "Search the web via Brave Search. Returns a numbered list of title | url | snippet."
  , toolSchema  = webSearchSchema
  , toolExecute = webSearchExec
  , toolRender  = id
  }

-- ---------------------------------------------------------------------------
-- Executor
-- ---------------------------------------------------------------------------

webSearchExec :: Value -> AppM Text
webSearchExec args = do
  input <- decodeInput args
  backend <- asks envHttpBackend
  mKey <- asks (braveKey . envTools)
  case mKey of
    Nothing -> throwError (ToolError "web_search"
      "Brave Search requires BRAVE_API_KEY (env) or tools.braveApiKey (config.yaml).")
    Just (ApiKey key) -> do
      let n = clampCount (wsiCount input)
          req = defaultRequest "https://api.search.brave.com/res/v1/web/search"
                  & withQuery "q" (wsiQuery input)
                  & withQuery "count" (Text.pack (show n))
                  & withHeader "X-Subscription-Token" key
                  & withHeader "Accept" "application/json"
      runSearch backend req
  where
    (&) :: a -> (a -> b) -> b
    x & f = f x

clampCount :: Maybe Int -> Int
clampCount = maybe 5 (\n -> max 1 (min 20 n))

decodeInput :: Value -> AppM WebSearchInput
decodeInput v = case Aeson.fromJSON v of
  Aeson.Success i -> pure i
  Aeson.Error e   -> throwError (ToolError "web_search" (Text.pack e))

runSearch :: HttpBackend -> HttpRequest -> AppM Text
runSearch backend req = do
  result <- liftIO (backend req)
  case result of
    Left err -> throwError (ToolError "web_search" (renderHttpError err))
    Right body -> case Aeson.eitherDecodeStrict body of
      Left e   -> throwError (ToolError "web_search" ("Brave decode error: " <> Text.pack e))
      Right br -> pure (renderResults (bwResults (brWeb br)))

renderHttpError :: HttpError -> Text
renderHttpError (HttpError status body) =
  "web_search HTTP " <> Text.pack (show status) <> ": " <> body
