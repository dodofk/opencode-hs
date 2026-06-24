module OpenCode.Tool.WebFetch
  ( webFetchTool
  , webFetchSchema
  , htmlToText
  ) where

import Control.Monad.Except (throwError)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Reader (asks)
import Data.Aeson (FromJSON (..), Value, object, (.:), (.:?), (.=), withObject)
import qualified Data.Aeson as Aeson
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as TextEnc
import Data.Text.Encoding.Error (lenientDecode)
import Text.HTML.TagSoup (Tag (..), parseTags, isTagOpenName, isTagCloseName)

import OpenCode.App.Error (AppError (..))
import OpenCode.App.Types (AppEnv (..), AppM)
import OpenCode.Net.Http
  ( HttpError (..), defaultRequest, withHeader )
import OpenCode.Tool.Types (SomeTool (..), ToolDef (DynamicTool))

-- ---------------------------------------------------------------------------
-- Input
-- ---------------------------------------------------------------------------

data WebFetchInput = WebFetchInput
  { wfiUrl       :: Text
  , wfiMaxLength :: Maybe Int
  }

instance FromJSON WebFetchInput where
  parseJSON = withObject "WebFetchInput" $ \o -> WebFetchInput
    <$> o .:  "url"
    <*> o .:? "maxLength"

-- ---------------------------------------------------------------------------
-- HTML -> text (pure)
-- ---------------------------------------------------------------------------

htmlToText :: Text -> Text
htmlToText html =
    collapseSpaces
  . Text.unwords
  . filter (not . Text.null)
  . map (Text.pack . tagToText)
  $ stripDangerous (parseTags (Text.unpack html))
  where
    tagToText (TagText s)       = s
    tagToText (TagOpen "br" _)  = "\n"
    tagToText (TagOpen "p" _)   = "\n\n"
    tagToText (TagOpen "h1" _)  = "\n\n"
    tagToText (TagOpen "h2" _)  = "\n\n"
    tagToText (TagOpen "li" _)  = "\n- "
    tagToText _                 = ""

stripDangerous :: [Tag String] -> [Tag String]
stripDangerous = stripSection "head" . stripSection "script" . stripSection "style"
  where
    stripSection :: String -> [Tag String] -> [Tag String]
    stripSection _    []     = []
    stripSection name (t:ts)
      | isTagOpenName name t =
          let after = dropWhile (not . isTagCloseName name) ts
          in case after of
               (_close : rest) -> stripSection name rest
               []              -> []
      | otherwise = t : stripSection name ts

collapseSpaces :: Text -> Text
collapseSpaces = Text.unwords . Text.words

-- ---------------------------------------------------------------------------
-- Schema & tool
-- ---------------------------------------------------------------------------

webFetchSchema :: Value
webFetchSchema = object
  [ "type" .= ("object" :: Text)
  , "properties" .= object
      [ "url" .= object
          [ "type" .= ("string" :: Text)
          , "description" .= ("URL to fetch" :: Text)
          ]
      , "maxLength" .= object
          [ "type" .= ("integer" :: Text)
          , "description" .= ("Max chars to return (default 10000, hard cap 50000)" :: Text)
          ]
      ]
  , "required" .= (["url"] :: [Text])
  ]

webFetchTool :: SomeTool
webFetchTool = SomeTool
  { toolDef     = DynamicTool
  , toolName    = "web_fetch"
  , toolDesc    = "Fetch a URL and return its text content (HTML stripped). No auth required."
  , toolSchema  = webFetchSchema
  , toolExecute = webFetchExec
  , toolRender  = id
  }

-- ---------------------------------------------------------------------------
-- Executor
-- ---------------------------------------------------------------------------

webFetchExec :: Value -> AppM Text
webFetchExec args = do
  input <- case Aeson.fromJSON args of
    Aeson.Success i -> pure i
    Aeson.Error e   -> throwError (ToolError "web_fetch" (Text.pack e))
  backend <- asks envHttpBackend
  let req = defaultRequest (wfiUrl input)
            & withHeader "User-Agent" "opencode-hs/0.1 (Haskell agent)"
            & withHeader "Accept" "text/html, */*"
      (&) :: a -> (a -> b) -> b
      x & f = f x
  result <- liftIO (backend req)
  case result of
    Left (HttpError status body) -> throwError (ToolError "web_fetch"
      ("web_fetch HTTP " <> Text.pack (show status) <> ": " <> body))
    Right body ->
      let txt    = htmlToText (TextEnc.decodeUtf8With lenientDecode body)
          maxLen = clampLen (wfiMaxLength input)
      in pure (truncateTo maxLen txt)

clampLen :: Maybe Int -> Int
clampLen = maybe 10000 (\n -> max 1 (min 50000 n))

truncateTo :: Int -> Text -> Text
truncateTo maxLen t
  | Text.length t <= maxLen = t
  | otherwise = Text.take maxLen t <> "\n[... truncated ...]"
