module HStream.Server.MetaData.Value where

import           Data.Text                     (Text)
import           Z.Data.CBytes                 (CBytes)
import           ZooKeeper.Types               (ZHandle)

import           HStream.IO.Types
import           HStream.MetaStore.Types       (FHandle, HasPath (myRootPath),
                                                RHandle (..))
import           HStream.Server.MetaData.Types
import           HStream.Server.Types          (SubscriptionWrap (..))
import qualified HStream.ThirdParty.Protobuf   as Proto
import           HStream.Utils                 (textToCBytes)

paths :: [CBytes]
paths = [ textToCBytes rootPath
        , textToCBytes ioRootPath
        , textToCBytes $ myRootPath @TaskIdMeta       @ZHandle
        , textToCBytes $ myRootPath @TaskMeta         @ZHandle
        , textToCBytes $ myRootPath @TaskKvMeta       @ZHandle
        , textToCBytes $ myRootPath @ShardReaderMeta      @ZHandle
        , textToCBytes $ myRootPath @QueryInfo        @ZHandle
        , textToCBytes $ myRootPath @QueryStatus      @ZHandle
        , textToCBytes $ myRootPath @ViewInfo         @ZHandle
        , textToCBytes $ myRootPath @SubscriptionWrap @ZHandle
        , textToCBytes $ myRootPath @Proto.Timestamp  @ZHandle
        , textToCBytes $ myRootPath @TaskAllocation   @ZHandle
        , textToCBytes $ myRootPath @QVRelation       @ZHandle
        ]

tables :: [Text]
tables = [
    myRootPath @TaskMeta         @RHandle
  , myRootPath @TaskIdMeta       @RHandle
  , myRootPath @QueryInfo        @RHandle
  , myRootPath @QueryStatus      @RHandle
  , myRootPath @ViewInfo         @RHandle
  , myRootPath @ShardReaderMeta      @RHandle
  , myRootPath @SubscriptionWrap @RHandle
  , myRootPath @Proto.Timestamp  @RHandle
  , myRootPath @TaskAllocation   @RHandle
  , myRootPath @QVRelation       @RHandle
  ]

fileTables :: [Text]
fileTables = [
    myRootPath @TaskMeta         @FHandle
  , myRootPath @TaskIdMeta       @FHandle
  , myRootPath @QueryInfo        @FHandle
  , myRootPath @QueryStatus      @FHandle
  , myRootPath @ViewInfo         @FHandle
  , myRootPath @ShardReaderMeta      @FHandle
  , myRootPath @SubscriptionWrap @FHandle
  , myRootPath @Proto.Timestamp  @FHandle
  , myRootPath @TaskAllocation   @FHandle
  , myRootPath @QVRelation       @FHandle
  ]

clusterStartTimeId :: Text
clusterStartTimeId = "Cluster_Uptime"
