-- | A mock LLM provider for tests. Emits a scripted sequence of 'StreamEvent's.
module OpenCode.LLM.Mock
  ( mockStreamCompletion
  , staticStreamer
  , scriptedStreamer
  , newScriptedStreamer
  , delayedStreamer
  ) where

import Conduit (ConduitT, yield, yieldMany)
import Control.Concurrent (threadDelay)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Trans.Resource (ResourceT)
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
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

-- | A multi-round 'Streamer' driven by an 'IORef' of scripted event lists.
-- The first call returns the first list, the second call returns the second,
-- and so on. Used to test the agentic loop's multi-round behavior.
--
-- Construct with 'newScriptedStreamer'; the 'IORef' lives inside the closure
-- so each test gets its own independent state.
scriptedStreamer :: IORef [[StreamEvent]] -> Streamer
scriptedStreamer ref _req = do
  rounds <- liftIO $ readIORef ref
  case rounds of
    []          -> pure ()   -- exhausted: emit no events
    (this:rest) -> do
      liftIO $ writeIORef ref rest
      yieldMany this

-- | Construct a 'scriptedStreamer' with its IORef pre-initialized.
newScriptedStreamer :: [[StreamEvent]] -> IO Streamer
newScriptedStreamer rounds = do
  ref <- newIORef rounds
  pure (scriptedStreamer ref)

-- | A 'Streamer' that yields each scripted event with @delayUs@ microseconds
-- between emissions. Used for manual TUI testing without API keys: the delay
-- makes streaming visible to a human. Tests pass @0@.
delayedStreamer :: Int -> [StreamEvent] -> Streamer
delayedStreamer delayUs evts _req = go evts
  where
    go []       = pure ()
    go [e]      = yield e                       -- last event: no trailing delay
    go (e:rest) = do
      yield e
      liftIO (threadDelay delayUs)
      go rest
