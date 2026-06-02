module Main (main) where

import OpenCode.Run (runApp)
import OpenCode.Tool.Registry (defaultBuiltinRegistry)

main :: IO ()
main = runApp defaultBuiltinRegistry
