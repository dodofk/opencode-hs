-- | Application error type. Kept in a leaf module to allow Tool/* modules
-- to refer to 'AppError' without inducing an import cycle through 'AppEnv'.
module OpenCode.App.Error
  ( AppError (..)
  ) where

import Data.Text (Text)

data AppError
  = ConfigError Text
  | LLMError Text
  | ToolError Text Text   -- ^ tool name, message
  | DatabaseError Text
  | MCPError Text
  | UnexpectedError Text
  deriving stock (Show, Eq)
