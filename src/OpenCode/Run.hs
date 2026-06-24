{-# LANGUAGE ScopedTypeVariables #-}

-- | Top-level application wiring: CLI dispatch + environment construction.
-- Sits above 'OpenCode.App', 'OpenCode.Session', 'OpenCode.CLI', and the TUI so
-- it can build the environment and launch any subcommand without inducing an
-- import cycle.
module OpenCode.Run
  ( runApp
  , armOnce
  , onSigInt
  , renderDbError
  ) where

import qualified Brick.BChan as BChan
import Conduit ((.|))
import qualified Conduit
import Control.Concurrent (forkIO, threadDelay)
import Control.Concurrent.Async (async, poll, waitCatch)
import qualified Control.Concurrent.STM as STM
import Control.Exception (Handler (Handler), SomeException, bracket, catches, try)
import Database.SQLite.Simple (SQLError (..))
import Control.Monad (void, when)
import Data.List.NonEmpty (NonEmpty ((:|)))
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import Data.Time (UTCTime (..), fromGregorian)
import Data.Version (showVersion)
import Options.Applicative (defaultPrefs, execParserPure, handleParseResult)
import Paths_opencode_hs (version)
import System.Environment (getArgs)
import System.Exit (ExitCode (ExitFailure), exitFailure)
import System.IO (hFlush, hPutStrLn, stderr, stdout)
import System.Posix.Process (exitImmediately)
import System.Posix.Signals (Handler (Catch), installHandler, sigINT)
import System.Timeout (timeout)

import OpenCode.App (AppEnv (..), runAppM)
import OpenCode.App.Error (displayAppError)
import OpenCode.CLI
  ( Command (..)
  , RunOpts (..)
  , commandParserInfo
  , defaultRunOpts
  , providerLabel
  , renderExportMarkdown
  , renderSessionList
  )
import OpenCode.Config
  ( Config (..), ProviderConfig (..), defaultAnthropicModel, defaultMiniMaxModel, loadConfig )
import OpenCode.Net.Http (runHttp)
import qualified OpenCode.DB as DB
import OpenCode.LLM.Types (LLMRequest (..), Streamer)
import OpenCode.MCP.Adapters (PromptEntry (..), promptEntries)
import OpenCode.MCP.Client (shutdown)
import OpenCode.MCP.Startup
  ( McpDiagnostic (..), mcpRegistryAdditions, startMcp )
import OpenCode.Skill.Discovery (SkillDiagnostic (..), discoverSkills)
import OpenCode.Skill.Registry (buildSkillRegistry)
import OpenCode.Skill.Types (Skill (..), SkillSource (McpPromptSkill))
import OpenCode.SkillTool (skillTool, skillToolName)
import OpenCode.TUI.Command (commandCatalog)
import OpenCode.Session
  ( createSession, loadSession, processUserMessage, streamerForProvider )
import OpenCode.Session.Events (SessionEvent (..))
import qualified OpenCode.Tool.Types as Tool
import OpenCode.TUI.App (startTUI)
import OpenCode.Types
  ( Message (..)
  , MessageId (MessageId)
  , MessagePart (TextPart)
  , ModelId (..)
  , ProviderId (..)
  , Role (RoleUser)
  , Session (..)
  , SessionId (..)
  , StreamEvent (StreamError)
  )

-- | Entry point. No arguments -> interactive TUI on a fresh session; otherwise
-- parse the subcommand. Every command runs inside 'withAppEnv'.
runApp :: Tool.ToolRegistry -> IO ()
runApp registry = do
  args <- getArgs
  cmd  <- case args of
    [] -> pure (Run defaultRunOpts)
    _  -> handleParseResult (execParserPure defaultPrefs commandParserInfo args)
  withAppEnv registry (needsMcp cmd) $ \cfg env ->
    dispatch cfg env cmd `catches`
      [ Handler (\(e :: SQLError) -> dieT (renderDbError e))
      , Handler (\(DB.DBCorruption m) -> dieT ("database error: " <> m))
      ]

-- | Only agent-running commands spawn MCP servers; pure admin commands
-- ('list'\/'export'\/'config check'\/'version') start nothing. A bare
-- invocation defaults to @Run defaultRunOpts@ in 'runApp', so the no-args
-- TUI path is covered by the 'Run' case here.
needsMcp :: Command -> Bool
needsMcp (Run _) = True
needsMcp _       = False

dispatch :: Config -> AppEnv -> Command -> IO ()
dispatch cfg env = \case
  Run ro      -> runRun cfg env ro
  List        -> runList env
  Export sid  -> runExport env sid
  ConfigCheck -> runConfigCheck cfg env
  Version     -> putStrLn (showVersion version)

-- | Load config, open the DB, and build an 'AppEnv'; run the continuation.
-- A config error is reported to stderr and the process exits non-zero. When
-- @spawnMcp@ is set, every enabled MCP server is connected, its tools merged
-- into the registry, and all clients shut down (via 'bracket') when the
-- continuation returns — normally or via exception. Under the same gate, local
-- skills are discovered and merged with MCP prompts into 'envSkills', and the
-- umbrella @skill@ tool (when any skills exist) is merged into the registry so
-- the model can invoke skills autonomously.
withAppEnv :: Tool.ToolRegistry -> Bool -> (Config -> AppEnv -> IO a) -> IO a
withAppEnv registry spawnMcp k = do
  cfgResult <- loadConfig
  case cfgResult of
    Left err  -> do
      hPutStrLn stderr ("opencode-hs: config error: " <> show err)
      exitFailure
    Right cfg -> do
      dbPath   <- DB.defaultDbPath
      conn     <- DB.openDb dbPath
      chan     <- BChan.newBChan 100
      abortVar <- STM.newTVarIO False
      -- Acquire MCP clients and release them in the same 'bracket', so the
      -- spawned server processes are covered for shutdown the instant they exist.
      let acquireMcp = if spawnMcp then startMcp cfg else pure ([], [])
      bracket acquireMcp (mapM_ shutdown . fst) $ \(clients, diags) -> do
        reportMcpDiagnostics diags
        (localSkills, skillDiags) <- if spawnMcp then discoverSkills else pure ([], [])
        reportSkillDiagnostics skillDiags
        let reserved  = skillToolName : [ T.drop 1 name | (_, name, _) <- commandCatalog ]
            mcpSkills =
              [ Skill { skName         = peFullName e
                      , skDescription  = peDescription e
                      , skRequiredArgs = peRequiredArgs e
                      , skSource       = McpPromptSkill (peServer e) (peName e)
                      }
              | c <- clients, e <- promptEntries c ]
            skills = buildSkillRegistry reserved (localSkills ++ mcpSkills)
        let env = AppEnv
              { envConfig      = cfg
              , envDb          = conn
              , envRegistry    = maybe id Tool.registerTool (skillTool clients skills)
                                   (mcpRegistryAdditions clients registry)
              , envEventChan   = chan
              , envAbort       = abortVar
              , envMcp         = clients
              , envSkills      = skills
              , envHttpBackend = runHttp
              , envTools       = tools cfg
              }
        armed <- STM.newTVarIO False
        -- NOTE: the SIGINT hard-exit timer (see 'onSigInt') calls
        -- 'exitImmediately', which bypasses this 'bracket'; on that path MCP
        -- child processes are orphaned and reaped by the OS rather than via
        -- 'shutdown'. The normal-return and exception paths shut down cleanly.
        _ <- installHandler sigINT (Catch (onSigInt env armed)) Nothing
        k cfg env

-- | MCP startup diagnostics go to stderr (visible in headless mode; harmless
-- before the TUI takes the screen).
reportMcpDiagnostics :: [McpDiagnostic] -> IO ()
reportMcpDiagnostics =
  mapM_ (\d -> TIO.hPutStrLn stderr
    ("opencode-hs: MCP server '" <> mdServer d <> "' unavailable: " <> mdReason d))

-- | Skill-discovery diagnostics go to stderr, like the MCP ones.
reportSkillDiagnostics :: [SkillDiagnostic] -> IO ()
reportSkillDiagnostics =
  mapM_ (\d -> TIO.hPutStrLn stderr
    ("opencode-hs: skill '" <> sdSkill d <> "' skipped: " <> sdReason d))

-- ---------------------------------------------------------------------------
-- run
-- ---------------------------------------------------------------------------

runRun :: Config -> AppEnv -> RunOpts -> IO ()
runRun cfg env ro = do
  session <- resolveSession cfg env ro
  if roNoTui ro
    then case roPrompt ro of
      Nothing     -> dieT "--no-tui requires --prompt"
      Just prompt -> runHeadless env (sessionId session) prompt
    else startTUI env session

resolveSession :: Config -> AppEnv -> RunOpts -> IO Session
resolveSession cfg env ro = case roSession ro of
  Just sid -> do
    result <- runAppM env (loadSession sid)
    case result of
      Right (Just s) -> pure s
      Right Nothing  -> dieT ("no such session: " <> unSessionId sid)
      Left err       -> dieT (displayAppError err)
  Nothing -> do
    let mdl = fromMaybe (defaultModel cfg) (roModel ro)
    result <- runAppM env (createSession mdl)
    either (dieT . displayAppError) pure result

-- | Headless run: stream the assistant reply to stdout as it arrives. Reads
-- 'envEventChan' until the worker finishes, then flushes any buffered tail.
-- Termination keys off the worker completing (via 'poll'), not off
-- @RunStateChanged Idle@ — the agentic loop emits 'Idle' after every tool
-- round, so keying on it would truncate a multi-round run (and could deadlock
-- once the bounded channel fills). Draining continuously also keeps the channel
-- from backing up the producer.
runHeadless :: AppEnv -> SessionId -> Text -> IO ()
runHeadless env sid prompt = do
  worker <- async (runAppM env (processUserMessage sid prompt))
  drain worker
  result <- waitCatch worker
  putStrLn ""
  case result of
    Left ex          -> TIO.hPutStrLn stderr (T.pack (show ex)) >> exitFailure
    Right (Left err) -> TIO.hPutStrLn stderr (displayAppError err) >> exitFailure
    Right (Right ()) -> pure ()
  where
    drain worker = do
      mev <- timeout 50000 (BChan.readBChan (envEventChan env))
      case mev of
        Just ev -> handleEv ev >> drain worker
        Nothing -> do
          done <- poll worker
          case done of
            Nothing -> drain worker   -- still running; keep draining
            Just _  -> flush          -- worker done; emit any buffered tail
    -- Drain whatever is still buffered after the worker exits, without blocking.
    flush = do
      mev <- timeout 1000 (BChan.readBChan (envEventChan env))
      case mev of
        Just ev -> handleEv ev >> flush
        Nothing -> pure ()
    handleEv ev = case ev of
      PartialText t      -> TIO.hPutStr stdout t >> hFlush stdout
      PartialReasoning r -> TIO.hPutStr stderr r >> hFlush stderr
      ToolStarted n      -> TIO.hPutStrLn stderr ("\x2699 " <> n)
      ErrorOccurred e    -> TIO.hPutStrLn stderr e
      _                  -> pure ()

-- ---------------------------------------------------------------------------
-- list / export
-- ---------------------------------------------------------------------------

runList :: AppEnv -> IO ()
runList env = do
  sessions <- DB.listSessions (envDb env)
  TIO.putStr (renderSessionList sessions)

runExport :: AppEnv -> SessionId -> IO ()
runExport env sid = do
  mSession <- DB.getSession (envDb env) sid
  case mSession of
    Nothing      -> dieT ("no such session: " <> unSessionId sid)
    Just session -> do
      msgs <- DB.getMessages (envDb env) sid
      TIO.putStr (renderExportMarkdown session msgs)

-- ---------------------------------------------------------------------------
-- config check
-- ---------------------------------------------------------------------------

runConfigCheck :: Config -> AppEnv -> IO ()
runConfigCheck cfg _env = mapM_ (checkProvider cfg) [OpenAI, MiniMax, Anthropic]

checkProvider :: Config -> ProviderId -> IO ()
checkProvider cfg pid = do
  let pc   = providers cfg
      mKey = case pid of
        OpenAI    -> openaiKey pc
        MiniMax   -> minimaxKey pc
        Anthropic -> anthropicKey pc
  status <- case mKey of
    Nothing -> pure "not configured"
    Just _  -> case streamerForProvider cfg pid of
      Left err       -> pure ("FAIL (" <> displayAppError err <> ")")
      Right streamer -> probeProvider streamer (probeModel cfg pid)
  TIO.putStrLn (providerLabel pid <> ": " <> status)

-- | Model to probe with: the configured default model when its provider
-- matches, else a per-provider default (so a key-only config still probes).
probeModel :: Config -> ProviderId -> Text
probeModel cfg pid
  | provider (defaultModel cfg) == pid = model (defaultModel cfg)
  | otherwise = case pid of
      OpenAI    -> "gpt-4o"
      MiniMax   -> defaultMiniMaxModel
      Anthropic -> defaultAnthropicModel

-- | Issue a minimal one-token request and inspect the first stream event.
probeProvider :: Streamer -> Text -> IO Text
probeProvider streamer mdl = do
  let req = LLMRequest
        { reqModel        = mdl
        , reqMessages     = [pingMessage]
        , reqTools        = []
        , reqSystemPrompt = ""
        , reqMaxTokens    = Just 1
        }
  outcome <- try (Conduit.runResourceT
                    (Conduit.runConduit (streamer req .| Conduit.await)))
  pure $ case outcome of
    Left (e :: SomeException)    -> "FAIL (" <> T.pack (show e) <> ")"
    Right (Just (StreamError e)) -> "FAIL (" <> T.take 120 e <> ")"
    Right _                      -> "OK"

pingMessage :: Message
pingMessage = Message
  { msgId      = MessageId "probe"
  , msgRole    = RoleUser
  , msgParts   = TextPart "ping" :| []
  , msgCreated = UTCTime (fromGregorian 1970 1 1) 0
  }

-- ---------------------------------------------------------------------------
-- SIGINT handling
-- ---------------------------------------------------------------------------

-- | Atomically claim the one-shot arm. Returns 'True' exactly once (the first
-- caller), 'False' on every later call. Pure STM so it is unit-testable.
armOnce :: STM.TVar Bool -> STM.STM Bool
armOnce armed = do
  already <- STM.readTVar armed
  if already
    then pure False
    else STM.writeTVar armed True >> pure True

-- | SIGINT handler: request a cooperative abort (same flag as Esc/headless),
-- and — on the first signal only — fork a 5-second hard-exit timer so a wedged
-- run can't trap the user. A second SIGINT just re-sets abort.
onSigInt :: AppEnv -> STM.TVar Bool -> IO ()
onSigInt env armed = do
  firstTime <- STM.atomically $ do
    STM.writeTVar (envAbort env) True
    armOnce armed
  when firstTime $
    void $ forkIO (threadDelay 5000000 >> exitImmediately (ExitFailure 130))

-- ---------------------------------------------------------------------------
-- helpers
-- ---------------------------------------------------------------------------

-- | A clean, user-facing one-liner for a SQLite failure — no backtrace.
renderDbError :: SQLError -> Text
renderDbError e = "database error: " <> sqlErrorDetails e

dieT :: Text -> IO a
dieT msg = do
  TIO.hPutStrLn stderr ("opencode-hs: " <> msg)
  exitFailure
