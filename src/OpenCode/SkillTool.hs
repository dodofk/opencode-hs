-- | The umbrella @skill@ tool: exposes every discovered skill (local SKILL.md
-- and MCP prompts) to the model as a single tool whose result is the rendered
-- skill body. Also home to 'renderSkill', the one render path shared with the
-- user-typed @/<name>@ invocation in the TUI. This is the only module allowed
-- to import both @Skill.*@ and @MCP.*@ (the @Skill.*@ namespace stays pure).
module OpenCode.SkillTool
  ( SkillCall (..)
  , skillToolName
  , renderSkill
  , runSkillCall
  , skillTool
  ) where

import Control.Exception (SomeException, displayException, try)
import Control.Monad.IO.Class (liftIO)
import Data.Aeson (FromJSON (..), Value)
import qualified Data.Aeson as Aeson
import Data.List (find)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import GHC.Generics (Generic)

import OpenCode.MCP.Client
  ( McpClient (..), McpError, getPrompt, renderMcpError )
import OpenCode.MCP.Protocol (GetPromptResult (..), PromptMessage (..))
import OpenCode.Skill.Parse (missingArgs, parseArgs, substituteArgs)
import OpenCode.Skill.Registry
  ( lookupSkill, skillToolDescription, skillToolSchema )
import OpenCode.Skill.Types (Skill (..), SkillSource (..))
import OpenCode.Tool.Types
  ( SomeTool (..), ToolDef (DynamicTool), inputOptions )

-- | The reserved tool/command name. A local skill with this name is dropped by
-- the registry ('OpenCode.Run' adds it to the reserved list).
skillToolName :: Text
skillToolName = "skill"

-- | The model's call payload: @{"name": ..., "arguments": ...}@.
data SkillCall = SkillCall
  { scName      :: Text
  , scArguments :: Maybe Text
  }
  deriving stock (Show, Eq, Generic)

instance FromJSON SkillCall where
  parseJSON = Aeson.genericParseJSON inputOptions

-- | Render a skill for the given trailing text. The single render path shared
-- by the user-typed @/<name>@ invocation (TUI) and the model's @skill@ tool.
-- Local skills substitute @$ARGUMENTS@ (pure, never 'Left'); MCP prompts parse
-- @key=value@ args, validate required args, and fetch from the live server.
-- 'Left' is human-readable guidance; never throws.
renderSkill :: [McpClient] -> Skill -> Text -> IO (Either Text Text)
renderSkill clients skill rest = case skSource skill of
  LocalSkill body ->
    pure (Right (substituteArgs body (T.strip rest)))
  McpPromptSkill server prompt -> case missingArgs (skRequiredArgs skill) args of
    (m : _) -> pure (Left ("missing required arg: " <> m))
    []      -> case find ((== server) . mcName) clients of
      Nothing -> pure (Left "prompt server unavailable")
      Just c  -> do
        result <- try (getPrompt c prompt args)
                    :: IO (Either SomeException (Either McpError GetPromptResult))
        pure $ case result of
          Left ex         -> Left ("prompt error: " <> T.pack (displayException ex))
          Right (Left e)  -> Left ("prompt error: " <> renderMcpError e)
          Right (Right g) -> Right (T.intercalate "\n\n" (map pmText (gprMessages g)))
  where args = parseArgs rest

-- | Execute one model call against the registry snapshot. Skill-level problems
-- (unknown name, missing args, fetch failure, blank render) come back as
-- guidance text — not a thrown error — so the run survives and the model can
-- self-correct (the M14 convention for error-ish tool results).
runSkillCall :: [McpClient] -> [Skill] -> Value -> IO Text
runSkillCall clients skills v = case Aeson.fromJSON v of
  Aeson.Error e -> pure (T.pack ("invalid skill call: " <> e))
  Aeson.Success c -> case lookupSkill (scName c) skills of
    Nothing -> pure ("unknown skill '" <> scName c <> "'. Valid names: "
                       <> T.intercalate ", " (map skName skills))
    Just s  -> do
      r <- renderSkill clients s (fromMaybe "" (scArguments c))
      pure $ case r of
        Left err -> "skill '" <> skName s <> "' failed: " <> err
        Right rendered
          | T.null (T.strip rendered) ->
              "skill '" <> skName s <> "' produced no content"
          | otherwise -> rendered

-- | The umbrella tool, or 'Nothing' when there are no skills to expose. Built
-- on the 'DynamicTool' tag like the MCP adapters; the executor closes over the
-- clients and the startup skill snapshot.
skillTool :: [McpClient] -> [Skill] -> Maybe SomeTool
skillTool _ [] = Nothing
skillTool clients skills = Just SomeTool
  { toolDef     = DynamicTool
  , toolName    = skillToolName
  , toolDesc    = skillToolDescription skills
  , toolSchema  = skillToolSchema skills
  , toolExecute = liftIO . runSkillCall clients skills
  , toolRender  = id
  }
