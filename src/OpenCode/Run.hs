{-# LANGUAGE ScopedTypeVariables #-}

-- | Top-level application wiring: CLI dispatch + environment construction.
-- Sits above 'OpenCode.App', 'OpenCode.Session', 'OpenCode.CLI', and the TUI so
-- it can build the environment and launch any subcommand without inducing an
-- import cycle.
module OpenCode.Run
  ( runApp
  ) where

import qualified Brick.BChan as BChan
import Conduit ((.|))
import qualified Conduit
import Control.Concurrent.Async (async, poll, waitCatch)
import qualified Control.Concurrent.STM as STM
import Control.Exception (SomeException, try)
import Data.List.NonEmpty (NonEmpty ((:|)))
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import Data.Time (UTCTime (..), fromGregorian)
import Options.Applicative (defaultPrefs, execParserPure, handleParseResult)
import System.Environment (getArgs)
import System.Exit (exitFailure)
import System.IO (hFlush, hPutStrLn, stderr, stdout)
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
  ( Config (..), ProviderConfig (..), defaultMiniMaxModel, loadConfig )
import qualified OpenCode.DB as DB
import OpenCode.LLM.Types (LLMRequest (..), Streamer)
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
  withAppEnv registry (\cfg env -> dispatch cfg env cmd)

dispatch :: Config -> AppEnv -> Command -> IO ()
dispatch cfg env = \case
  Run ro      -> runRun cfg env ro
  List        -> runList env
  Export sid  -> runExport env sid
  ConfigCheck -> runConfigCheck cfg env

-- | Load config, open the DB, and build an 'AppEnv'; run the continuation.
-- A config error is reported to stderr and the process exits non-zero.
withAppEnv :: Tool.ToolRegistry -> (Config -> AppEnv -> IO a) -> IO a
withAppEnv registry k = do
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
      let env = AppEnv
            { envConfig    = cfg
            , envDb        = conn
            , envRegistry  = registry
            , envEventChan = chan
            , envAbort     = abortVar
            }
      k cfg env

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
      PartialText t   -> TIO.hPutStr stdout t >> hFlush stdout
      ToolStarted n   -> TIO.hPutStrLn stderr ("\x2699 " <> n)
      ErrorOccurred e -> TIO.hPutStrLn stderr e
      _               -> pure ()

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
    Just _  -> case pid of
      Anthropic -> pure "FAIL (not implemented until M11)"
      _         -> case streamerForProvider cfg pid of
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
      Anthropic -> ""   -- never probed

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
-- helpers
-- ---------------------------------------------------------------------------

dieT :: Text -> IO a
dieT msg = do
  TIO.hPutStrLn stderr ("opencode-hs: " <> msg)
  exitFailure
