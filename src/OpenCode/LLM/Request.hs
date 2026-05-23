-- | Shared request-building utilities used by both provider modules.
module OpenCode.LLM.Request
  ( buildSystemPrompt
  , sseDataLine
  , chunkSSELines
  ) where

import Conduit (ConduitT, await, yield)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BSC
import Data.Text (Text)
import OpenCode.LLM.Types (ToolDefinition)

-- | Build a system prompt from a list of available tool descriptions.
-- Expanded in M6 to include agent-specific instructions and per-tool blocks.
buildSystemPrompt :: [ToolDefinition] -> Text
buildSystemPrompt _ = "You are a helpful AI coding assistant."

-- | Extract the payload from an SSE @data:@ line.
--
--   * @data: <payload>@ → @Just payload@ (including @Just "[DONE]"@)
--   * comments (starting with @:@), @event:@ lines, blanks → @Nothing@
--
-- The caller is responsible for recognizing @"[DONE]"@ as the end-of-stream
-- sentinel; this parser only handles the SSE envelope.
sseDataLine :: ByteString -> Maybe ByteString
sseDataLine bs
  | "data: " `BS.isPrefixOf` bs = Just (BS.drop 6 bs)
  | otherwise                   = Nothing

-- | Chunk a raw byte stream into one 'ByteString' per logical line.
-- Splits on the @\\n@ byte and strips a trailing @\\r@ (handling CRLF
-- line endings as delivered by standard HTTP/1.1 SSE responses).
-- Any unterminated final line is yielded at end-of-stream.
chunkSSELines :: Monad m => ConduitT ByteString ByteString m ()
chunkSSELines = loop BS.empty
  where
    loop buf = do
      mchunk <- await
      case mchunk of
        Nothing ->
          if BS.null buf then pure () else yield buf
        Just chunk -> do
          let combined = buf <> chunk
              (complete, rest) = breakLines combined
          mapM_ yield complete
          loop rest

    -- Split a buffer into (complete lines, residual after the last \n).
    breakLines :: ByteString -> ([ByteString], ByteString)
    breakLines b = case BSC.split '\n' b of
      []   -> ([], BS.empty)
      [x]  -> ([], x)
      xs   -> (map stripCR (init xs), last xs)

    stripCR :: ByteString -> ByteString
    stripCR bs
      | not (BS.null bs) && BS.last bs == 13 = BS.init bs
      | otherwise                            = bs
