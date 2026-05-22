-- | Shared request-building utilities used by both provider modules.
module OpenCode.LLM.Request
  ( buildSystemPrompt
  , sseDataLine
  ) where

import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Text (Text)
import OpenCode.LLM.Types (ToolDefinition)

-- | Build a system prompt from a list of available tool descriptions.
-- Expanded in M3 to include agent-specific instructions.
buildSystemPrompt :: [ToolDefinition] -> Text
buildSystemPrompt _ = "You are a helpful AI coding assistant."

-- | Extract the payload from an SSE @data:@ line.
-- Returns @Nothing@ for comment lines, event-name lines, and @[DONE]@.
sseDataLine :: ByteString -> Maybe ByteString
sseDataLine bs
  | bs == "data: [DONE]"     = Nothing
  | "data: " `BS.isPrefixOf` bs = Just (BS.drop 6 bs)
  | otherwise                = Nothing
