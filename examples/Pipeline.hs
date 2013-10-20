module Main where

import           Control.Monad
import qualified Data.ByteString.Char8 as B
import           System.Environment
import           System.Exit
import           System.IO
import           System.Nanomsg
import           Text.Printf

main :: IO ()
main = do
  args <- getArgs
  case args of
    ["node0", url]      -> node0 url
    ["node1", url, msg] -> node1 url msg
    _ -> do
      hPutStrLn stderr "Usage: pipeline node0|node1 <URL> <MSG>"
      exitWith (ExitFailure 1)


node0 :: String -> IO ()
node0 url = do
  sock <- socket AF_SP Pull
  bind sock url
  forever $ do
    buf <- recv sock
    printf "NODE0: RECEIVED: \"%s\"\n" (B.unpack buf)
    freemsg buf

node1 :: String -> String -> IO ()
node1 url msg = do
  sock <- socket AF_SP Push
  eid <- connect sock url
  printf "NODE1: SENDING \"%s\"\n" msg
  send sock (B.pack msg)
  shutdown sock eid
  return ()

