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
    -- * Registry
  , SomeTool (..)
  , ToolRegistry (..)
  , emptyRegistry
  , registerTool
  , lookupTool
  ) where

import Data.Aeson (FromJSON, ToJSON, Value)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import GHC.Generics (Generic)
import OpenCode.App (AppM)
import OpenCode.LLM.Types (ToolDefinition (..))

-- ---------------------------------------------------------------------------
-- Tool input / output records
-- ---------------------------------------------------------------------------

data ReadFileInput = ReadFileInput
  { rfiPath   :: FilePath
  , rfiOffset :: Maybe Int   -- ^ start line (1-indexed)
  , rfiLimit  :: Maybe Int   -- ^ number of lines to read
  }
  deriving stock (Show, Eq, Generic)
  deriving anyclass (FromJSON, ToJSON)

data WriteFileInput = WriteFileInput
  { wfiPath    :: FilePath
  , wfiContent :: Text
  }
  deriving stock (Show, Eq, Generic)
  deriving anyclass (FromJSON, ToJSON)

data EditFileInput = EditFileInput
  { efiPath      :: FilePath
  , efiOldString :: Text
  , efiNewString :: Text
  }
  deriving stock (Show, Eq, Generic)
  deriving anyclass (FromJSON, ToJSON)

data BashInput = BashInput
  { biCommand :: Text
  , biTimeout :: Maybe Int   -- ^ seconds; default 30
  }
  deriving stock (Show, Eq, Generic)
  deriving anyclass (FromJSON, ToJSON)

data BashOutput = BashOutput
  { boStdout   :: Text
  , boStderr   :: Text
  , boExitCode :: Int
  }
  deriving stock (Show, Eq, Generic)
  deriving anyclass (FromJSON, ToJSON)

data GlobInput = GlobInput
  { giPattern :: Text
  , giRoot    :: Maybe FilePath
  }
  deriving stock (Show, Eq, Generic)
  deriving anyclass (FromJSON, ToJSON)

data GrepInput = GrepInput
  { griPattern   :: Text
  , griPath      :: Maybe FilePath
  , griRecursive :: Bool
  }
  deriving stock (Show, Eq, Generic)
  deriving anyclass (FromJSON, ToJSON)

data GrepMatch = GrepMatch
  { gmFile :: FilePath
  , gmLine :: Int
  , gmText :: Text
  }
  deriving stock (Show, Eq, Generic)
  deriving anyclass (FromJSON, ToJSON)

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

-- | Existential wrapper: pairs a GADT tag with its executor in AppM.
data SomeTool = forall i o.
  ( FromJSON i
  , ToJSON   o
  ) => SomeTool
  { toolDef     :: ToolDef i o
  , toolName    :: Text
  , toolDesc    :: Text
  , toolSchema  :: Value           -- ^ JSON Schema for this tool's input
  , toolExecute :: i -> AppM o
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

-- Suppress unused warning until M3
_someToolDefinition :: SomeTool -> ToolDefinition
_someToolDefinition = someToolDefinition
