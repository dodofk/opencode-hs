-- | Slash-command parsing for the TUI input line.
module OpenCode.TUI.Command
  ( Command (..)
  , parseCommand
  ) where

import Data.Text (Text)
import qualified Data.Text as T

-- | A recognized (or explicitly unknown) slash command typed at the input line.
data Command
  = CmdNew            -- ^ @/new@
  | CmdSessions       -- ^ @/sessions@
  | CmdModel          -- ^ @/model@
  | CmdHelp           -- ^ @/help@
  | CmdQuit           -- ^ @/quit@
  | CmdUnknown Text   -- ^ slash-prefixed but unrecognized (carries the word)
  deriving stock (Show, Eq)

-- | Parse an input line into a 'Command'.
--
--   * 'Nothing' — not slash-prefixed (after trimming): the caller treats it as
--     an LLM prompt.
--   * @Just cmd@ — a slash command. Matching is case-insensitive on the first
--     word; trailing arguments are ignored in M13.
parseCommand :: Text -> Maybe Command
parseCommand raw =
  case T.uncons trimmed of
    Just ('/', _) -> Just (classify firstWord)
    _             -> Nothing
  where
    trimmed   = T.strip raw
    firstWord = T.toLower (T.takeWhile (/= ' ') trimmed)
    classify w = case w of
      "/new"      -> CmdNew
      "/sessions" -> CmdSessions
      "/model"    -> CmdModel
      "/help"     -> CmdHelp
      "/quit"     -> CmdQuit
      other       -> CmdUnknown other
