module OpenCode.Tool.GitHubIssueSpec (spec) where

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
import OpenCode.Tool.GitHubIssue (githubIssueTool)
import OpenCode.Types (ApiKey (..))

spec :: Spec
spec = describe "github_read_issue tool" $ do

  it "renders an issue's title/state/author/body" $ do
    fixture <- BS.readFile "test/fixtures/web/github/issue.json"
    let backend = mockBackend [ ( "api.github.com/repos", Right fixture ) ]
        reg = registerTool githubIssueTool emptyRegistry
        env = testEnv backend (Just "ghp-test")
        args = Aeson.object
          [ "repo" Aeson..= ("dodofk/opencode-hs" :: Text)
          , "number" Aeson..= (1 :: Int)
          ]
    result <- runExceptT $ runReaderT (executeTool reg "github_read_issue" args) env
    case result of
      Right t -> do
        Text.unpack t `shouldContain` "Example issue"
        Text.unpack t `shouldContain` "open"
        Text.unpack t `shouldContain` "octocat"
        Text.unpack t `shouldContain` "issue body"
      Left err -> expectationFailure (show err)

  it "hits /pulls/ when kind=pr" $ do
    fixture <- BS.readFile "test/fixtures/web/github/issue.json"
    let backend = mockBackend
          [ ( "api.github.com/repos/dodofk/opencode-hs/pulls/1", Right fixture ) ]
        reg = registerTool githubIssueTool emptyRegistry
        env = testEnv backend (Just "ghp-test")
        args = Aeson.object
          [ "repo" Aeson..= ("dodofk/opencode-hs" :: Text)
          , "number" Aeson..= (1 :: Int)
          , "kind" Aeson..= ("pr" :: Text)
          ]
    result <- runExceptT $ runReaderT (executeTool reg "github_read_issue" args) env
    case result of
      Right _  -> pure ()
      Left err -> expectationFailure (show err)

  it "errors when githubKey is missing" $ do
    let reg = registerTool githubIssueTool emptyRegistry
        env = testEnv (mockBackend []) Nothing
        args = Aeson.object
          [ "repo" Aeson..= ("x/y" :: Text), "number" Aeson..= (1 :: Int) ]
    result <- runExceptT $ runReaderT (executeTool reg "github_read_issue" args) env
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
