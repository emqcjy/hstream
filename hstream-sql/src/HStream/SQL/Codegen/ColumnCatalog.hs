{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes        #-}
{-# LANGUAGE StrictData        #-}

module HStream.SQL.Codegen.ColumnCatalog where

import qualified Data.HashMap.Strict as HM
import qualified Data.List           as L
import           Data.Text           (Text)
import           HStream.SQL.AST

alwaysTrueJoinCond :: FlowObject -> FlowObject -> Bool
alwaysTrueJoinCond _ _ = True

getField :: ColumnCatalog -> FlowObject -> Maybe (ColumnCatalog, FlowValue)
getField (ColumnCatalog k stream_m) o =
  let filterCond = case stream_m of
        Nothing -> \(ColumnCatalog f _) _   -> f == k
        Just s  -> \(ColumnCatalog f s_m) _ -> f == k && s_m == stream_m
   in case HM.toList (HM.filterWithKey filterCond o) of
        []      -> Nothing
        [(k,v)] -> Just (k, v)
        xs      -> Just (L.head xs) --FIXME: ambiguous columns
{-
            _          -> throw
                          SomeRuntimeException
                          { runtimeExceptionMessage = "!!! Ambiguous field name with different <stream> and/or <extra>: " <> show xs <> ": " <> show callStack
                          , runtimeExceptionCallStack = callStack
                          }
-}

getField' :: ColumnCatalog -> FlowObject -> (ColumnCatalog, FlowValue)
getField' cata o =
  case getField cata o of
    Nothing     -> (cata, FlowNull)
    Just (k, v) -> (k, v)

streamRenamer :: Text -> FlowObject -> FlowObject
streamRenamer newName =
  HM.mapKeys (\cata@(ColumnCatalog f s_m) -> case s_m of
                 Nothing -> cata
                 Just s  -> ColumnCatalog f (Just newName)
             )
