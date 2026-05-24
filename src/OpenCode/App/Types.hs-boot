module OpenCode.App.Types
  ( AppM
  , AppEnv
  ) where

import Control.Monad.Except (ExceptT)
import Control.Monad.Reader (ReaderT)

import OpenCode.App.Error (AppError)

data AppEnv

type AppM = ReaderT AppEnv (ExceptT AppError IO)
