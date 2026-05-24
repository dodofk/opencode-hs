-- | A mock LLM provider for tests. Emits a scripted sequence of 'StreamEvent's.
module OpenCode.LLM.Mock
  ( mockStreamCompletion
  , staticStreamer
  ) where

import Conduit (ConduitT, yieldMany)
import Control.Monad.Trans.Resource (ResourceT)
import OpenCode.LLM.Types (Streamer)
import OpenCode.Types (StreamEvent)

-- | A streaming completion that emits a fixed list of events.
mockStreamCompletion
  :: [StreamEvent]
  -> ConduitT () StreamEvent (ResourceT IO) ()
mockStreamCompletion = yieldMany

-- | Adapt 'mockStreamCompletion' to the 'Streamer' type by discarding the
-- 'LLMRequest' and emitting the same scripted events on every call.
staticStreamer :: [StreamEvent] -> Streamer
staticStreamer scripted = const (mockStreamCompletion scripted)
