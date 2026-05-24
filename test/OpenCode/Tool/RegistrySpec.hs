module OpenCode.Tool.RegistrySpec (spec) where

import Control.Monad.Except (runExceptT)
import Control.Monad.Reader (runReaderT)
import qualified Data.Aeson as Aeson
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as Text
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

import OpenCode.App (AppEnv (..))
import OpenCode.Tool.Registry (defaultBuiltinRegistry)
import OpenCode.Tool.Types

spec :: Spec
spec = describe "defaultBuiltinRegistry" $ do

  it "registers exactly the three M5 file tools by name" $
    Map.keys (unRegistry defaultBuiltinRegistry)
      `shouldMatchList` ["read_file", "write_file", "edit_file"]

  it "is accessible from AppEnv via envRegistry" $
    let env = AppEnv { envConfig = undefined, envDb = undefined, envRegistry = defaultBuiltinRegistry }
    in Map.size (unRegistry (envRegistry env)) `shouldBe` 3

  it "round-trips write_file then read_file through executeTool" $
    withSystemTempDirectory "reg" $ \dir -> do
      let path = dir </> "rt.txt"
          env  = AppEnv { envConfig = undefined, envDb = undefined, envRegistry = defaultBuiltinRegistry }
      written <- runExceptT $ runReaderT
        (executeTool defaultBuiltinRegistry "write_file"
          (Aeson.object ["path" Aeson..= path, "content" Aeson..= ("hi" :: Text)]))
        env
      written `shouldBe` Right ("wrote 2 bytes to " <> Text.pack path)

      readBack <- runExceptT $ runReaderT
        (executeTool defaultBuiltinRegistry "read_file"
          (Aeson.object ["path" Aeson..= path]))
        env
      readBack `shouldBe` Right "hi\n"
