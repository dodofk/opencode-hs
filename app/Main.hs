module Main (main) where

import OpenCode.App (runApp)
import OpenCode.Tool.Registry (defaultBuiltinRegistry)

main :: IO ()
main = runApp defaultBuiltinRegistry
