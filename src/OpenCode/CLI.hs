-- | Pure CLI surface: the command grammar plus the pure parsers and renderers
-- the test suite exercises directly. All IO orchestration lives in
-- 'OpenCode.Run'; this module imports no IO and breaks no cycles.
module OpenCode.CLI
  ( Command (..)
  , RunOpts (..)
  , defaultRunOpts
  , parseModelId
  , providerLabel
  , commandParserInfo
  , parseArgs
  , renderSessionList
  , renderExportMarkdown
  ) where

import Control.Applicative ((<|>))
import Data.Bifunctor (first)
import qualified Data.List.NonEmpty as NE
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time (UTCTime)
import Data.Time.Format (defaultTimeLocale, formatTime)
import Options.Applicative
  ( Parser, ParserInfo, ReadM, command, defaultPrefs, eitherReader
  , execParserPure, flag', fullDesc, getParseResult, header, help, helper, info
  , long, metavar, option, optional, progDesc, strArgument, strOption
  , subparser, switch, (<**>)
  )

import OpenCode.Types
  ( Message (..), MessagePart (..), ModelId (..), ProviderId (..), Role (..)
  , Session (..), SessionId (..), ToolArgs (..), ToolCall (..), ToolResult (..)
  )

-- | A parsed top-level command.
data Command
  = Run RunOpts
  | List
  | Export SessionId
  | ConfigCheck
  | Version
  deriving stock (Show, Eq)

-- | Options for the @run@ subcommand (and the bare-invocation default).
data RunOpts = RunOpts
  { roSession :: Maybe SessionId
  , roModel   :: Maybe ModelId
  , roPrompt  :: Maybe Text
  , roNoTui   :: Bool
  }
  deriving stock (Show, Eq)

defaultRunOpts :: RunOpts
defaultRunOpts = RunOpts Nothing Nothing Nothing False

-- | Render a provider id as its lowercase wire label.
providerLabel :: ProviderId -> Text
providerLabel = \case
  OpenAI    -> "openai"
  Anthropic -> "anthropic"
  MiniMax   -> "minimax"

-- | Parse a @provider:model@ string into a 'ModelId'. The provider must be one
-- of @openai@/@anthropic@/@minimax@ and the model part must be non-empty.
parseModelId :: Text -> Either Text ModelId
parseModelId raw =
  case T.breakOn ":" raw of
    (_, "")          -> Left ("expected provider:model, got: " <> raw)
    (provText, rest) ->
      let mdl = T.drop 1 rest
      in if T.null mdl
           then Left ("missing model in: " <> raw)
           else case providerFromText provText of
             Just p  -> Right (ModelId { provider = p, model = mdl })
             Nothing -> Left ("unknown provider: " <> provText)

providerFromText :: Text -> Maybe ProviderId
providerFromText = \case
  "openai"    -> Just OpenAI
  "anthropic" -> Just Anthropic
  "minimax"   -> Just MiniMax
  _           -> Nothing

-- | Top-level parser info (program description + @--help@).
commandParserInfo :: ParserInfo Command
commandParserInfo = info (topLevelParser <**> helper)
  (fullDesc <> progDesc "A terminal AI coding agent" <> header "opencode-hs")

topLevelParser :: Parser Command
topLevelParser = versionFlag <|> commandParser

versionFlag :: Parser Command
versionFlag = flag' Version (long "version" <> help "Print version and exit")

commandParser :: Parser Command
commandParser = subparser
  ( command "run"
      (info (Run <$> runOptsParser <**> helper)
            (progDesc "Start the TUI, or run a single prompt headless"))
 <> command "list"
      (info (pure List <**> helper) (progDesc "List stored sessions"))
 <> command "export"
      (info (Export <$> sessionIdArg <**> helper)
            (progDesc "Export a session as Markdown to stdout"))
 <> command "config"
      (info (configParser <**> helper) (progDesc "Configuration commands"))
  )

