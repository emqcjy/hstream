{-# LANGUAGE BlockArguments      #-}
{-# LANGUAGE CPP                 #-}
{-# LANGUAGE DataKinds           #-}
{-# LANGUAGE GADTs               #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE RecordWildCards     #-}
{-# LANGUAGE ScopedTypeVariables #-}

module HStream.Server.Handler.Stream
  ( -- * For grpc-haskell
    createStreamHandler
  , deleteStreamHandler
  , getStreamHandler
  , listStreamsHandler
  , listStreamsWithPrefixHandler
  , listShardsHandler
  , appendHandler
    -- * For hs-grpc-server
  , handleCreateStream
  , handleDeleteStream
  , handleGetStream
  , handleListStreams
  , handleListStreamsWithPrefix
  , handleAppend
  , handleListShard
  ) where

import           Control.Exception
import           Data.Maybe                       (fromJust)
import qualified HsGrpc.Server                    as G
import qualified HsGrpc.Server.Types              as G
import           Network.GRPC.HighLevel.Generated

import qualified HStream.Exception                as HE
import qualified HStream.Logger                   as Log
import qualified HStream.Server.Core.Stream       as C
import           HStream.Server.Exception
import           HStream.Server.HStreamApi
import           HStream.Server.Types             (ServerContext (..))
import           HStream.Server.Validation
import qualified HStream.Stats                    as Stats
import qualified HStream.Store                    as Store
import           HStream.ThirdParty.Protobuf      as PB
import           HStream.Utils

--------------------------------------------------------------------------------

createStreamHandler
  :: ServerContext
  -> ServerRequest 'Normal Stream Stream
  -> IO (ServerResponse 'Normal Stream)
createStreamHandler sc (ServerNormalRequest _metadata stream) = defaultExceptionHandle $ do
  Log.debug $ "Receive Create Stream Request: " <> Log.buildString' stream
  validateStream stream
  C.createStream sc stream >>= returnResp

handleCreateStream :: ServerContext -> G.UnaryHandler Stream Stream
handleCreateStream sc _ stream = catchDefaultEx $ do
  Log.debug $ "Receive Create Stream Request: " <> Log.buildString' stream
  validateStream stream
  C.createStream sc stream

-- DeleteStream have two mod: force delete or normal delete
-- For normal delete, if current stream have active subscription, the delete request will return error.
-- For force delete, if current stream have active subscription, the stream will be archived. After that,
-- old stream is no longer visible, current consumers can continue consume from the old subscription,
-- but new consumers are no longer allowed to join that subscription.
--
-- Note: For foce delete, delivery is only guaranteed as far as possible. Which means: a consumer which
-- terminates its consumption for any reason will have no chance to restart the consumption process.
deleteStreamHandler
  :: ServerContext
  -> ServerRequest 'Normal DeleteStreamRequest Empty
  -> IO (ServerResponse 'Normal Empty)
deleteStreamHandler sc (ServerNormalRequest _metadata request) = defaultExceptionHandle $ do
  Log.debug $ "Receive Delete Stream Request: " <> Log.buildString' request
  validateNameAndThrow ResStream $ deleteStreamRequestStreamName request
  C.deleteStream sc request
  returnResp Empty

handleDeleteStream :: ServerContext -> G.UnaryHandler DeleteStreamRequest Empty
handleDeleteStream sc _ req = catchDefaultEx $ do
  Log.debug $ "Receive Delete Stream Request: " <> Log.buildString' req
  validateNameAndThrow ResStream $ deleteStreamRequestStreamName req
  C.deleteStream sc req >> pure Empty

getStreamHandler
  :: ServerContext
  -> ServerRequest 'Normal GetStreamRequest GetStreamResponse
  -> IO (ServerResponse 'Normal GetStreamResponse)
getStreamHandler sc (ServerNormalRequest _metadata request) = defaultExceptionHandle $ do
  Log.debug $ "Receive Get Stream Request: " <> Log.buildString' request
  validateNameAndThrow ResStream $ getStreamRequestName request
  C.getStream sc request >>= returnResp

handleGetStream :: ServerContext -> G.UnaryHandler GetStreamRequest GetStreamResponse
handleGetStream sc _ req = catchDefaultEx $ do
  Log.debug $ "Receive Get Stream Request: " <> Log.buildString' req
  validateNameAndThrow ResStream $ getStreamRequestName req
  C.getStream sc req

listStreamsHandler
  :: ServerContext
  -> ServerRequest 'Normal ListStreamsRequest ListStreamsResponse
  -> IO (ServerResponse 'Normal ListStreamsResponse)
listStreamsHandler sc (ServerNormalRequest _metadata request) = defaultExceptionHandle $ do
  Log.debug "Receive List Stream Request"
  C.listStreams sc request >>= returnResp . ListStreamsResponse

handleListStreams :: ServerContext -> G.UnaryHandler ListStreamsRequest ListStreamsResponse
handleListStreams sc _ req = catchDefaultEx $ do
  Log.debug "Receive List Stream Request"
  ListStreamsResponse <$> C.listStreams sc req

listStreamsWithPrefixHandler
  :: ServerContext
  -> ServerRequest 'Normal ListStreamsWithPrefixRequest ListStreamsResponse
  -> IO (ServerResponse 'Normal ListStreamsResponse)
listStreamsWithPrefixHandler sc (ServerNormalRequest _metadata request) = defaultExceptionHandle $ do
  Log.debug "Receive List Stream Request"
  validateNameAndThrow ResStream $ listStreamsWithPrefixRequestPrefix request
  C.listStreamsWithPrefix sc request >>= returnResp . ListStreamsResponse

handleListStreamsWithPrefix :: ServerContext -> G.UnaryHandler ListStreamsWithPrefixRequest ListStreamsResponse
handleListStreamsWithPrefix sc _ req = catchDefaultEx $ do
  Log.debug "Receive List Stream Request"
  validateNameAndThrow ResStream $ listStreamsWithPrefixRequestPrefix req
  ListStreamsResponse <$> C.listStreamsWithPrefix sc req

appendHandler
  :: ServerContext
  -> ServerRequest 'Normal AppendRequest AppendResponse
  -> IO (ServerResponse 'Normal AppendResponse)
appendHandler sc@ServerContext{..} (ServerNormalRequest _metadata request@AppendRequest{..}) =
  appendStreamExceptionHandle inc_failed $ do
    validateAppendRequest request
    returnResp =<< C.append sc appendRequestStreamName appendRequestShardId (fromJust appendRequestRecords)
  where
    inc_failed = do
      Stats.stream_stat_add_append_failed scStatsHolder cStreamName 1
      Stats.stream_time_series_add_append_failed_requests scStatsHolder cStreamName 1
    cStreamName = textToCBytes appendRequestStreamName

handleAppend :: ServerContext -> G.UnaryHandler AppendRequest AppendResponse
handleAppend sc@ServerContext{..} _ req@AppendRequest{..} = appendExHandle inc_failed $ do
  validateAppendRequest req
  C.append sc appendRequestStreamName appendRequestShardId (fromJust appendRequestRecords)
 where
   inc_failed = do
     Stats.stream_stat_add_append_failed scStatsHolder cStreamName 1
     Stats.stream_time_series_add_append_failed_requests scStatsHolder cStreamName 1
   cStreamName = textToCBytes appendRequestStreamName
{-# INLINE handleAppend #-}

--------------------------------------------------------------------------------

listShardsHandler
  :: ServerContext
  -> ServerRequest 'Normal ListShardsRequest ListShardsResponse
  -> IO (ServerResponse 'Normal ListShardsResponse)
listShardsHandler sc (ServerNormalRequest _metadata request) = listShardsExceptionHandle $ do
  Log.debug "Receive List Shards Request"
  validateNameAndThrow ResStream $ listShardsRequestStreamName request
  C.listShards sc request >>= returnResp . ListShardsResponse

handleListShard :: ServerContext -> G.UnaryHandler ListShardsRequest ListShardsResponse
handleListShard sc _ req = listShardsExHandle $ do
  Log.debug "Receive List Shards Request"
  validateNameAndThrow ResStream $ listShardsRequestStreamName req
  ListShardsResponse <$> C.listShards sc req

--------------------------------------------------------------------------------
-- Exception Handlers

appendStreamExceptionHandle :: IO () -> HE.ExceptionHandle (ServerResponse 'Normal a)
appendStreamExceptionHandle f = HE.mkExceptionHandle' whileEx mkHandlers
  where
    whileEx :: forall e. Exception e => e -> IO ()
    whileEx err = Log.warning (Log.buildString' err) >> f
    handlers =
      [ Handler (\(err :: Store.NOTFOUND) ->
          return (StatusUnavailable, HE.mkStatusDetails err))
      , Handler (\(err :: Store.NOTINSERVERCONFIG) ->
          return (StatusUnavailable, HE.mkStatusDetails err))
      , Handler (\(err :: Store.NOSEQUENCER) -> do
          return (StatusUnavailable, HE.mkStatusDetails err))
      , Handler (\(err :: Store.TIMEDOUT) -> do
          return (StatusUnavailable, HE.mkStatusDetails err))
      ] ++ defaultHandlers
    mkHandlers = HE.setRespType mkServerErrResp handlers

#define MkUnavailable(E) \
  Handler $ \(err :: E) -> do \
    Log.warning (Log.buildString' err); \
    G.throwGrpcError $ HE.mkGrpcStatus err G.StatusUnavailable

appendExHandle :: IO () -> (IO a -> IO a)
appendExHandle f = HE.mkExceptionHandle' (const f) handlers
  where
    handlers =
      [ MkUnavailable(Store.NOTFOUND)
      , MkUnavailable(Store.NOTINSERVERCONFIG)
      , MkUnavailable(Store.NOSEQUENCER)
      , MkUnavailable(Store.TIMEDOUT)
      ] ++ defaultExHandlers

listShardsExceptionHandle :: HE.ExceptionHandle (ServerResponse 'Normal a)
listShardsExceptionHandle = HE.mkExceptionHandle . HE.setRespType mkServerErrResp $
   Handler (\(err :: Store.NOTFOUND) ->
          return (StatusUnavailable, HE.mkStatusDetails err))
  : defaultHandlers

listShardsExHandle :: IO a -> IO a
listShardsExHandle = HE.mkExceptionHandle handlers
  where
    handlers =
      [ Handler $ \(err :: Store.NOTFOUND) -> do
          G.throwGrpcError $ HE.mkGrpcStatus err G.StatusUnavailable
      ] ++ defaultExHandlers

#undef MkUnavailable
