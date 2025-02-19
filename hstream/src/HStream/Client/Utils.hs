{-# LANGUAGE DataKinds           #-}
{-# LANGUAGE GADTs               #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE RecordWildCards     #-}
{-# LANGUAGE ScopedTypeVariables #-}

module HStream.Client.Utils
  ( clientDefaultRequest
  , calculateShardId
  , extractSelect
  , genClientId
  , mkClientNormalRequest'
  , printResult
  , dropPlanToResType
  , requestTimeout
  , subscriptionWithDefaultSetting
  , terminateMsg
  , waitForServerToStart
  , withInterrupt
  , removeEmitChanges) where

import           Control.Concurrent               (threadDelay)
import           Control.Exception                (finally)
import           Crypto.Hash.MD5                  (hash)
import qualified Data.ByteString                  as BS
import           Data.Char                        (toUpper)
import           Data.Functor                     ((<&>))
import           Data.Int                         (Int32)
import           Data.String                      (IsString)
import qualified Data.Text                        as T
import qualified Data.Text.Encoding               as BS
import           Data.Word                        (Word64)
import           Network.GRPC.HighLevel.Client
import           Network.GRPC.HighLevel.Generated (withGRPCClient)
import           Proto3.Suite                     (Enumerated (..))
import           Proto3.Suite.Class               (HasDefault, def)
import           System.Posix                     (Handler (Catch),
                                                   installHandler,
                                                   keyboardSignal)


import           HStream.Base                     (genUnique)
import           HStream.Client.Types             (Resource (..))
import qualified HStream.Server.HStreamApi        as API
import           HStream.SQL                      (DropObject (..))
import           HStream.Utils                    (Format (formatResult),
                                                   ResourceType (..),
                                                   SocketAddr (..),
                                                   mkClientNormalRequest,
                                                   mkGRPCClientConfWithSSL)

terminateMsg :: IsString a => a
terminateMsg = "\x1b[32mTerminated\x1b[0m"

clientDefaultRequest :: HasDefault a => ClientRequest 'Normal a b
clientDefaultRequest = mkClientNormalRequest' def

requestTimeout :: Int
requestTimeout = 1000

subAckTimeout :: Int32
subAckTimeout = 1

subMaxUnack :: Int32
subMaxUnack = 100

subscriptionWithDefaultSetting :: T.Text -> T.Text -> API.Subscription
subscriptionWithDefaultSetting subscriptionSubscriptionId subscriptionStreamName =
  API.Subscription { subscriptionAckTimeoutSeconds = subAckTimeout
                   , subscriptionMaxUnackedRecords = subMaxUnack
                   , subscriptionOffset = Enumerated (Right API.SpecialOffsetEARLIEST)
                   , subscriptionCreationTime = Nothing
                   , ..}

mkClientNormalRequest' :: a -> ClientRequest 'Normal a b
mkClientNormalRequest' = mkClientNormalRequest requestTimeout

extractSelect :: [String] -> T.Text
extractSelect = T.pack .
  unwords . reverse . ("CHANGES;" :) .
  dropWhile ((/= "EMIT") . map toUpper) .
  reverse .
  dropWhile ((/= "SELECT") . map toUpper)

waitForServerToStart :: Int -> SocketAddr -> Maybe ClientSSLConfig -> IO (Maybe ())
waitForServerToStart t addr clientSSLConfig = withGRPCClient (mkGRPCClientConfWithSSL addr clientSSLConfig) $ \client -> do
  api <- API.hstreamApiClient client
  loop t api
  where
    interval = 1000000
    loop timeout api@API.HStreamApi{..} = do
     resp <- hstreamApiDescribeCluster (mkClientNormalRequest' def)
     case resp of
       ClientNormalResponse {} -> return $ Just ()
       _                       -> do
         let newTimeout = timeout - interval
         threadDelay interval
         putStrLn "Waiting for server to start..."
         if newTimeout <= 0 then return Nothing
           else loop newTimeout api

calculateShardId :: T.Text -> [API.Shard] -> Maybe Word64
calculateShardId key (API.Shard{..}:ss) =
  case (compareHash result start, compareHash result end) of
    (GT, LT) -> Just shardShardId
    (EQ, _)  -> Just shardShardId
    (_, EQ)  -> Just shardShardId
    _        -> calculateShardId key ss
  where
    compareHash x y = if BS.length x == BS.length y
      then x `compare` y
      else BS.length x `compare` BS.length y
    start = BS.encodeUtf8 shardStartHashRangeKey
    end = BS.encodeUtf8 shardEndHashRangeKey
    result = hash (BS.encodeUtf8 key)
calculateShardId _ _ = Nothing

dropPlanToResType :: DropObject -> Resource
dropPlanToResType (DConnector x) = Resource ResConnector x
dropPlanToResType (DView x)      = Resource ResView x
dropPlanToResType (DStream x)    = Resource ResStream x
dropPlanToResType (DQuery x)     = Resource ResQuery x

genClientId :: IO T.Text
genClientId = genUnique <&> (("hstream_cli_client_" <>) . T.pack . show)

withInterrupt :: IO () -> IO a -> IO a
withInterrupt interruptHandle act = do
  old_handler <- installHandler keyboardSignal (Catch interruptHandle) Nothing
  act `finally` installHandler keyboardSignal old_handler Nothing

removeEmitChanges :: [String] -> String
removeEmitChanges = unwords . reverse . (";" :) . drop 1 . dropWhile ((/= "EMIT") . map toUpper) . reverse

--------------------------------------------------------------------------------

printResult :: Format a => a -> IO ()
printResult resp = putStr $ formatResult resp
