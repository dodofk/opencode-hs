{-# LANGUAGE OverloadedStrings #-}

-- | Convert discovered MCP capabilities into the app's own abstractions:
-- tools and resources become 'SomeTool's on the dynamic-tool path; prompts
-- become 'PromptEntry' descriptors for the TUI. Also the pure parser for a
-- @\/name k=v@ prompt-invocation line.
module OpenCode.MCP.Adapters
  ( PromptEntry (..)
  , mcpToolName
  , toolToSomeTool
  , resourceTools
  , clientSomeTools
  , promptEntryOf
  , promptEntries
  , promptSuggestEntries
  , parsePromptInvocation
  , missingArgs
  , resourceReadSchema
  ) where

import Control.Monad.Except (MonadError, throwError)
import Control.Monad.IO.Class (liftIO)
import Data.Aeson (Value (..), object, (.=))
import qualified Data.Aeson.KeyMap as KM
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T

import OpenCode.App.Error (AppError (ToolError))
import OpenCode.MCP.Client
  ( McpClient (..), McpError, callTool, readResource, renderMcpError )
import OpenCode.MCP.Protocol
import OpenCode.Tool.Types (SomeTool (..), ToolDef (DynamicTool))

-- | A prompt the user can invoke from the TUI.
data PromptEntry = PromptEntry
  { peFullName     :: Text     -- ^ @<server>_<prompt>@ (no leading slash)
  , peServer       :: Text     -- ^ owning server name (matches 'mcName')
  , peName         :: Text     -- ^ raw prompt name on the server
  , peDescription  :: Text
  , peRequiredArgs :: [Text]
  }
  deriving stock (Show, Eq)

-- ---------------------------------------------------------------------------
-- Naming
-- ---------------------------------------------------------------------------

mcpToolName :: Text -> Text -> Text
mcpToolName server tool = server <> "_" <> tool

-- ---------------------------------------------------------------------------
-- Tools
-- ---------------------------------------------------------------------------

toolToSomeTool :: McpClient -> McpToolDef -> SomeTool
toolToSomeTool c t = SomeTool
  { toolDef     = DynamicTool
  , toolName    = fullName
  , toolDesc    = mtDescription t
  , toolSchema  = mtInputSchema t
  , toolExecute = \args -> do
      r <- liftIO (callTool c (mtName t) args)
      either (failWith fullName) (pure . renderContent . ctrContent) r
  , toolRender  = id
  }
  where fullName = mcpToolName (mcName c) (mtName t)

-- | When a server advertises resources, expose two tools so the LLM can list
-- and read them through the normal tool path.
resourceTools :: McpClient -> [SomeTool]
resourceTools c
  | not (capResources (mcCaps c)) = []
  | otherwise = [listTool, readTool]
  where
    server   = mcName c
    listName = mcpToolName server "list_resources"
    readName = mcpToolName server "read_resource"

    listTool = SomeTool
      { toolDef     = DynamicTool
      , toolName    = listName
      , toolDesc    = "list resources from the " <> server <> " MCP server"
      , toolSchema  = object ["type" .= ("object" :: Text), "properties" .= object []]
      , toolExecute = \_ -> pure (renderResourceList (mcResources c))
      , toolRender  = id
      }

    readTool = SomeTool
      { toolDef     = DynamicTool
      , toolName    = readName
      , toolDesc    = "read a resource by uri from the " <> server <> " MCP server"
      , toolSchema  = resourceReadSchema
      , toolExecute = \args -> case extractUri args of
          Nothing  -> throwError (ToolError readName "missing 'uri' argument")
          Just uri -> do
            r <- liftIO (readResource c uri)
            either (failWith readName) (pure . renderContent . rrContents) r
      , toolRender  = id
      }

-- | All tools (real + synthesized resource tools) a client contributes.
clientSomeTools :: McpClient -> [SomeTool]
clientSomeTools c = map (toolToSomeTool c) (mcTools c) ++ resourceTools c

resourceReadSchema :: Value
resourceReadSchema = object
  [ "type" .= ("object" :: Text)
  , "properties" .= object ["uri" .= object ["type" .= ("string" :: Text)]]
  , "required" .= (["uri"] :: [Text])
  ]

-- | Turn an MCP transport error into a tool error. Works in any
-- @MonadError AppError m@ (the tool executors run in 'AppM').
failWith :: MonadError AppError m => Text -> McpError -> m a
failWith name e = throwError (ToolError name (renderMcpError e))

extractUri :: Value -> Maybe Text
extractUri (Object o) = case KM.lookup "uri" o of
  Just (String s) -> Just s
  _               -> Nothing
extractUri _ = Nothing

renderResourceList :: [McpResource] -> Text
renderResourceList [] = "(no resources)"
renderResourceList rs = T.intercalate "\n" (map row rs)
  where
    row r = mrUri r <> "  " <> mrName r <> maybe "" (" — " <>) (mrDescription r)

-- ---------------------------------------------------------------------------
-- Prompts
-- ---------------------------------------------------------------------------

promptEntryOf :: Text -> McpPrompt -> PromptEntry
promptEntryOf server p = PromptEntry
  { peFullName     = mcpToolName server (mpName p)
  , peServer       = server
  , peName         = mpName p
  , peDescription  = fromMaybe "" (mpDescription p)
  , peRequiredArgs = [ mpaName a | a <- mpArguments p, mpaRequired a ]
  }

promptEntries :: McpClient -> [PromptEntry]
promptEntries c = map (promptEntryOf (mcName c)) (mcPrompts c)

-- | Autocomplete entries (slash-prefixed name + description) for every prompt
-- across the given clients.
promptSuggestEntries :: [McpClient] -> [(Text, Text)]
promptSuggestEntries cs =
  [ ("/" <> peFullName e, peDescription e) | c <- cs, e <- promptEntries c ]

-- | Parse a @\/name k=v k2=v2@ prompt-invocation line. The name carries no
-- leading slash in the result. Tokens without an @=@ are ignored. 'Nothing'
-- for input that is not a single @\/word …@.
parsePromptInvocation :: Text -> Maybe (Text, [(Text, Text)])
parsePromptInvocation raw = case T.words (T.strip raw) of
  (w : rest)
    | Just nm <- T.stripPrefix "/" w, not (T.null nm) ->
        Just (nm, [ (k, T.drop 1 vEq)
                  | tok <- rest
                  , let (k, vEq) = T.breakOn "=" tok
                  , not (T.null k), not (T.null vEq) ])
  _ -> Nothing

-- | Required arg names not present in the supplied key=value pairs.
missingArgs :: PromptEntry -> [(Text, Text)] -> [Text]
missingArgs entry args =
  [ a | a <- peRequiredArgs entry, a `notElem` map fst args ]
