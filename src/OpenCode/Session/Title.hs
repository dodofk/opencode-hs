-- | One-shot session-title generation. Best-effort and non-fatal: a failed or
-- empty generation yields 'Nothing' and leaves the title untouched.
module OpenCode.Session.Title
  ( titlePrompt
  , sanitizeTitle
  , generateTitle
  ) where

import Control.Exception (SomeException, try)
import Control.Monad.IO.Class (liftIO)
import qualified Conduit
import Conduit ((.|))
import Data.List.NonEmpty (NonEmpty ((:|)))
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time (UTCTime (..), fromGregorian)

import OpenCode.App (AppM)
import OpenCode.LLM.Types (LLMRequest (..), Streamer)
import OpenCode.Types
  ( Message (..), MessageId (MessageId), MessagePart (TextPart), ModelId (..)
  , Role (RoleUser), StreamEvent (TextDelta) )

-- | Wrap the first user message in a terse title instruction.
titlePrompt :: Text -> Text
titlePrompt userMsg = T.unlines
  [ "Give a short title (at most 5 words, no quotes, no punctuation) for a"
  , "conversation that starts with this user message:"
  , ""
  , userMsg
  ]

-- | Normalise a model's title reply: first line, strip surrounding
-- quotes/backticks, collapse whitespace, cap to 6 words / 60 chars; "untitled"
-- when nothing survives.
sanitizeTitle :: Text -> Text
sanitizeTitle raw =
  let firstLine = case T.lines raw of
        (l : _) -> l
        []      -> ""
      stripped  = T.dropAround (`elem` ['"', '\'', '`', ' ']) firstLine
      collapsed = T.unwords (take 6 (T.words stripped))
      capped    = T.take 60 collapsed
  in if T.null capped then "untitled" else capped

-- | Issue a one-shot, tool-free request and return a sanitised title, or
-- 'Nothing' if the stream produced no text or errored.
generateTitle :: Streamer -> ModelId -> Text -> AppM (Maybe Text)
generateTitle streamer mdl userMsg = do
  let req = LLMRequest
        { reqModel        = model mdl
        , reqMessages     = [titleMessage (titlePrompt userMsg)]
        , reqTools        = []
        , reqSystemPrompt = ""
        , reqMaxTokens    = Just 32
        }
  outcome <- liftIO $ try $ Conduit.runResourceT $ Conduit.runConduit $
    streamer req .| Conduit.sinkList
  pure $ case outcome of
    Left (_ :: SomeException) -> Nothing
    Right events ->
      let txt = T.concat [t | TextDelta t <- events]
      in if T.null txt then Nothing else Just (sanitizeTitle txt)

titleMessage :: Text -> Message
titleMessage t = Message
  { msgId      = MessageId "title-gen"
  , msgRole    = RoleUser
  , msgParts   = TextPart t :| []
  , msgCreated = UTCTime (fromGregorian 1970 1 1) 0
  }
