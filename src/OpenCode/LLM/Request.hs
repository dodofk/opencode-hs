-- | Shared request-building utilities used by both provider modules.
module OpenCode.LLM.Request
  ( buildSystemPrompt
  , sseDataLine
  ) where

import Data.ByteString (ByteString)
import Data.Text (Text)
import OpenCode.LLM.Types (ToolDefinition)

-- | Build a system prompt from a list of available tool descriptions.
-- Expanded in M3 to include agent-specific instructions.
buildSystemPrompt :: [ToolDefinition] -> Text
buildSystemPrompt _ = "You are a helpful AI coding assistant."

-- | Extract the payload from an SSE @data:@ line.
-- Returns @Nothing@ for lines that are comments, event names, or @[DONE]@.
sseDataLine :: ByteString -> Maybe ByteString
sseDataLine bs
  | "data: [DONE]" == bs = Nothing
  | "data: " `isPrefixOf` bs = Just (drop 6 bs)
  | otherwise = Nothing
  where
    isPrefixOf prefix str = take (length prefix) str == prefix
    drop = Data.ByteString.drop
