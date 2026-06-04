module OpenCode.RunSpec (spec) where

import Control.Concurrent.STM (atomically, newTVarIO, readTVarIO)
import qualified Data.Text as T
import Database.SQLite.Simple (SQLError (..))
import Database.SQLite3 (Error (ErrorBusy))
import Test.Hspec

import OpenCode.App.Types (AppEnv (..))
import OpenCode.Run (armOnce, onSigInt, renderDbError)
import OpenCode.TestEnv (newDummyEnv)

spec :: Spec
spec = do
  describe "armOnce" $
    it "returns True the first time and False thereafter" $ do
      v <- newTVarIO False
      a <- atomically (armOnce v)
      b <- atomically (armOnce v)
      c <- atomically (armOnce v)
      [a, b, c] `shouldBe` [True, False, False]

  describe "onSigInt" $
    it "sets the env abort flag" $ do
      env   <- newDummyEnv
      armed <- newTVarIO False
      onSigInt env armed
      readTVarIO (envAbort env) `shouldReturn` True

  describe "renderDbError" $
    it "produces a clean database-error line" $ do
      let e = SQLError ErrorBusy "database is locked" ""
      renderDbError e `shouldSatisfy` T.isInfixOf "database error"
