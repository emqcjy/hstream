{-# LANGUAGE BlockArguments      #-}
{-# LANGUAGE CPP                 #-}
{-# LANGUAGE DataKinds           #-}
{-# LANGUAGE GADTs               #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE RecordWildCards     #-}
{-# LANGUAGE ScopedTypeVariables #-}

module HStream.Client.Action
  ( Action

  , createStream
  , createStreamBySelect
  , createStreamBySelectWithCustomQueryName
  , deleteStream
  , getStream
  , listStreams
  , listShards
  , readShard
  , insertIntoStream

  , createSubscription
  , createSubscription'
  , deleteSubscription
  , getSubscription
  , listSubscriptions

  , createConnector
  , listConnectors
  , pauseConnector
  , resumeConnector

  , listQueries
  , listViews
  , terminateQuery
  , pauseQuery
  , resumeQuery

  , dropAction
  , lookupResource
  , describeCluster

  , executeViewQuery

  , retry
  ) where

import           Control.Concurrent               (threadDelay)
import qualified Data.ByteString                  as BS
import qualified Data.Map                         as Map
import qualified Data.Text                        as T
import qualified Data.Vector                      as V
import           Data.Word                        (Word32, Word64)
import           Network.GRPC.HighLevel           (clientCallCancel)
import           Network.GRPC.HighLevel.Generated (ClientError (..),
                                                   ClientRequest (ClientReaderRequest),
                                                   ClientResult (..),
                                                   GRPCIOError (..),
                                                   GRPCMethodType (Normal, ServerStreaming),
                                                   MetadataMap (MetadataMap),
                                                   StatusCode (..))
import qualified Proto3.Suite                     as PT
import           Proto3.Suite.Class               (def)

import           HStream.Client.Types             (Resource (..))
import           HStream.Client.Utils
import           HStream.Server.HStreamApi
import qualified HStream.Server.HStreamApi        as API
import           HStream.SQL.AST                  (StreamName)
#ifdef HStreamUseV2Engine
import           HStream.SQL.Codegen              (DropObject (..),
                                                   InsertType (..),
                                                   TerminationSelection (..))
#else
import           HStream.SQL.Codegen.V1           (DropObject (..),
                                                   InsertType (..),
                                                   TerminateObject (..))
#endif
import           HStream.ThirdParty.Protobuf      (Empty (..))
import           HStream.Utils

type Action a = HStreamClientApi -> IO (ClientResult 'Normal a)

createStream :: StreamName -> Int -> Word32
  -> Action API.Stream
createStream sName rFac rDuration API.HStreamApi{..} =
  hstreamApiCreateStream (mkClientNormalRequest' def
    { API.streamStreamName        = sName
    , API.streamReplicationFactor = fromIntegral rFac
    , API.streamBacklogDuration   = rDuration
    , API.streamShardCount        = 1})

listStreams :: Action API.ListStreamsResponse
listStreams    API.HStreamApi{..} = hstreamApiListStreams clientDefaultRequest
listViews   :: Action API.ListViewsResponse
listViews      API.HStreamApi{..} = hstreamApiListViews clientDefaultRequest
listQueries :: Action API.ListQueriesResponse
listQueries    API.HStreamApi{..} = hstreamApiListQueries clientDefaultRequest
listConnectors :: Action API.ListConnectorsResponse
listConnectors API.HStreamApi{..} = hstreamApiListConnectors clientDefaultRequest
listSubscriptions :: Action API.ListSubscriptionsResponse
listSubscriptions API.HStreamApi{..} = hstreamApiListSubscriptions clientDefaultRequest

terminateQuery :: T.Text
  -> HStreamClientApi
  -> IO (ClientResult 'Normal Empty )
terminateQuery qid API.HStreamApi{..} = hstreamApiTerminateQuery
  (mkClientNormalRequest' def {API.terminateQueryRequestQueryId = qid})

dropAction :: Bool -> DropObject -> Action Empty
dropAction ignoreNonExist dropObject API.HStreamApi{..}  = do
  case dropObject of
    DStream    txt -> hstreamApiDeleteStream (mkClientNormalRequest' def
                      { API.deleteStreamRequestStreamName     = txt
                      , API.deleteStreamRequestIgnoreNonExist = ignoreNonExist
                      , API.deleteStreamRequestForce          = False
                      })

    DView      txt -> hstreamApiDeleteView (mkClientNormalRequest' def
                      { API.deleteViewRequestViewId = txt
                      , API.deleteViewRequestIgnoreNonExist = ignoreNonExist
                      })

    DConnector txt -> hstreamApiDeleteConnector (mkClientNormalRequest' def
                      { API.deleteConnectorRequestName = txt
                      -- , API.deleteConnectorRequestIgnoreNonExist = checkIfExist
                      })
    DQuery txt -> hstreamApiDeleteQuery (mkClientNormalRequest' def
                      { API.deleteQueryRequestId = txt
                      })

insertIntoStream
  :: StreamName -> Word64 -> InsertType -> BS.ByteString
  -> Action API.AppendResponse
insertIntoStream sName shardId insertType payload API.HStreamApi{..} = do
  let header = case insertType of
        JsonFormat -> buildRecordHeader API.HStreamRecordHeader_FlagJSON Map.empty clientDefaultKey
        RawFormat  -> buildRecordHeader API.HStreamRecordHeader_FlagRAW Map.empty clientDefaultKey
      hsRecord = mkHStreamRecord header payload
      record = mkBatchedRecord (PT.Enumerated (Right CompressionTypeNone)) Nothing 1 (V.singleton hsRecord)
  hstreamApiAppend (mkClientNormalRequest' def
    { API.appendRequestShardId    = shardId
    , API.appendRequestStreamName = sName
    , API.appendRequestRecords    = Just record
    })

createStreamBySelect :: String -> Action API.Query
createStreamBySelect sql api  = do
  qName <- newRandomText 10
  createStreamBySelectWithCustomQueryName sql ("cli_generated_" <> qName) api

createStreamBySelectWithCustomQueryName :: String -> T.Text -> Action API.Query
createStreamBySelectWithCustomQueryName sql qName API.HStreamApi{..} = do
  hstreamApiCreateQuery (mkClientNormalRequest' def
    { API.createQueryRequestSql = T.pack sql, API.createQueryRequestQueryName = qName })

createConnector :: T.Text -> T.Text -> T.Text -> T.Text -> Action API.Connector
createConnector name typ target cfg API.HStreamApi{..} =
  hstreamApiCreateConnector (mkClientNormalRequest' def
    { API.createConnectorRequestName = name
    , API.createConnectorRequestType = typ
    , API.createConnectorRequestTarget = target
    , API.createConnectorRequestConfig = cfg })


listShards :: T.Text -> Action API.ListShardsResponse
listShards sName API.HStreamApi{..} = do
  hstreamApiListShards $ mkClientNormalRequest' def {
    listShardsRequestStreamName = sName
  }

lookupResource :: Resource -> Action API.ServerNode
lookupResource (Resource rType rid) API.HStreamApi{..} = hstreamApiLookupResource $
  mkClientNormalRequest' def
    { lookupResourceRequestResId   = rid
    , lookupResourceRequestResType = PT.Enumerated $ Right rType
    }

describeCluster :: Action API.DescribeClusterResponse
describeCluster API.HStreamApi{..} = hstreamApiDescribeCluster clientDefaultRequest

pauseConnector :: T.Text -> Action Empty
pauseConnector cid HStreamApi{..} = hstreamApiPauseConnector $
  mkClientNormalRequest' def { pauseConnectorRequestName = cid }

resumeConnector :: T.Text -> Action Empty
resumeConnector cid HStreamApi{..} = hstreamApiResumeConnector $
  mkClientNormalRequest' def { resumeConnectorRequestName = cid }

pauseQuery :: T.Text -> Action Empty
pauseQuery qid HStreamApi{..} = hstreamApiPauseQuery $
  mkClientNormalRequest' def { pauseQueryRequestId = qid }

resumeQuery :: T.Text -> Action Empty
resumeQuery qid HStreamApi{..} = hstreamApiResumeQuery $
  mkClientNormalRequest' def { resumeQueryRequestId = qid }

createSubscription :: T.Text -> T.Text -> Action Subscription
createSubscription subId sName = createSubscription' (subscriptionWithDefaultSetting subId sName)

createSubscription' :: Subscription -> Action Subscription
createSubscription' sub HStreamApi{..} = hstreamApiCreateSubscription $ mkClientNormalRequest' sub

deleteSubscription :: T.Text -> Bool -> Action Empty
deleteSubscription subId force HStreamApi{..} = hstreamApiDeleteSubscription $
  mkClientNormalRequest' def { deleteSubscriptionRequestSubscriptionId = subId
                             , deleteSubscriptionRequestForce = force}
deleteStream :: T.Text -> Bool -> Action Empty
deleteStream sName force HStreamApi{..} = hstreamApiDeleteStream $
  mkClientNormalRequest' def { deleteStreamRequestStreamName = sName
                             , deleteStreamRequestForce = force}

getStream :: T.Text -> Action GetStreamResponse
getStream sName HStreamApi{..} = hstreamApiGetStream $ mkClientNormalRequest' def { getStreamRequestName = sName }

getSubscription :: T.Text -> Action GetSubscriptionResponse
getSubscription sid HStreamApi{..} = hstreamApiGetSubscription $ mkClientNormalRequest' def { getSubscriptionRequestId = sid }

executeViewQuery :: String -> Action ExecuteViewQueryResponse
executeViewQuery sql HStreamApi{..} = hstreamApiExecuteViewQuery $ mkClientNormalRequest' def { executeViewQueryRequestSql = T.pack sql }

readShard :: API.ReadShardStreamRequest -> HStreamClientApi -> IO (ClientResult 'ServerStreaming API.ReadShardStreamResponse)
readShard req HStreamApi{..} = hstreamApiReadShardStream $
  ClientReaderRequest req requestTimeout (MetadataMap mempty) $ \cancel _meta recv ->
    withInterrupt (clientCallCancel cancel) (readStream recv)
 where
   readStream recv = recv >>= \case
      Left (err :: GRPCIOError) -> errorWithoutStackTrace ("error: " <> show err)
      Right Nothing             -> pure ()  -- do `not` call cancel here
      Right (res :: Maybe API.ReadShardStreamResponse) ->
        case res of
          Nothing   -> readStream recv
          Just res' -> (putStr . formatResult $ res') >> readStream recv

--------------------------------------------------------------------------------

fakeMap :: (a -> b) -> ClientResult 'Normal a -> ClientResult 'Normal b
fakeMap f (ClientNormalResponse x _meta1 _meta2 _status _details) =
  ClientNormalResponse (f x) _meta1 _meta2 _status _details
fakeMap _ (ClientErrorResponse err) = ClientErrorResponse err

retry :: Word32 -> Word32 -> Action a -> Action a
retry n i action api = do
  res <- action api
  case res of
    ClientErrorResponse (ClientIOError (GRPCIOBadStatusCode StatusUnavailable details)) -> do
      threadDelay $ fromIntegral (i * 1000 * 1000)
      if n > 0 then retry (n - 1) i action api else return res
    _ -> return res
