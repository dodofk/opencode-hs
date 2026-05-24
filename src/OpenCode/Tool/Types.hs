-- | Type-safe tool system using GADTs and existential wrappers.
module OpenCode.Tool.Types
  ( -- * GADT
    ToolDef (..)
    -- * Input/output records (one per tool)
  , ReadFileInput (..)
  , WriteFileInput (..)
  , EditFileInput (..)
  , BashInput (..)
  , BashOutput (..)
  , GlobInput (..)
  , GrepInput (..)
  , GrepMatch (..)
    -- * Existential wrapper
  , SomeTool (..)
    -- * Registry
  , ToolRegistry (..)
  , emptyRegistry
  , registerTool
  , lookupTool
  , someToolDefinition
    -- * Dispatch
  , executeTool
    -- * Aeson helpers
  , inputOptions
  ) where

import Control.Monad.Except (throwError)
import Data.Aeson (FromJSON (..), ToJSON (..), Value (..))
import qualified Data.Aeson as Aeson
import Data.Char (isLower, toLower)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as Text
import GHC.Generics (Generic)

import OpenCode.App.Error (AppError (..))
import {-# SOURCE #-} OpenCode.App.Types (AppM)
import OpenCode.LLM.Types (ToolDefinition (..))

-- ---------------------------------------------------------------------------
-- Aeson options: strip field-name prefix, omit Nothing fields
--
-- Field naming convention: each record uses a 2-3 letter lowercase prefix
-- ('rfi' for ReadFileInput, 'bo' for BashOutput, etc.). The JSON wire format
-- strips this prefix so the LLM sees clean lowercase field names ('path',
-- 'offset', 'stdout', etc.).
-- ---------------------------------------------------------------------------

inputOptions :: Aeson.Options
inputOptions = Aeson.defaultOptions
  { Aeson.fieldLabelModifier = stripFieldPrefix
  , Aeson.omitNothingFields  = True
  }
  where
    -- Drop leading lowercase letters, then lowercase the next letter.
    -- "rfiPath" -> "path", "boStdout" -> "stdout", "path" (no prefix) -> "path".
    stripFieldPrefix s = case dropWhile isLower s of
      []       -> s
      (c:rest) -> toLower c : rest

-- ---------------------------------------------------------------------------
-- Tool input / output records
-- ---------------------------------------------------------------------------

data ReadFileInput = ReadFileInput
  { rfiPath   :: FilePath
  , rfiOffset :: Maybe Int   -- ^ start line (1-indexed)
  , rfiLimit  :: Maybe Int   -- ^ number of lines to read
  }
  deriving stock (Show, Eq, Generic)

instance FromJSON ReadFileInput where parseJSON = Aeson.genericParseJSON inputOptions
instance ToJSON   ReadFileInput where toJSON    = Aeson.genericToJSON    inputOptions

data WriteFileInput = WriteFileInput
  { wfiPath    :: FilePath
  , wfiContent :: Text
  }
  deriving stock (Show, Eq, Generic)

instance FromJSON WriteFileInput where parseJSON = Aeson.genericParseJSON inputOptions
instance ToJSON   WriteFileInput where toJSON    = Aeson.genericToJSON    inputOptions

data EditFileInput = EditFileInput
  { efiPath      :: FilePath
  , efiOldString :: Text
  , efiNewString :: Text
  }
  deriving stock (Show, Eq, Generic)

instance FromJSON EditFileInput where parseJSON = Aeson.genericParseJSON inputOptions
instance ToJSON   EditFileInput where toJSON    = Aeson.genericToJSON    inputOptions

data BashInput = BashInput
  { biCommand :: Text
  , biTimeout :: Maybe Int   -- ^ seconds; default 30
  }
  deriving stock (Show, Eq, Generic)

instance FromJSON BashInput where parseJSON = Aeson.genericParseJSON inputOptions
instance ToJSON   BashInput where toJSON    = Aeson.genericToJSON    inputOptions

data BashOutput = BashOutput
  { boStdout   :: Text
  , boStderr   :: Text
  , boExitCode :: Int
  }
  deriving stock (Show, Eq, Generic)

instance FromJSON BashOutput where parseJSON = Aeson.genericParseJSON inputOptions
instance ToJSON   BashOutput where toJSON    = Aeson.genericToJSON    inputOptions

data GlobInput = GlobInput
  { giPattern :: Text
  , giRoot    :: Maybe FilePath
  }
  deriving stock (Show, Eq, Generic)

instance FromJSON GlobInput where parseJSON = Aeson.genericParseJSON inputOptions
instance ToJSON   GlobInput where toJSON    = Aeson.genericToJSON    inputOptions

data GrepInput = GrepInput
  { griPattern   :: Text
  , griPath      :: Maybe FilePath
  , griRecursive :: Maybe Bool
  }
  deriving stock (Show, Eq, Generic)

instance FromJSON GrepInput where parseJSON = Aeson.genericParseJSON inputOptions
instance ToJSON   GrepInput where toJSON    = Aeson.genericToJSON    inputOptions

data GrepMatch = GrepMatch
  { gmFile :: FilePath
  , gmLine :: Int
  , gmText :: Text
  }
  deriving stock (Show, Eq, Generic)

instance FromJSON GrepMatch where parseJSON = Aeson.genericParseJSON inputOptions
instance ToJSON   GrepMatch where toJSON    = Aeson.genericToJSON    inputOptions

-- ---------------------------------------------------------------------------
-- GADT
-- ---------------------------------------------------------------------------

data ToolDef input output where
  ReadFileTool  :: ToolDef ReadFileInput  Text
  WriteFileTool :: ToolDef WriteFileInput Text
  EditFileTool  :: ToolDef EditFileInput  Text
  BashTool      :: ToolDef BashInput      BashOutput
  GlobTool      :: ToolDef GlobInput      [FilePath]
  GrepTool      :: ToolDef GrepInput      [GrepMatch]

-- | Existential wrapper: pairs a GADT tag with its executor and renderer.
-- Only 'FromJSON' is required on the input type — the output renderer is
-- supplied per-tool, so structured-output tools (M7's Bash, Grep) can JSON-
-- encode while text-output tools (M5's file tools) can pass text through.
data SomeTool = forall i o.
  FromJSON i => SomeTool
  { toolDef     :: ToolDef i o
  , toolName    :: Text
  , toolDesc    :: Text
  , toolSchema  :: Value          -- ^ JSON Schema for this tool's input
  , toolExecute :: i -> AppM o
  , toolRender  :: o -> Text      -- ^ how to present output to the LLM
  }

-- ---------------------------------------------------------------------------
-- Registry
-- ---------------------------------------------------------------------------

newtype ToolRegistry = ToolRegistry
  { unRegistry :: Map Text SomeTool
  }

emptyRegistry :: ToolRegistry
emptyRegistry = ToolRegistry Map.empty

registerTool :: SomeTool -> ToolRegistry -> ToolRegistry
registerTool t (ToolRegistry m) = ToolRegistry (Map.insert (toolName t) t m)

lookupTool :: Text -> ToolRegistry -> Maybe SomeTool
lookupTool name (ToolRegistry m) = Map.lookup name m

-- | Convert a registry entry to the wire format sent to the LLM.
someToolDefinition :: SomeTool -> ToolDefinition
someToolDefinition t = ToolDefinition
  { tdName        = toolName t
  , tdDescription = toolDesc t
  , tdSchema      = toolSchema t
  }

-- ---------------------------------------------------------------------------
-- Dispatch
-- ---------------------------------------------------------------------------

-- | Look up a tool by name, decode the JSON arguments to its typed input,
-- run the handler, and render the output as 'Text'. Raises 'ToolError' on
-- unknown name or malformed arguments.
executeTool :: ToolRegistry -> Text -> Value -> AppM Text
executeTool reg name args = case lookupTool name reg of
  Nothing -> throwError (ToolError name "unknown tool")
  Just SomeTool { toolExecute = exec, toolRender = render } ->
    case Aeson.fromJSON args of
      Aeson.Error e       -> throwError (ToolError name (Text.pack e))
      Aeson.Success input -> do
        output <- exec input
        pure (render output)