configParser :: Parser Command
configParser = subparser
  ( command "check"
      (info (pure ConfigCheck <**> helper) (progDesc "Probe each configured provider")) )

runOptsParser :: Parser RunOpts
runOptsParser = RunOpts
  <$> optional (SessionId <$> strOption
        (long "session" <> metavar "ID" <> help "Resume an existing session"))
  <*> optional (option modelReader
        (long "model" <> metavar "PROVIDER:MODEL" <> help "Model, e.g. openai:gpt-4o"))
  <*> optional (strOption
        (long "prompt" <> metavar "TEXT" <> help "Prompt to send (requires --no-tui)"))
  <*> switch (long "no-tui" <> help "Run headless: stream the reply to stdout")

modelReader :: ReadM ModelId
modelReader = eitherReader (first T.unpack . parseModelId . T.pack)

sessionIdArg :: Parser SessionId
sessionIdArg = SessionId <$> strArgument
  (metavar "SESSION_ID" <> help "Session id to export")

-- | Pure parse used by tests and by 'OpenCode.Run.runApp'. Empty args map to
-- the default Run (bare invocation -> TUI); otherwise run the optparse grammar.
parseArgs :: [String] -> Maybe Command
parseArgs [] = Just (Run defaultRunOpts)
parseArgs as = getParseResult (execParserPure defaultPrefs commandParserInfo as)

-- | A fixed-width table of sessions: @ID  TITLE  MODEL  CREATED@.
renderSessionList :: [Session] -> Text
renderSessionList [] = "(no sessions)\n"
renderSessionList sessions = T.unlines (headerRow : map row sessions)
  where
    idW    = colWidth "ID"    (unSessionId . sessionId)
    titleW = colWidth "TITLE" sessionTitle
    modelW = colWidth "MODEL" (modelText . sessionModel)
    colWidth h f = maximum (T.length h : map (T.length . f) sessions)
    headerRow = rowCells "ID" "TITLE" "MODEL" "CREATED"
    row s = rowCells (unSessionId (sessionId s)) (sessionTitle s)
                     (modelText (sessionModel s)) (createdText (sessionCreated s))
    rowCells a b c d =
      pad idW a <> "  " <> pad titleW b <> "  " <> pad modelW c <> "  " <> d
    pad w t = t <> T.replicate (max 0 (w - T.length t)) " "

modelText :: ModelId -> Text
modelText m = providerLabel (provider m) <> ":" <> model m

createdText :: UTCTime -> Text
createdText = T.pack . formatTime defaultTimeLocale "%Y-%m-%d %H:%M"

-- | Render a session and its messages as Markdown: a title + metadata block,
-- then one @##@ section per message with text, fenced tool calls/results, and
-- blockquoted errors.
renderExportMarkdown :: Session -> [Message] -> Text
renderExportMarkdown s msgs = T.unlines $
  [ "# " <> sessionTitle s
  , ""
  , "- **ID:** " <> unSessionId (sessionId s)
  , "- **Model:** " <> modelText (sessionModel s)
  , "- **Created:** " <> createdText (sessionCreated s)
  , ""
  ] <> concatMap renderMessageMd msgs

renderMessageMd :: Message -> [Text]
renderMessageMd m =
  ("## " <> roleHeading (msgRole m))
  : ""
  : (concatMap renderPartMd (NE.toList (msgParts m)) <> [""])

roleHeading :: Role -> Text
roleHeading = \case
  RoleUser      -> "User"
  RoleAssistant -> "Assistant"
  RoleTool      -> "Tool"

renderPartMd :: MessagePart -> [Text]
renderPartMd = \case
  TextPart t        -> [t, ""]
  ToolCallPart tc   -> ["```" <> toolName tc, unToolArgs (arguments tc), "```", ""]
  ToolResultPart tr -> ["```result", content tr, "```", ""]
  ErrorPart e       -> ["> ⚠ " <> e, ""]
