module OpenCode.Tool.GitHubSearchSpec (spec) where

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
import OpenCode.Tool.GitHubSearch (githubSearchTool)
import OpenCode.Types (ApiKey (..))

spec :: Spec
spec = describe "github_search_code tool" $ do

  it "renders matching repo/path + html_url" $ do
    fixture <- BS.readFile "test/fixtures/web/github/search-code.json"
    let backend = mockBackend [ ( "api.github.com/search/code", Right fixture ) ]
        reg = registerTool githubSearchTool emptyRegistry
        env = testEnv backend (Just "ghp-test")
        args = Aeson.object [ "query" Aeson..= ("OpenCode" :: Text) ]
    result <- runExceptT $ runReaderT (executeTool reg "github_search_code" args) env
    case result of
      Right t -> do
        Text.unpack t `shouldContain` "1."
        Text.unpack t `shouldContain` "dodofk/opencode-hs"
        Text.unpack t `shouldContain` "app/Main.hs"
      Left err -> expectationFailure (show err)

  it "errors when githubKey is missing" $ do
    let reg = registerTool githubSearchTool emptyRegistry
        env = testEnv (mockBackend []) Nothing
        args = Aeson.object [ "query" Aeson..= ("x" :: Text) ]
    result <- runExceptT $ runReaderT (executeTool reg "github_search_code" args) env
    case result of
      Right _  -> expectationFailure "expected ToolError for missing github key"
      Left err -> show err `shouldContain` "GITHUB_TOKEN"

  it "errors on 403 (rate limit / bad token)" $ do
    let backend = mockBackend [ ( "api.github.com", Left (HttpError 403 "rate limited") ) ]
        reg = registerTool githubSearchTool emptyRegistry
        env = testEnv backend (Just "ghp-test")
        args = Aeson.object [ "query" Aeson..= ("x" :: Text) ]
    result <- runExceptT $ runReaderT (executeTool reg "github_search_code" args) env
    case result of
      Right _  -> expectationFailure "expected ToolError for 403"
      Left err -> show err `shouldContain` "403"

testEnv :: HttpBackend -> Maybe Text -> AppEnv
testEnv backend mGithub = AppEnv
  { envConfig      = undefined
  , envDb          = undefined
  , envRegistry    = undefined
  , envEventChan   = undefined
  , envAbort       = undefined
  , envMcp         = []
  , envSkills      = []
  , envHttpBackend = backend
  , envTools       = ToolsConfig { braveKey = Nothing, githubKey = ApiKey <$> mGithub }
  }
