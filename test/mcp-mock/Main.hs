{-# LANGUAGE OverloadedStrings #-}

-- | A minimal MCP server over stdio for integration tests. Advertises tools,
-- resources, and prompts. The @echo@ tool returns its JSON arguments as text.
module Main (main) where

import Data.Aeson (Value (..), object, (.=))
import qualified Data.Aeson as Aeson
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BL
import Data.Text (Text)
import Data.Text.Encoding (decodeUtf8)
import System.IO
  ( BufferMode (LineBuffering), hFlush, hSetBuffering, isEOF, stdin, stdout )

main :: IO ()
main = do
  hSetBuffering stdout LineBuffering
  hSetBuffering stdin LineBuffering
  loop

loop :: IO ()
loop = do
  eof <- isEOF
  if eof
    then pure ()
    else do
      line <- BS.hGetLine stdin
      case Aeson.decodeStrict line :: Maybe Value of
        Just (Object o) -> dispatch o >> loop
        _               -> loop

dispatch :: KM.KeyMap Value -> IO ()
dispatch o = case KM.lookup "id" o of
  Nothing    -> pure ()                       -- notification; ignore
  Just idVal -> respond idVal (methodOf o) o

methodOf :: KM.KeyMap Value -> Text
methodOf o = case KM.lookup "method" o of
  Just (String m) -> m
  _               -> ""

respond :: Value -> Text -> KM.KeyMap Value -> IO ()
respond idVal method o = case method of
  "initialize" -> reply idVal $ object
    [ "protocolVersion" .= ("2024-11-05" :: Text)
    , "capabilities" .= object
        [ "tools" .= object [], "resources" .= object [], "prompts" .= object [] ]
    , "serverInfo" .= object ["name" .= ("mock" :: Text), "version" .= ("0" :: Text)]
    ]
  "tools/list" -> reply idVal $ object
    [ "tools" .=
        [ object
            [ "name" .= ("echo" :: Text)
            , "description" .= ("echoes its arguments" :: Text)
            , "inputSchema" .= object ["type" .= ("object" :: Text)]
            ]
        ]
    ]
  "tools/call"
    | toolNameOf o == "boom" -> replyError idVal "boom tool always fails"
    | otherwise -> reply idVal $ object
        [ "content" .= [ object ["type" .= ("text" :: Text), "text" .= echoArgs o] ]
        , "isError" .= False
        ]
  "resources/list" -> reply idVal $ object
    [ "resources" .=
        [ object ["uri" .= ("mock://a" :: Text), "name" .= ("a" :: Text)] ]
    ]
  "resources/read" -> reply idVal $ object
    [ "contents" .=
        [ object ["uri" .= ("mock://a" :: Text), "text" .= ("resource body" :: Text)] ]
    ]
  "prompts/list" -> reply idVal $ object
    [ "prompts" .=
        [ object
            [ "name" .= ("greet" :: Text)
            , "description" .= ("greet someone" :: Text)
            , "arguments" .= ([] :: [Value])
            ]
        ]
    ]
  "prompts/get" -> reply idVal $ object
    [ "messages" .=
        [ object
            [ "role" .= ("user" :: Text)
            , "content" .= object ["type" .= ("text" :: Text), "text" .= ("hello there" :: Text)]
            ]
        ]
    ]
  _ -> replyError idVal ("unknown method: " <> method)

-- | The JSON-encoded @arguments@ of a tools/call request, as text.
echoArgs :: KM.KeyMap Value -> Text
echoArgs o = case KM.lookup "params" o of
  Just (Object p) -> case KM.lookup "arguments" p of
    Just args -> decodeUtf8 (BL.toStrict (Aeson.encode args))
    Nothing   -> "{}"
  _ -> "{}"

-- | The @name@ of a tools/call request.
toolNameOf :: KM.KeyMap Value -> Text
toolNameOf o = case KM.lookup "params" o of
  Just (Object p) -> case KM.lookup "name" p of
    Just (String n) -> n
    _               -> ""
  _ -> ""

reply :: Value -> Value -> IO ()
reply idVal result =
  emit (object ["jsonrpc" .= ("2.0" :: Text), "id" .= idVal, "result" .= result])

replyError :: Value -> Text -> IO ()
replyError idVal msg =
  emit (object
    [ "jsonrpc" .= ("2.0" :: Text)
    , "id" .= idVal
    , "error" .= object ["code" .= (-32601 :: Int), "message" .= msg]
    ])

emit :: Value -> IO ()
emit v = BL.hPut stdout (Aeson.encode v) >> BL.hPut stdout "\n" >> hFlush stdout
