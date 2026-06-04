-- | Pure CLI surface: the command grammar plus the pure parsers and renderers
-- the test suite exercises directly. All IO orchestration lives in
-- 'OpenCode.Run'; this module imports no IO and breaks no cycles.
module OpenCode.CLI
  ( Command (..)
  , RunOpts (..)
  , defaultRunOpts
  , parseModelId
  , providerLabel
  ) where

import Data.Text (Text)
import qualified Data.Text as T

import OpenCode.Types (ModelId (..), ProviderId (..), SessionId (..))

-- | A parsed top-level command.
data Command
  = Run RunOpts
  | List
  | Export SessionId
  | ConfigCheck
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
      let modelText = T.drop 1 rest
      in if T.null modelText
           then Left ("missing model in: " <> raw)
           else case providerFromText provText of
             Just p  -> Right (ModelId { provider = p, model = modelText })
             Nothing -> Left ("unknown provider: " <> provText)

providerFromText :: Text -> Maybe ProviderId
providerFromText = \case
  "openai"    -> Just OpenAI
  "anthropic" -> Just Anthropic
  "minimax"   -> Just MiniMax
  _           -> Nothing
