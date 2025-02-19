{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE LambdaCase         #-}
{-# LANGUAGE OverloadedStrings  #-}

module HStream.IO.Worker where

import qualified Control.Concurrent        as C
import           Control.Exception         (catch, throw, throwIO)
import           Control.Monad             (forM_, when)
import qualified Data.HashMap.Strict       as HM
import           Data.IORef                (newIORef, readIORef)
import qualified Data.IORef                as C
import           Data.Maybe                (fromMaybe)
import qualified Data.Text                 as T
import qualified Data.Text.Lazy            as TL
import           GHC.Stack                 (HasCallStack)

import qualified Data.Aeson                as J
import qualified Data.Aeson.KeyMap         as J
import qualified Data.Aeson.Text           as J
import           Data.Int                  (Int32)
import qualified Data.Text.Encoding        as T
import qualified Data.UUID                 as UUID
import qualified Data.UUID.V4              as UUID
import qualified HStream.Exception         as HE
import           HStream.IO.IOTask         (getDockerStatus)
import qualified HStream.IO.IOTask         as IOTask
import qualified HStream.IO.Meta           as M
import           HStream.IO.Types
import qualified HStream.Logger            as Log
import           HStream.MetaStore.Types   (MetaHandle (..))
import qualified HStream.Server.HStreamApi as API
import qualified HStream.Stats             as Stats
import qualified HStream.Utils             as Utils

newWorker :: MetaHandle  -> Stats.StatsHolder -> HStreamConfig -> IOOptions -> IO Worker
newWorker mHandle statsHolder hsConfig options = do
  Log.info $ "new Worker with hsConfig:" <> Log.buildString (show hsConfig)
  ioTasksM <- C.newMVar HM.empty
  monitorTid <- newIORef undefined
  let workerHandle = mHandle
  let worker = Worker {..}
  tid <- C.forkIO $ monitor worker
  C.writeIORef monitorTid tid
  return worker

closeWorker :: Worker -> IO ()
closeWorker Worker{..} = do
  tid <- readIORef monitorTid
  C.throwTo tid StopWorkerException

monitor :: Worker -> IO ()
monitor worker@Worker{..} = do
  catch monitorTasks $ \case
    StopWorkerException -> pure ()
  C.threadDelay 3000000
  monitor worker
  where
    monitorTasks = do
      ioTasks <- C.readMVar ioTasksM
      forM_ ioTasks IOTask.monitorProcess

createIOTask :: Worker -> T.Text -> T.Text -> T.Text -> T.Text -> IO API.Connector
createIOTask worker@Worker{..} name typ target cfg = do
  taskId <- UUID.toText <$> UUID.nextRandom
  createdTime <- Utils.getProtoTimestamp
  let IOOptions {..} = options
      taskType = ioTaskTypeFromText typ
      image = makeImage taskType target options
      connectorConfig =
        J.fromList
          [ "hstream" J..= J.toJSON hsConfig
          , "connector" J..= (J.decodeStrict $ T.encodeUtf8 cfg :: Maybe J.Object)
          , "task" J..= taskId
          ]
      taskInfo = TaskInfo
        { taskName = name
        , taskType = taskType
        , taskTarget = target
        , taskCreatedTime = createdTime
        , taskConfig = TaskConfig image optTasksNetwork
        , connectorConfig = connectorConfig
        }
  createIOTaskFromTaskInfo worker taskId taskInfo False True
  showIOTask_ worker name

createIOTaskFromTaskInfo :: HasCallStack => Worker -> T.Text -> TaskInfo -> Bool -> Bool -> IO ()
createIOTaskFromTaskInfo worker@Worker{..} taskId taskInfo@TaskInfo {..} cleanIfExists createMetaData = do
  getIOTask worker taskName >>= \case
    Nothing -> pure ()
    Just _  -> throwIO $ HE.ConnectorExists taskName
  let taskPath = optTasksPath options <> "/" <> taskId
  task <- IOTask.newIOTask taskId workerHandle statsHolder taskInfo taskPath
  IOTask.initIOTask task cleanIfExists
  IOTask.checkIOTask task
  when createMetaData $ M.createIOTaskMeta workerHandle taskName taskId taskInfo
  C.modifyMVar_ ioTasksM $ \ioTasks -> do
    case HM.lookup taskName ioTasks of
      Just _ -> throwIO $ HE.ConnectorExists taskName
      Nothing -> do
        IOTask.startIOTask task
        return $ HM.insert taskName task ioTasks

getSpec :: Worker -> T.Text -> T.Text -> IO T.Text
getSpec Worker{..} typ target = IOTask.getSpec img
  where img = makeImage (ioTaskTypeFromText typ) target options

getTaskLogs :: Worker -> T.Text -> Int32 -> Int32 -> IO T.Text
getTaskLogs worker name beg num = do
  Log.info $ Log.buildString ("getTasksLog:" ++ T.unpack name)
  ioTask <- getIOTask_ worker name
  IOTask.getTaskLogs ioTask beg num

showIOTask_ :: Worker -> T.Text -> IO API.Connector
showIOTask_ worker@Worker{..} name = do
  task@IOTask{taskInfo=TaskInfo{..}, ..} <- getIOTask_ worker name
  taskOffsets <- C.readMVar taskOffsetsM
  M.getIOTaskMeta workerHandle taskId >>= \case
    Nothing -> throwIO $ HE.ConnectorNotFound name
    Just c  -> do
      dockerStatus <- getDockerStatus task
      let connector = convertTaskMeta c
      return $ connector { API.connectorOffsets = taskOffsets
                         , API.connectorTaskId  = taskId
                         , API.connectorNode    = fromMaybe "" (getServerNode connectorConfig)
                         , API.connectorConfig  = getConnectorConfig connectorConfig
                         , API.connectorImage   = tcImage taskConfig
                         , API.connectorDockerStatus = dockerStatus
                         }
 where
   getServerNode cfg = do
     jsonCfg <- J.lookup "hstream" cfg
     HStreamConfig{..} <- case J.fromJSON jsonCfg of
       J.Error _      -> Nothing
       J.Success cfg' -> Just cfg'
     T.stripPrefix "hstream://" serviceUrl

   getConnectorConfig cfg =
    let mConnector :: Maybe J.Value = J.lookup "connector" cfg
     in maybe "" (TL.toStrict . J.encodeToLazyText) mConnector

listIOTasks :: Worker -> IO [API.Connector]
listIOTasks Worker{..} = M.listIOTaskMeta workerHandle

stopIOTask :: Worker -> T.Text -> Bool -> Bool-> IO ()
stopIOTask worker name ifIsRunning force = do
  ioTask <- getIOTask_ worker name
  IOTask.stopIOTask ioTask ifIsRunning force

startIOTask :: Worker -> T.Text -> IO ()
startIOTask worker name = do
  getIOTask_ worker name >>= IOTask.startIOTask

listResources :: Worker -> IO [T.Text]
listResources worker = fmap API.connectorName <$> listIOTasks worker

recoverTask :: Worker -> T.Text -> IO ()
recoverTask worker@Worker{..} name = do
  Log.info $ "recovering task:" <> Log.buildString' name
  M.getIOTaskFromName workerHandle name >>= \case
    Nothing -> throwIO $ HE.ConnectorNotFound name
    Just (taskId, TaskMeta{taskInfoMeta=taskInfo@TaskInfo{..}}) -> do
      let newConnCfg = J.insert "hstream" (J.toJSON hsConfig) connectorConfig
      createIOTaskFromTaskInfo worker taskId taskInfo{connectorConfig=newConnCfg} True False

getIOTask :: Worker -> T.Text -> IO (Maybe IOTask)
getIOTask Worker{..} name = HM.lookup name <$> C.readMVar ioTasksM

getIOTask_ :: Worker -> T.Text -> IO IOTask
getIOTask_ Worker{..} name = do
  ioTasks <- C.readMVar ioTasksM
  case HM.lookup name ioTasks of
    Nothing     -> throwIO $ HE.ConnectorNotFound name
    Just ioTask -> return ioTask

deleteIOTask :: Worker -> T.Text -> IO ()
deleteIOTask worker@Worker{..} taskName = do
  stopIOTask worker taskName True False
  M.deleteIOTaskMeta workerHandle taskName
  C.modifyMVar_ ioTasksM $ return . HM.delete taskName

makeImage :: IOTaskType -> T.Text -> IOOptions -> T.Text
makeImage typ name IOOptions{..} =
  fromMaybe
    (throw $ HE.ConnectorUnimplemented name)
    (HM.lookup name images)
  where images = if typ == SOURCE then optSourceImages else optSinkImages
