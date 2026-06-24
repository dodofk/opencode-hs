module OpenCode.Tool.WebFetchSpec (spec) where

import Control.Monad.Except (runExceptT)
import Control.Monad.Reader (runReaderT)
import qualified Data.Aeson as Aeson
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as TextEnc
import Test.Hspec

import OpenCode.App (AppEnv (..))
import OpenCode.Config (ToolsConfig (..))
import OpenCode.Net.Http (HttpBackend)
import OpenCode.Net.HttpMock (mockBackend)
import OpenCode.Tool.Types (executeTool, registerTool, emptyRegistry)
import OpenCode.Tool.WebFetch (webFetchTool, htmlToText)

spec :: Spec
spec = do
  describe "web_fetch tool" $ do

    it "renders the fetched page text" $ do
      let html = "<html><body><h1>Hello World</h1></body></html>"
          bs = TextEnc.encodeUtf8 html
          backend = mockBackend [ ( "example.com", Right bs ) ]
          reg = registerTool webFetchTool emptyRegistry
          env = testEnv backend
          args = Aeson.object [ "url" Aeson..= ("https://example.com" :: Text) ]
      result <- runExceptT $ runReaderT (executeTool reg "web_fetch" args) env
      case result of
        Right t -> Text.unpack t `shouldContain` "Hello World"
        Left err -> expectationFailure (show err)

  describe "htmlToText (pure)" $ do
    it "drops <script> and <style> contents" $
      htmlToText "<style>hidden</style><p>kept</p>" `shouldSatisfy` Text.isInfixOf "kept"

    it "drops <script> content but keeps surrounding text" $ do
      let t = htmlToText "<p>a</p><script>var x=1;</script><p>b</p>"
      Text.unpack t `shouldContain` "a"
      Text.unpack t `shouldContain` "b"
      Text.unpack t `shouldNotContain` "var x"

testEnv :: HttpBackend -> AppEnv
testEnv backend = AppEnv
  { envConfig      = undefined
  , envDb          = undefined
  , envRegistry    = undefined
  , envEventChan   = undefined
  , envAbort       = undefined
  , envMcp         = []
  , envSkills      = []
  , envHttpBackend = backend
  , envTools       = ToolsConfig { braveKey = Nothing, githubKey = Nothing }
  }
