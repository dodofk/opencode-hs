module Main where

import Database.SQLite.Simple (close)
import OpenCode.DB (openDb)

main :: IO ()
main = openDb "/tmp/m2-verify.db" >>= close
