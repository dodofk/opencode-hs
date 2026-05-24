module OpenCode.Tool.TypesSpec (spec) where

import Control.Monad.Except (runExceptT)
import Control.Monad.Reader (runReaderT)
import Data.Aeson (Value, object, (.=))
import qualified Data.Aeson as Aeson
import qualified Data.ByteString.Lazy.Char8 as BL
import Data.Text (Text)
import qualified Data.Text as Text
import Test.Hspec

import OpenCode.App (AppEnv (..), AppError (..))
import OpenCode.Tool.Types

spec :: Spec
spec = do
  describe "inputOptions field stripping" $ do

    it "round-trips a ReadFileInput through JSON with stripped field names" $ do
      let input = ReadFileInput { rfiPath = "/tmp/x", rfiOffset = Just 5, rfiLimit = Just 10 }
          encoded = Aeson.encode input
      -- Should contain "path", "offset", "limit" — NOT "rfiPath" etc.
      encoded `shouldSatisfy` (\b -> "\"path\":"    `Text.isInfixOf` Text.pack (BL.unpack b))
      encoded `shouldSatisfy` (\b -> "\"offset\":"  `Text.isInfixOf` Text.pack (BL.unpack b))
      encoded `shouldNotSatisfy` (\b -> "\"rfiPath\":" `Text.isInfixOf` Text.pack (BL.unpack b))
      -- And the round-trip is total.
      Aeson.eitherDecode encoded `shouldBe` Right input

    it "round-trips a WriteFileInput" $ do
      let input = WriteFileInput { wfiPath = "/tmp/y", wfiContent = "hello\nworld" }
      Aeson.eitherDecode (Aeson.encode input) `shouldBe` Right input

    it "round-trips an EditFileInput" $ do
      let input = EditFileInput "/tmp/z" "old text" "new text"
      Aeson.eitherDecode (Aeson.encode input) `shouldBe` Right input

    it "omits Nothing fields from JSON" $ do
      let input = ReadFileInput { rfiPath = "/tmp/x", rfiOffset = Nothing, rfiLimit = Nothing }
          encoded = Text.pack (BL.unpack (Aeson.encode input))
      encoded `shouldNotSatisfy` ("offset" `Text.isInfixOf`)
      encoded `shouldNotSatisfy` ("limit"  `Text.isInfixOf`)

  describe "executeTool" $ do

    it "raises ToolError on an unknown tool name" $ do
      let reg = emptyRegistry
      result <- runTool reg "no_such_tool" (object [])
      result `shouldBe` Left (ToolError "no_such_tool" "unknown tool")

    it "raises ToolError on malformed JSON arguments" $ do
      let reg = registerTool (echoTool "echo") emptyRegistry
      result <- runTool reg "echo" (Aeson.Number 42)   -- not an object
      case result of
        Left (ToolError "echo" msg) -> Text.unpack msg `shouldContain` "expected Object"
        _ -> expectationFailure ("expected ToolError on malformed args, got " <> show result)

    it "decodes prefix-stripped JSON when dispatching" $ do
      let reg = registerTool (echoTool "echo") emptyRegistry
      result <- runTool reg "echo" (object ["path" .= ("/tmp/x" :: Text), "content" .= ("hello" :: Text)])
      result `shouldBe` Right "hello"

-- ---------------------------------------------------------------------------
-- Test helpers
-- ---------------------------------------------------------------------------

-- | Run an 'executeTool' invocation against a stub AppEnv. envConfig and
-- envDb are undefined because the executeTool path here doesn't touch them.
runTool :: ToolRegistry -> Text -> Value -> IO (Either AppError Text)
runTool reg name args = do
  let env = AppEnv { envConfig = undefined, envDb = undefined, envRegistry = undefined }
  runExceptT (runReaderT (executeTool reg name args) env)

-- | A WriteFileInput-shaped echo tool that returns wfiContent verbatim,
-- with toolRender = id. Used for testing executeTool dispatch.
echoTool :: Text -> SomeTool
echoTool name = SomeTool
  { toolDef     = WriteFileTool
  , toolName    = name
  , toolDesc    = "echo for testing"
  , toolSchema  = object []
  , toolExecute = pure . wfiContent
  , toolRender  = id
  }
