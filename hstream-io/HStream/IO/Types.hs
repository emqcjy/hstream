{-# LANGUAGE DeriveAnyClass        #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TemplateHaskell       #-}

module HStream.IO.Types where

import qualified Control.Concurrent          as C
import           Control.Exception           (Exception)
import qualified Data.Aeson                  as J
import qualified Data.Aeson.TH               as JT
import qualified Data.ByteString.Lazy        as BSL
import qualified Data.ByteString.Lazy.Char8  as BSLC
import qualified Data.HashMap.Strict         as HM
import           Data.IORef                  (IORef)
import qualified Data.Text                   as T
import qualified GHC.IO.Handle               as IO
import qualified System.Process.Typed        as TP
import           ZooKeeper.Types             (ZHandle)

import qualified Control.Exception           as E
import qualified Data.Aeson.KeyMap           as J
import qualified Data.Aeson.Text             as J
import qualified Data.Text.Lazy              as TL
import qualified Data.Vector                 as Vector
import qualified HStream.Exception           as E
import qualified HStream.IO.LineReader       as LR
import           HStream.MetaStore.Types     (FHandle, HasPath (..), MetaHandle,
                                              RHandle (..))
import qualified HStream.Server.HStreamApi   as API
import qualified HStream.Stats               as Stats
import qualified HStream.ThirdParty.Protobuf as Grpc
import qualified HStream.ThirdParty.Protobuf as PB
import           Proto3.Suite                (def)

data IOTaskType = SOURCE | SINK
  deriving (Show, Eq)
$(JT.deriveJSON JT.defaultOptions ''IOTaskType)

data TaskConfig = TaskConfig
  { tcImage   :: T.Text
  , tcNetwork :: T.Text
  }
  deriving (Show)
$(JT.deriveJSON JT.defaultOptions ''TaskConfig)

data TaskInfo = TaskInfo
  { taskName        :: T.Text
  , taskType        :: IOTaskType
  , taskTarget      :: T.Text
  , taskCreatedTime :: Grpc.Timestamp
  , taskConfig      :: TaskConfig
  , connectorConfig :: J.Object
  }
  deriving (Show)
$(JT.deriveJSON JT.defaultOptions ''TaskInfo)

data IOTaskStatus
  = NEW
  | RUNNING
  | STOPPED
  | FAILED
  | COMPLETED
  | DELETED
  deriving (Show, Eq)
$(JT.deriveJSON JT.defaultOptions ''IOTaskStatus)

data IOOptions = IOOptions
  { optTasksNetwork :: T.Text
  , optTasksPath    :: T.Text
  , optSourceImages :: HM.HashMap T.Text T.Text
  , optSinkImages   :: HM.HashMap T.Text T.Text
  } deriving (Show, Eq)

type TaskProcess = TP.Process IO.Handle IO.Handle IO.Handle

data IOTask = IOTask
  { taskId          :: T.Text
  , taskInfo        :: TaskInfo
  , taskPath        :: FilePath
  , taskHandle      :: MetaHandle
  , process'        :: IORef (Maybe TaskProcess)
  , statusM         :: C.MVar IOTaskStatus
  , taskStatsHolder :: Stats.StatsHolder
  , taskOffsetsM    :: C.MVar (Vector.Vector PB.Struct)
  , logReader       :: LR.LineReader
  }

type ZkUrl = T.Text
type Path = T.Text
data ConnectorMetaConfig
  -- ZkKvConfig zkUrl rootPath
  = ZkKvConfig  ZkUrl Path
  | FileKvConfig FilePath

newtype HStreamConfig = HStreamConfig
  { serviceUrl :: T.Text
  } deriving (Show)
$(JT.deriveJSON JT.defaultOptions ''HStreamConfig)

data Worker = Worker
  { hsConfig     :: HStreamConfig
  , options      :: IOOptions
  , ioTasksM     :: C.MVar (HM.HashMap T.Text IOTask)
  , monitorTid   :: IORef C.ThreadId
  , workerHandle :: MetaHandle
  , statsHolder  :: Stats.StatsHolder
  }

data TaskMeta = TaskMeta {
    taskInfoMeta  :: TaskInfo
  , taskStateMeta :: IOTaskStatus
  } deriving (Show)
$(JT.deriveJSON JT.defaultOptions ''TaskMeta)

newtype TaskIdMeta = TaskIdMeta {taskIdMeta :: T.Text}
  deriving (Show)
$(JT.deriveJSON JT.defaultOptions ''TaskIdMeta)

newtype TaskKvMeta = TaskKvMeta
  { value :: T.Text
  } deriving (Show)
$(JT.deriveJSON JT.defaultOptions ''TaskKvMeta)

ioRootPath :: T.Text
ioRootPath = "/hstream/io"

instance HasPath TaskMeta ZHandle where
  myRootPath = ioRootPath <> "/tasks"

instance HasPath TaskIdMeta ZHandle where
  myRootPath = ioRootPath <> "/taskNames"

instance HasPath TaskKvMeta ZHandle where
  myRootPath = ioRootPath <> "/taskKvs"

instance HasPath TaskMeta RHandle where
  myRootPath = "ioTasks"

instance HasPath TaskIdMeta RHandle where
  myRootPath = "ioTaskNames"

instance HasPath TaskKvMeta RHandle where
  myRootPath = "ioTaskKvs"

instance HasPath TaskMeta FHandle where
  myRootPath = "ioTasks"

instance HasPath TaskIdMeta FHandle where
  myRootPath = "ioTaskNames"

instance HasPath TaskKvMeta FHandle where
  myRootPath = "ioTaskKvs"

convertTaskMeta :: TaskMeta -> API.Connector
convertTaskMeta TaskMeta {..} =
  def { API.connectorName = taskName taskInfoMeta
      , API.connectorType = ioTaskTypeToText . taskType $ taskInfoMeta
      , API.connectorTarget = taskTarget taskInfoMeta
      , API.connectorCreationTime = Just . taskCreatedTime $ taskInfoMeta
      , API.connectorStatus = ioTaskStatusToText taskStateMeta
      , API.connectorConfig = TL.toStrict . J.encodeToLazyText . J.lookup "connector" $ connectorConfig taskInfoMeta
      }

ioTaskStatusToText :: IOTaskStatus -> T.Text
ioTaskStatusToText = T.pack . show

ioTaskStatusToBS :: IOTaskStatus -> BSL.ByteString
ioTaskStatusToBS = BSLC.pack . show

ioTaskTypeToText :: IOTaskType -> T.Text
ioTaskTypeToText typ = case typ of
  SOURCE -> "SOURCE"
  SINK   -> "SINK"

ioTaskTypeFromText :: T.Text -> IOTaskType
ioTaskTypeFromText typ = case T.toUpper typ of
  "SOURCE" -> SOURCE
  "SINK"   -> SINK
  _        -> E.throw (E.InvalidConnectorType typ)

-- -------------------------------------------------------------------------- --

data StopWorkerException = StopWorkerException deriving Show
instance Exception StopWorkerException
