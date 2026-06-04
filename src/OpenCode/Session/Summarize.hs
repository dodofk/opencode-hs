-- | Context-window summarization. Compacts the *in-memory* request history when
-- it nears the model's context limit; the DB is never touched, so export/reload
-- stay lossless. Cutting at whole-message boundaries never orphans a tool call
-- from its result (call+result are bundled in one assistant message).
module OpenCode.Session.Summarize
  ( estimateTokens
  , contextLimit
  , needsSummary
  , summarizePrompt
  , maybeSummarize
  ) where

import Control.Exception (SomeException, try)
import Control.Monad.IO.Class (liftIO)
import qualified Conduit
import Conduit ((.|))
import Data.List.NonEmpty (NonEmpty ((:|)))
import qualified Data.List.NonEmpty as NE
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time (UTCTime (..), fromGregorian)

import OpenCode.App (AppM)
import OpenCode.LLM.Types (LLMRequest (..), Streamer)
import OpenCode.Types
  ( Message (..), MessageId (MessageId), MessagePart (..), ModelId (..)
  , ProviderId (..), Role (..), StreamEvent (TextDelta), ToolArgs (..)
  , ToolCall (..), ToolResult (..) )

-- | Rough token estimate: total text characters / 4.
estimateTokens :: [Message] -> Int
estimateTokens msgs = sum (map msgChars msgs) `div` 4
  where
    msgChars m = sum (map partChars (NE.toList (msgParts m)))
    partChars (TextPart t)       = T.length t
    partChars (ErrorPart t)      = T.length t
    partChars (ToolCallPart tc)  = T.length (toolName tc) + T.length (unToolArgs (arguments tc))
    partChars (ToolResultPart r) = T.length (content r)

-- | Per-provider context window (token budget). Per-model refinement is YAGNI.
contextLimit :: ModelId -> Int
contextLimit m = case provider m of
  OpenAI    -> 128000
  Anthropic -> 200000
  MiniMax   -> 1000000

-- | Does the estimate meet/exceed the caller-supplied threshold?
needsSummary :: Int -> [Message] -> Bool
needsSummary threshold msgs = estimateTokens msgs >= threshold

-- | Instruction wrapping the older messages to be compacted.
summarizePrompt :: [Message] -> Text
summarizePrompt older = T.unlines
  ( "Summarise the following earlier conversation into a compact paragraph that"
  : "preserves key facts, decisions, and open threads. Be concise."
  : ""
  : map renderMsg older )
  where
    renderMsg m = roleTag (msgRole m) <> ": " <> T.intercalate " " (map renderPart (NE.toList (msgParts m)))
    roleTag RoleUser      = "User"
    roleTag RoleAssistant = "Assistant"
    roleTag RoleTool      = "Tool"
    renderPart (TextPart t)       = t
    renderPart (ErrorPart t)      = "[error] " <> t
    renderPart (ToolCallPart tc)  = "[tool " <> toolName tc <> "]"
    renderPart (ToolResultPart r) = "[result] " <> content r

-- | If the history exceeds @threshold@ and has more than @keepRecent@ messages,
-- replace the older prefix with a single one-shot summary message and keep the
-- last @keepRecent@. Best-effort: a failed/empty summary returns @msgs@ as-is.
maybeSummarize :: Streamer -> ModelId -> Int -> Int -> [Message] -> AppM [Message]
maybeSummarize streamer mdl threshold keepRecent msgs
  | needsSummary threshold msgs && length msgs > keepRecent = do
      let (older, recent) = splitAt (length msgs - keepRecent) msgs
      mSummary <- summarize streamer mdl older
      pure $ case mSummary of
        Just s  -> summaryMessage s : recent
        Nothing -> msgs
  | otherwise = pure msgs

summarize :: Streamer -> ModelId -> [Message] -> AppM (Maybe Text)
summarize streamer mdl older = do
  let req = LLMRequest
        { reqModel        = model mdl
        , reqMessages     = [promptMessage (summarizePrompt older)]
        , reqTools        = []
        , reqSystemPrompt = ""
        , reqMaxTokens    = Just 512
        }
  outcome <- liftIO $ try $ Conduit.runResourceT $ Conduit.runConduit $
    streamer req .| Conduit.sinkList
  pure $ case outcome of
    Left (_ :: SomeException) -> Nothing
    Right events ->
      let txt = T.concat [t | TextDelta t <- events]
      in if T.null txt then Nothing else Just txt

summaryMessage :: Text -> Message
summaryMessage s = Message
  { msgId      = MessageId "summary"
  , msgRole    = RoleUser
  , msgParts   = TextPart ("[Summary of earlier conversation]: " <> s) :| []
  , msgCreated = epoch
  }

promptMessage :: Text -> Message
promptMessage t = Message (MessageId "summary-prompt") RoleUser (TextPart t :| []) epoch

epoch :: UTCTime
epoch = UTCTime (fromGregorian 1970 1 1) 0
