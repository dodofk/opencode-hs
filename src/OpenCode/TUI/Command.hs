-- | Slash-command parsing for the TUI input line.
module OpenCode.TUI.Command
  ( Command (..)
  , parseCommand
  , commandCatalog
  , commandSuggestions
  , clampSel
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
    firstWord = T.toLower (case T.words trimmed of
                             (w:_) -> w
                             []    -> "")
    classify w = case w of
      "/new"      -> CmdNew
      "/sessions" -> CmdSessions
      "/model"    -> CmdModel
      "/help"     -> CmdHelp
      "/quit"     -> CmdQuit
      other       -> CmdUnknown other

-- | Every slash command with its @\/name@ and a one-line description, in the
-- order they appear in the autocomplete panel and the help overlay. This is the
-- single source of truth for command names + descriptions.
commandCatalog :: [(Command, Text, Text)]
commandCatalog =
  [ (CmdNew,      "/new",      "start a new session")
  , (CmdSessions, "/sessions", "switch session")
  , (CmdModel,    "/model",    "change model (this session)")
  , (CmdHelp,     "/help",     "show help")
  , (CmdQuit,     "/quit",     "exit")
  ]

-- | Autocomplete matches for the current input line. Empty unless the trimmed
-- input begins with @\/@; otherwise the catalog rows whose @\/name@ has the typed
-- first token as a case-insensitive prefix.
--
-- @\/@ alone matches every command; @\/se@ matches @\/sessions@; @\/foo@ matches
-- nothing. Returns @(name, description)@ pairs in catalog order.
commandSuggestions :: Text -> [(Text, Text)]
commandSuggestions raw =
  case T.uncons trimmed of
    Just ('/', _) ->
      [ (name, desc)
      | (_, name, desc) <- commandCatalog
      , token `T.isPrefixOf` T.toLower name
      ]
    _ -> []
  where
    trimmed = T.strip raw
    token   = T.toLower firstWord
    firstWord = case T.words trimmed of
      (w:_) -> w
      []    -> ""

-- | Clamp a selection index into @[0, n-1]@ (0 when the list is empty).
clampSel :: Int -> Int -> Int
clampSel n i
  | n <= 0    = 0
  | i < 0     = 0
  | i >= n    = n - 1
  | otherwise = i
