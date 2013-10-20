module Main where

import           Control.Monad
import qualified Data.ByteString.Char8 as B
import           Data.Time
import           System.Environment
import           System.Exit
import           System.IO
import           System.Nanomsg
import           Text.Printf

main :: IO ()
main = do
  args <- getArgs
  case args of
    ["node0", url] -> node0 url
    ["node1", url] -> node1 url
    _ -> do
      hPutStrLn stderr "Usage: pipeline node0|node1 <URL> <MSG>"
      exitWith (ExitFailure 1)


node0 :: String -> IO ()
node0 url = do
  sock <- socket AF_SP Rep
  bind sock url
  forever $ do
    req <- recv sock
    case B.unpack req of
      "DATE" -> do
        now <- getCurrentTime
        putStrLn "NODE0: RECEIVED DATE REQUEST"
        putStrLn $ "NODE0: SENDING DATE " ++ show now
        send sock $ B.pack $ show now
      other ->
        putStrLn $ "Unknown request: " ++ other
    freemsg req

node1 :: String -> IO ()
node1 url = do
  sock <- socket AF_SP Req
  eid  <- connect sock url
  putStrLn "NODE1: SENDING DATE REQUEST"
  send sock (B.pack "DATE")
  reply <- recv sock
  putStrLn $ "NODE1: RECEIVED DATE: " ++ B.unpack reply
  freemsg reply
  shutdown sock eid

