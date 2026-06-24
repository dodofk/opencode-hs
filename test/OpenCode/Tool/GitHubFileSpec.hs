module OpenCode.Tool.GitHubFileSpec (spec) where

import Control.Monad.Except (runExceptT)
import Control.Monad.Reader (runReaderT)
import qualified Data.Aeson as Aeson
import qualified Data.ByteString as BS
import Data.Text (Text)
import qualified Data.Text as Text
import Test.Hspec

import OpenCode.App (AppEnv (..))
import OpenCode.Config (ToolsConfig (..))
import OpenCode.Net.Http (HttpBackend)
import OpenCode.Net.HttpMock (mockBackend)
import OpenCode.Tool.Types (executeTool, registerTool, emptyRegistry)
import OpenCode.Tool.GitHubFile (githubFileTool)
import OpenCode.Types (ApiKey (..))

spec :: Spec
spec = describe "github_fetch_file tool" $ do

  it "decodes base64 content and returns file text" $ do
    fixture <- BS.readFile "test/fixtures/web/github/contents.json"
    let backend = mockBackend [ ( "api.github.com/repos", Right fixture ) ]
        reg = registerTool githubFileTool emptyRegistry
        env = testEnv backend (Just "ghp-test")
        args = Aeson.object
          [ "repo" Aeson..= ("dodofk/opencode-hs" :: Text)
          , "path" Aeson..= ("app/Main.hs" :: Text)
          ]
    result <- runExceptT $ runReaderT (executeTool reg "github_fetch_file" args) env
    case result of
      Right t -> Text.unpack t `shouldContain` "module Main where"
      Left err -> expectationFailure (show err)

  it "errors when githubKey is missing" $ do
    let reg = registerTool githubFileTool emptyRegistry
        env = testEnv (mockBackend []) Nothing
        args = Aeson.object [ "repo" Aeson..= ("x/y" :: Text), "path" Aeson..= ("f" :: Text) ]
    result <- runExceptT $ runReaderT (executeTool reg "github_fetch_file" args) env
    case result of
      Right _  -> expectationFailure "expected ToolError"
      Left err -> show err `shouldContain` "GITHUB_TOKEN"

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
