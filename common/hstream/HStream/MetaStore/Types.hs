{-# LANGUAGE AllowAmbiguousTypes   #-}
{-# LANGUAGE CPP                   #-}
{-# LANGUAGE DataKinds             #-}
{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE TupleSections         #-}
{-# LANGUAGE TypeFamilies          #-}
{-# LANGUAGE UndecidableInstances  #-}

module HStream.MetaStore.Types where

import           Control.Exception                (Handler (..), catches, try)
import           Control.Monad                    (void)
import           Data.Aeson                       (FromJSON, ToJSON)
import qualified Data.Aeson                       as A
import qualified Data.ByteString                  as BS
import qualified Data.ByteString.Lazy             as BL
import           Data.Functor                     ((<&>))
import qualified Data.Map.Strict                  as Map
import           Data.Maybe                       (catMaybes, isJust)
import qualified Data.Text                        as T
import           Data.Text.Encoding               (decodeUtf8)
import           GHC.Stack                        (HasCallStack)
import           Network.HTTP.Client              (Manager)
import qualified Z.Foreign                        as ZF
import qualified ZooKeeper                        as Z
import           ZooKeeper.Exception              (ZooException)
import qualified ZooKeeper.Types                  as Z
import           ZooKeeper.Types                  (ZHandle)

import qualified HStream.MetaStore.FileUtils      as File
import           HStream.MetaStore.RqliteUtils    (ROp (..), transaction)
import qualified HStream.MetaStore.RqliteUtils    as RQ
import           HStream.MetaStore.ZookeeperUtils (createInsertZK,
                                                   decodeDataCompletion,
                                                   decodeZNodeValue,
                                                   deleteZkChildren,
                                                   deleteZkPath, setZkData,
                                                   upsertZkData)
import           HStream.Utils                    (cBytesToText, textToCBytes)

type Key = T.Text
type Path = T.Text
type Url = T.Text
type Version = Int
class (MetaStore value handle, HasPath value handle) => MetaType value handle
instance (MetaStore value handle, HasPath value handle) => MetaType value handle
type FHandle = FilePath
data RHandle = RHandle Manager Url
data MetaHandle
  = ZkHandle ZHandle
  | RLHandle RHandle
  | FileHandle FHandle
-- TODO
--  | LocalHandle FHandle

data MetaOp
  = InsertOp Path Key BS.ByteString
  | UpdateOp Path Key BS.ByteString (Maybe Version)
  | DeleteOp Path Key (Maybe Version)
  | CheckOp  Path Key Version

class (ToJSON a, FromJSON a, Show a) => HasPath a handle where
  myRootPath :: T.Text
  myExceptionHandler :: Key -> [Handler b]
  myExceptionHandler = const []

#define RETHROW(action, handle) \
  catches (action) (myExceptionHandler @value @handle mid)

class MetaStore value handle where
  myPath     :: HasPath value handle => T.Text -> T.Text
  insertMeta :: (HasPath value handle, HasCallStack) => Key -> value -> handle -> IO ()
  updateMeta :: (HasPath value handle, HasCallStack) => Key -> value -> Maybe Version -> handle -> IO ()
  upsertMeta :: (HasPath value handle, HasCallStack) => Key -> value -> handle -> IO ()
  deleteMeta :: (HasPath value handle, HasCallStack) => Key -> Maybe Version -> handle  -> IO ()
  listMeta   :: (HasPath value handle, HasCallStack) => handle -> IO [value]
  getMeta    :: (HasPath value handle, HasCallStack) => Key -> handle -> IO (Maybe value)
  getMetaWithVer  :: (HasPath value handle, HasCallStack) => Key -> handle -> IO (Maybe (value, Int))
  getAllMeta      :: (HasPath value handle, HasCallStack) => handle -> IO (Map.Map Key value)
  deleteAllMeta   :: (HasPath value handle, HasCallStack) => handle -> IO ()
  checkMetaExists :: (HasPath value handle, HasCallStack) => Key -> handle -> IO Bool

  -- FIXME: The Operation is not atomic
  updateMetaWith  :: (HasPath value handle, HasCallStack) => Key -> (Maybe value -> value) -> Maybe Version -> handle -> IO ()
  updateMetaWith mid f mv h = getMeta @value mid h >>= \x -> updateMeta mid (f x) mv h

  insertMetaOp :: HasPath value handle => Key -> value -> handle -> MetaOp
  updateMetaOp :: HasPath value handle => Key -> value -> Maybe Version -> handle -> MetaOp
  deleteMetaOp :: HasPath value handle => Key -> Maybe Version -> handle -> MetaOp
  checkOp      :: HasPath value handle => Key -> Version -> handle -> MetaOp
  insertMetaOp mid value    _ = InsertOp (myRootPath @value @handle) mid (BL.toStrict $ A.encode value)
  updateMetaOp mid value mv _ = UpdateOp (myRootPath @value @handle) mid (BL.toStrict $ A.encode value) mv
  deleteMetaOp mid mv       _ = DeleteOp (myRootPath @value @handle) mid mv
  checkOp mid v             _ = CheckOp  (myRootPath @value @handle) mid v

class MetaMulti handle where
  metaMulti :: [MetaOp] -> handle -> IO ()

instance MetaStore value ZHandle where
  myPath mid = myRootPath @value @ZHandle <> "/" <> mid
  insertMeta mid x zk    = RETHROW(createInsertZK zk (myPath @value @ZHandle mid) x   ,ZHandle)
  updateMeta mid x mv zk = RETHROW(setZkData      zk (myPath @value @ZHandle mid) x mv,ZHandle)
  upsertMeta mid x    zk = RETHROW(upsertZkData   zk (myPath @value @ZHandle mid) x   ,ZHandle)
  deleteMeta mid   mv zk = RETHROW(deleteZkPath   zk (myPath @value @ZHandle mid) mv  ,ZHandle)
  deleteAllMeta       zk = RETHROW(deleteZkChildren zk (myRootPath @value @ZHandle)   ,ZHandle)
    where
      mid = "some of the meta when deleting"

  checkMetaExists mid zk = RETHROW(isJust <$> Z.zooExists zk (textToCBytes (myPath @value @ZHandle mid)),ZHandle)
  getMeta         mid zk = RETHROW(decodeZNodeValue zk (myPath @value @ZHandle mid),ZHandle)
  getMetaWithVer  mid zk = RETHROW(action,ZHandle)
    where
      action = do
        e_a <- try $ Z.zooGet zk (textToCBytes $ myPath @value @ZHandle mid)
        case e_a of
          Left (_ :: ZooException) -> return Nothing
          Right a                  -> return $ (, fromIntegral . Z.statVersion . Z.dataCompletionStat $ a) <$> decodeDataCompletion a

  getAllMeta          zk = RETHROW(action,ZHandle)
    where
      mid = "some of the meta when getting "
      action = do
        let path = textToCBytes $ myRootPath @value @ZHandle
        ids <- Z.unStrVec . Z.strsCompletionValues <$> Z.zooGetChildren zk path
        idAndValues <- catMaybes <$> mapM (\x -> let x' = cBytesToText x in getMeta @value x' zk <&> fmap (x',)) ids
        pure $ Map.fromList idAndValues
  listMeta            zk = RETHROW(action,ZHandle)
    where
      mid = "some of the meta when listing"
      action = do
        let path = textToCBytes $ myRootPath @value @ZHandle
        ids <- Z.unStrVec . Z.strsCompletionValues <$> Z.zooGetChildren zk path
        catMaybes <$> mapM (flip (getMeta @value) zk . cBytesToText) ids

instance MetaMulti ZHandle where
  metaMulti ops zk = do
    let zOps = map opToZ ops
    void $ Z.zooMulti zk zOps
    where
      opToZ op = case op of
        InsertOp p k v    -> Z.zooCreateOpInit (textToCBytes $ p <> "/" <> k) (Just $ ZF.fromByteString v) 0 Z.zooOpenAclUnsafe Z.ZooPersistent
        UpdateOp p k v mv -> Z.zooSetOpInit    (textToCBytes $ p <> "/" <> k) (Just $ ZF.fromByteString v) (fromIntegral <$> mv)
        DeleteOp p k mv   -> Z.zooDeleteOpInit (textToCBytes $ p <> "/" <> k) (fromIntegral <$> mv)
        CheckOp  p k v    -> Z.zooCheckOpInit  (textToCBytes $ p <> "/" <> k) (fromIntegral v)

instance MetaStore value RHandle where
  myPath _ = myRootPath @value @RHandle
  insertMeta mid x    (RHandle m url) = RETHROW(RQ.insertInto m url (myRootPath @value @RHandle) mid x                               ,RHandle)
  updateMeta mid x mv (RHandle m url) = RETHROW(RQ.updateSet  m url (myRootPath @value @RHandle) mid x mv                            ,RHandle)
  upsertMeta mid x    (RHandle m url) = RETHROW(RQ.upsert     m url (myRootPath @value @RHandle) mid x                               ,RHandle)
  deleteMeta mid   mv (RHandle m url) = RETHROW(RQ.deleteFrom m url (myRootPath @value @RHandle) (Just mid) mv                       ,RHandle)
  deleteAllMeta       (RHandle m url) = RETHROW(RQ.deleteFrom m url (myRootPath @value @RHandle) Nothing Nothing                     ,RHandle)
    where mid = "some of the meta when deleting all"
  checkMetaExists mid (RHandle m url) = RETHROW(RQ.selectFrom @value m url (myRootPath @value @RHandle) (Just mid) <&> not . Map.null,RHandle)
  getMeta         mid (RHandle m url) = RETHROW(fmap fst <$> getMetaWithVer mid  (RHandle m url)                                     ,RHandle)
  getMetaWithVer  mid (RHandle m url) = RETHROW(RQ.selectFrom m url (myRootPath @value @RHandle) (Just mid) <&> Map.lookup mid       ,RHandle)
  getAllMeta          (RHandle m url) = RETHROW(fmap fst <$> RQ.selectFrom m url (myRootPath @value @RHandle) Nothing                ,RHandle)
    where mid = "some of the meta when get all"
  listMeta            (RHandle m url) = RETHROW(Map.elems <$> getAllMeta (RHandle m url)                                             ,RHandle)
    where mid = "some of the meta when list all"

instance MetaMulti RHandle where
  metaMulti ops (RHandle m url) = do
    let zOps = concatMap opToR ops
    -- TODO: if failing show which operation failed
    transaction m url zOps
    where
      opToR op = case op of
        InsertOp p k v    -> [InsertROp p k v]
        UpdateOp p k v mv -> let ops' = [ExistROp p k, UpdateROp p k v]
                              in maybe ops' (\version -> CheckROp p k version: ops') mv
        DeleteOp p k mv   -> let ops' = [ExistROp p k, DeleteROp p k]
                              in maybe ops' (\version -> CheckROp p k version: ops') mv
        CheckOp  p k v    -> [CheckROp p k v]

instance MetaStore value FHandle where
  myPath _   = myRootPath @value @FHandle
  insertMeta = File.insertIntoTable (myRootPath @value @FHandle)
  updateMeta = File.updateSet  (myRootPath @value @FHandle)
  upsertMeta = File.upsert     (myRootPath @value @FHandle)
  deleteMeta = File.deleteFromTable (myRootPath @value @FHandle)
  deleteAllMeta = File.deleteAllFromTable (myRootPath @value @FHandle)
  checkMetaExists mid ioH = File.selectFrom @value (myRootPath @value @FHandle) mid ioH
                        <&> not . null
  getMeta        = ((fmap fst <$>) . ) . getMetaWithVer
  getMetaWithVer = File.selectFrom (myRootPath @value @FHandle)

  getAllMeta     = (fmap fst <$>)  . File.selectAllFrom (myRootPath @value @FHandle)
  listMeta       = (Map.elems <$>) . getAllMeta

instance MetaMulti FHandle where
  metaMulti ops ioH = do
    let fileOps = map opToFile ops
    -- TODO: if failing show which operation failed
    File.runOps fileOps ioH
    where
      opToFile op = case op of
        InsertOp p k v    -> File.InsertOp p k (decodeUtf8 v)
        UpdateOp p k v mv -> File.UpdateOp p k (decodeUtf8 v) mv
        DeleteOp p k mv   -> File.DeleteOp p k mv
        CheckOp  p k v    -> File.CheckOp p k v

instance (ToJSON a, FromJSON a, HasPath a ZHandle, HasPath a RHandle, HasPath a FHandle, Show a) => HasPath a MetaHandle

#define USE_WHICH_HANDLE(handle, action) \
  case handle of ZkHandle zk -> action zk; RLHandle rq -> action rq; FileHandle io -> action io;

instance (HasPath value ZHandle, HasPath value RHandle, HasPath value FHandle) => MetaStore value MetaHandle where
  myPath = undefined
  listMeta            h = USE_WHICH_HANDLE(h, listMeta @value)
  insertMeta mid x    h = USE_WHICH_HANDLE(h, insertMeta mid x)
  updateMeta mid x mv h = USE_WHICH_HANDLE(h, updateMeta mid x mv)
  upsertMeta mid x    h = USE_WHICH_HANDLE(h, upsertMeta mid x)
  deleteMeta mid   mv h = USE_WHICH_HANDLE(h, deleteMeta @value mid mv)
  deleteAllMeta       h = USE_WHICH_HANDLE(h, deleteAllMeta @value)
  checkMetaExists mid h = USE_WHICH_HANDLE(h, checkMetaExists @value mid)
  getMeta mid         h = USE_WHICH_HANDLE(h, getMeta @value mid)
  getMetaWithVer mid  h = USE_WHICH_HANDLE(h, getMetaWithVer @value mid)
  getAllMeta          h = USE_WHICH_HANDLE(h, getAllMeta @value)

  insertMetaOp mid value    h = USE_WHICH_HANDLE(h, insertMetaOp mid value)
  updateMetaOp mid value mv h = USE_WHICH_HANDLE(h, updateMetaOp mid value mv)
  deleteMetaOp mid mv       h = USE_WHICH_HANDLE(h, deleteMetaOp @value mid mv)
  checkOp mid v             h = USE_WHICH_HANDLE(h, checkOp @value mid v)

instance MetaMulti MetaHandle where
  metaMulti ops h = USE_WHICH_HANDLE(h, metaMulti ops)
