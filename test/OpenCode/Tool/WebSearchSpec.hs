module OpenCode.Tool.WebSearchSpec (spec) where

import Control.Monad.Except (runExceptT)
import Control.Monad.Reader (runReaderT)
import qualified Data.Aeson as Aeson
import qualified Data.ByteString as BS
import Data.Text (Text)
import qualified Data.Text as Text
import Test.Hspec

import OpenCode.App (AppEnv (..))
import OpenCode.Config (ToolsConfig (..))
import OpenCode.Net.Http (HttpBackend, HttpError (..))
import OpenCode.Net.HttpMock (mockBackend)
import OpenCode.Tool.Types (executeTool, registerTool, emptyRegistry)
import OpenCode.Tool.WebSearch (webSearchTool)
import OpenCode.Types (ApiKey (..))

spec :: Spec
spec = describe "web_search tool" $ do

  it "renders results as a numbered title|url|snippet list" $ do
    fixture <- BS.readFile "test/fixtures/web/brave/search-haskell.json"
    let backend = mockBackend
          [ ( "search.brave.com", Right fixture ) ]
        reg = registerTool webSearchTool emptyRegistry
        env = testEnv backend (Just "BSA-test")
        args = Aeson.object [ "query" Aeson..= ("haskell" :: Text) ]
    result <- runExceptT $ runReaderT (executeTool reg "web_search" args) env
    case result of
      Right t -> do
        Text.unpack t `shouldContain` "1."
        Text.unpack t `shouldContain` "Haskell Language"
        Text.unpack t `shouldContain` "https://www.haskell.org/"
      Left err -> expectationFailure (show err)

  it "errors when braveKey is missing" $ do
    let reg = registerTool webSearchTool emptyRegistry
        env = testEnv (mockBackend []) Nothing
        args = Aeson.object [ "query" Aeson..= ("haskell" :: Text) ]
    result <- runExceptT $ runReaderT (executeTool reg "web_search" args) env
    case result of
      Right _  -> expectationFailure "expected ToolError for missing key"
      Left err -> show err `shouldContain` "BRAVE_API_KEY"

  it "errors on non-200 status" $ do
    let backend = mockBackend
          [ ( "search.brave.com", Left (HttpError 401 "unauthorized") ) ]
        reg = registerTool webSearchTool emptyRegistry
        env = testEnv backend (Just "BSA-test")
        args = Aeson.object [ "query" Aeson..= ("x" :: Text) ]
    result <- runExceptT $ runReaderT (executeTool reg "web_search" args) env
    case result of
      Right _  -> expectationFailure "expected ToolError for 401"
      Left err -> show err `shouldContain` "401"

testEnv :: HttpBackend -> Maybe Text -> AppEnv
testEnv backend mBrave = AppEnv
  { envConfig      = undefined
  , envDb          = undefined
  , envRegistry    = undefined
  , envEventChan   = undefined
  , envAbort       = undefined
  , envMcp         = []
  , envSkills      = []
  , envHttpBackend = backend
  , envTools       = ToolsConfig
      { braveKey  = ApiKey <$> mBrave
      , githubKey = Nothing
      }
  }
