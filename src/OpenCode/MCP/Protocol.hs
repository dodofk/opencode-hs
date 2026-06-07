{-# LANGUAGE OverloadedStrings #-}

-- | Pure JSON-RPC 2.0 + MCP wire types and codecs. No IO. Decoders tolerate
-- unknown fields (servers add their own) and missing optional fields.
module OpenCode.MCP.Protocol
  ( -- * JSON-RPC
    JsonRpcRequest (..)
  , JsonRpcNotification (..)
  , JsonRpcResponse (..)
  , JsonRpcError (..)
  , encodeRequest
  , encodeNotification
  , parseResponse
    -- * MCP messages
  , McpCapabilities (..)
  , emptyCaps
  , InitializeResult (..)
  , McpToolDef (..)
  , McpResource (..)
  , McpPromptArg (..)
  , McpPrompt (..)
  , ContentBlock (..)
  , CallToolResult (..)
  , ReadResourceResult (..)
  , PromptMessage (..)
  , GetPromptResult (..)
  , renderContent
    -- * Result-field decoders
  , decodeToolsList
  , decodeResourcesList
  , decodePromptsList
  ) where

import Data.Aeson
  ( FromJSON (..), ToJSON (..), Value (..), (.:), (.:?), (.!=), (.=)
  , object, withObject )
import qualified Data.Aeson as Aeson
import Data.Aeson.Types (parseEither)
import qualified Data.Aeson.KeyMap as KM
import Data.Bifunctor (bimap, first)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BL
import Data.Text (Text)
import qualified Data.Text as T

-- ---------------------------------------------------------------------------
-- JSON-RPC
-- ---------------------------------------------------------------------------

data JsonRpcRequest = JsonRpcRequest
  { reqId :: Int, reqMethod :: Text, reqParams :: Value }
  deriving stock (Show, Eq)

instance ToJSON JsonRpcRequest where
  toJSON r = object
    [ "jsonrpc" .= ("2.0" :: Text)
    , "id"      .= reqId r
    , "method"  .= reqMethod r
    , "params"  .= reqParams r
    ]

data JsonRpcNotification = JsonRpcNotification
  { ntfMethod :: Text, ntfParams :: Value }
  deriving stock (Show, Eq)

instance ToJSON JsonRpcNotification where
  toJSON n = object
    [ "jsonrpc" .= ("2.0" :: Text)
    , "method"  .= ntfMethod n
    , "params"  .= ntfParams n
    ]

instance FromJSON JsonRpcNotification where
  parseJSON = withObject "JsonRpcNotification" $ \o ->
    JsonRpcNotification <$> o .: "method" <*> o .:? "params" .!= Null

data JsonRpcError = JsonRpcError { errCode :: Int, errMessage :: Text }
  deriving stock (Show, Eq)

instance FromJSON JsonRpcError where
  parseJSON = withObject "JsonRpcError" $ \o ->
    JsonRpcError <$> o .: "code" <*> o .: "message"

data JsonRpcResponse = JsonRpcResponse
  { respId :: Int, respResult :: Either JsonRpcError Value }
  deriving stock (Show, Eq)

instance FromJSON JsonRpcResponse where
  parseJSON = withObject "JsonRpcResponse" $ \o -> do
    i    <- o .: "id"
    merr <- o .:? "error"
    case merr of
      Just e  -> pure (JsonRpcResponse i (Left e))
      Nothing -> JsonRpcResponse i . Right <$> o .:? "result" .!= Null

-- | One newline-delimited request line (no trailing newline; the caller adds it).
encodeRequest :: JsonRpcRequest -> BL.ByteString
encodeRequest = Aeson.encode

encodeNotification :: JsonRpcNotification -> BL.ByteString
encodeNotification = Aeson.encode

-- | Classify one server line as a notification or a response. 'Left' on a
-- line that is neither valid JSON nor a recognized JSON-RPC message.
parseResponse :: BS.ByteString -> Either Text (Either JsonRpcNotification JsonRpcResponse)
parseResponse bs = case Aeson.eitherDecodeStrict bs of
  Left e            -> Left (T.pack e)
  Right (Object o)
    | hasId o       -> bimap T.pack Right (parseEither parseJSON (Object o))
    | hasMethod o   -> bimap T.pack Left  (parseEither parseJSON (Object o))
    | otherwise     -> Left "unrecognized JSON-RPC message"
  Right _           -> Left "JSON-RPC message is not an object"
  where
    hasId m     = case KM.lookup "id" m of
                    Just Null -> False
                    Just _    -> True
                    Nothing   -> False
    hasMethod   = KM.member "method"

-- ---------------------------------------------------------------------------
-- MCP messages
-- ---------------------------------------------------------------------------

data McpCapabilities = McpCapabilities
  { capTools :: Bool, capResources :: Bool, capPrompts :: Bool }
  deriving stock (Show, Eq)

emptyCaps :: McpCapabilities
emptyCaps = McpCapabilities False False False

instance FromJSON McpCapabilities where
  parseJSON = withObject "McpCapabilities" $ \o -> pure McpCapabilities
    { capTools     = KM.member "tools" o
    , capResources = KM.member "resources" o
    , capPrompts   = KM.member "prompts" o
    }

data InitializeResult = InitializeResult
  { initProtocolVersion :: Text, initCapabilities :: McpCapabilities }
  deriving stock (Show, Eq)

instance FromJSON InitializeResult where
  parseJSON = withObject "InitializeResult" $ \o -> InitializeResult
    <$> o .:? "protocolVersion" .!= ""
    <*> o .:? "capabilities" .!= emptyCaps

data McpToolDef = McpToolDef
  { mtName :: Text, mtDescription :: Text, mtInputSchema :: Value }
  deriving stock (Show, Eq)

instance FromJSON McpToolDef where
  parseJSON = withObject "McpToolDef" $ \o -> McpToolDef
    <$> o .:  "name"
    <*> o .:? "description" .!= ""
    <*> o .:? "inputSchema" .!= object []

data McpResource = McpResource
  { mrUri :: Text, mrName :: Text, mrDescription :: Maybe Text, mrMimeType :: Maybe Text }
  deriving stock (Show, Eq)

instance FromJSON McpResource where
  parseJSON = withObject "McpResource" $ \o -> McpResource
    <$> o .:  "uri"
    <*> o .:? "name" .!= ""
    <*> o .:? "description"
    <*> o .:? "mimeType"

data McpPromptArg = McpPromptArg
  { mpaName :: Text, mpaDescription :: Maybe Text, mpaRequired :: Bool }
  deriving stock (Show, Eq)

instance FromJSON McpPromptArg where
  parseJSON = withObject "McpPromptArg" $ \o -> McpPromptArg
    <$> o .:  "name"
    <*> o .:? "description"
    <*> o .:? "required" .!= False

data McpPrompt = McpPrompt
  { mpName :: Text, mpDescription :: Maybe Text, mpArguments :: [McpPromptArg] }
  deriving stock (Show, Eq)

instance FromJSON McpPrompt where
  parseJSON = withObject "McpPrompt" $ \o -> McpPrompt
    <$> o .:  "name"
    <*> o .:? "description"
    <*> o .:? "arguments" .!= []

-- | A content block. We only distinguish text from everything else.
data ContentBlock = TextContent Text | OtherContent
  deriving stock (Show, Eq)

instance FromJSON ContentBlock where
  parseJSON = withObject "ContentBlock" $ \o -> do
    mty <- o .:? "type"
    case (mty :: Maybe Text) of
      Just "text" -> TextContent <$> o .:? "text" .!= ""
      Just _      -> pure OtherContent
      Nothing     -> maybe OtherContent TextContent <$> o .:? "text"  -- resource contents

data CallToolResult = CallToolResult
  { ctrContent :: [ContentBlock], ctrIsError :: Bool }
  deriving stock (Show, Eq)

instance FromJSON CallToolResult where
  parseJSON = withObject "CallToolResult" $ \o -> CallToolResult
    <$> o .:? "content" .!= []
    <*> o .:? "isError" .!= False

newtype ReadResourceResult = ReadResourceResult { rrContents :: [ContentBlock] }
  deriving stock (Show, Eq)

instance FromJSON ReadResourceResult where
  parseJSON = withObject "ReadResourceResult" $ \o ->
    ReadResourceResult <$> o .:? "contents" .!= []

data PromptMessage = PromptMessage { pmRole :: Text, pmText :: Text }
  deriving stock (Show, Eq)

instance FromJSON PromptMessage where
  parseJSON = withObject "PromptMessage" $ \o -> do
    role    <- o .:? "role" .!= "user"
    content <- o .: "content"
    pure (PromptMessage role (contentText content))

newtype GetPromptResult = GetPromptResult { gprMessages :: [PromptMessage] }
  deriving stock (Show, Eq)

instance FromJSON GetPromptResult where
  parseJSON = withObject "GetPromptResult" $ \o ->
    GetPromptResult <$> o .:? "messages" .!= []

-- | Extract text from a prompt message's @content@: a content object, or a bare
-- string.
contentText :: Value -> Text
contentText (String s) = s
contentText v = case parseEither parseJSON v of
  Right cb -> renderContent [cb]
  Left _   -> ""

-- | Join text blocks with newlines; render any non-text block as a placeholder.
renderContent :: [ContentBlock] -> Text
renderContent = T.intercalate "\n" . map render
  where
    render (TextContent t) = t
    render OtherContent    = "[non-text content omitted]"

-- ---------------------------------------------------------------------------
-- Result-field decoders (pull a typed list out of a method result object)
-- ---------------------------------------------------------------------------

-- Inline literal keys (OverloadedStrings makes "tools" :: Key); the element
-- type is fixed by each signature.
decodeToolsList :: Value -> Either Text [McpToolDef]
decodeToolsList = first T.pack . parseEither (withObject "toolsList" (.: "tools"))

decodeResourcesList :: Value -> Either Text [McpResource]
decodeResourcesList = first T.pack . parseEither (withObject "resourcesList" (.: "resources"))

decodePromptsList :: Value -> Either Text [McpPrompt]
decodePromptsList = first T.pack . parseEither (withObject "promptsList" (.: "prompts"))
