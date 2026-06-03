-- | Application error type. Kept in a leaf module to allow Tool/* modules
-- to refer to 'AppError' without inducing an import cycle through 'AppEnv'.
module OpenCode.App.Error
  ( AppError (..)
  , displayAppError
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

-- | Render an 'AppError' as a concise, user-facing message — no Haskell
-- constructor syntax — suitable for display in the TUI.
displayAppError :: AppError -> Text
displayAppError = \case
  ConfigError m     -> "config error: " <> m
  LLMError m        -> "LLM error: " <> m
  ToolError n m     -> "tool error (" <> n <> "): " <> m
  DatabaseError m   -> "database error: " <> m
  MCPError m        -> "MCP error: " <> m
  UnexpectedError m -> "unexpected error: " <> m
