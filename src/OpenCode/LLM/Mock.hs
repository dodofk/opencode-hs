-- | A mock LLM provider for tests. Emits a scripted sequence of 'StreamEvent's.
module OpenCode.LLM.Mock
  ( mockStreamCompletion
  ) where

import Conduit (ConduitT, yieldMany)
import Control.Monad.Trans.Resource (ResourceT)
import OpenCode.Types (StreamEvent)

-- | A streaming completion that emits a fixed list of events.
mockStreamCompletion
  :: [StreamEvent]
  -> ConduitT () StreamEvent (ResourceT IO) ()
mockStreamCompletion = yieldMany
