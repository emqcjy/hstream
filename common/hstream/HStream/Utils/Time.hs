{-# LANGUAGE BangPatterns #-}

module HStream.Utils.Time
  ( Interval (..)
  , parserInterval
  , interval2ms

  , diffTimeSince
  , usecSince
  , msecSince
  , secSince

    -- * Re-export
  , getPOSIXTime
  , getCurrentMsTimestamp
  ) where

import           Control.Applicative    ((<|>))
import           Data.Attoparsec.Text   (Parser, choice, endOfInput, parseOnly,
                                         rational, string)
import           Data.Int               (Int64)
import qualified Data.Text              as T
import           Data.Time.Clock        (NominalDiffTime)
import           Data.Time.Clock.POSIX  (getPOSIXTime)

import           Data.Time.Clock.System (SystemTime (MkSystemTime),
                                         getSystemTime)
import           HStream.Base           (rmTrailingZeros)

data Interval
  = Milliseconds Double
  | Seconds Double
  | Minutes Double
  | Hours Double
  deriving (Eq)

instance Show Interval where
  show (Seconds x)      = rmTrailingZeros x <> " seconds"
  show (Minutes x)      = rmTrailingZeros x <> " minutes"
  show (Hours x)        = rmTrailingZeros x <> " hours"
  show (Milliseconds x) = rmTrailingZeros x <> " milliseconds"

interval2ms :: Interval -> Int
interval2ms (Milliseconds x) = round x
interval2ms (Seconds x)      = round (x * 1000)
interval2ms (Minutes x)      = round (x * 1000 * 60)
interval2ms (Hours x)        = round (x * 1000 * 60 * 60)

intervalParser :: Parser Interval
intervalParser = do
  x <- rational
  f <- intervalConstructorParser
  endOfInput
  return (f x)

intervalConstructorParser :: Parser (Double -> Interval)
intervalConstructorParser =
      Milliseconds <$ choice (string <$> ["ms","milliseconds","millisecond"])
  <|> Seconds <$ choice (string <$> ["seconds", "s", "second"])
  <|> Minutes <$ choice (string <$> ["minutes", "min", "minute"])
  <|> Hours   <$ choice (string <$> ["hours", "h", "hr", "hrs", "hour"])

parserInterval :: String -> Either String Interval
parserInterval = parseOnly intervalParser . T.pack

diffTimeSince :: NominalDiffTime -> IO NominalDiffTime
diffTimeSince start = do
  now <- getPOSIXTime
  return $ now - start
{-# INLINE diffTimeSince #-}

usecSince :: NominalDiffTime -> IO Int64
usecSince start = floor . (* 1e6) <$> diffTimeSince start
{-# INLINE usecSince #-}

msecSince :: NominalDiffTime -> IO Int64
msecSince start = floor . (* 1e3) <$> diffTimeSince start
{-# INLINE msecSince #-}

secSince :: NominalDiffTime -> IO Int64
secSince start = floor <$> diffTimeSince start
{-# INLINE secSince #-}

getCurrentMsTimestamp :: IO Int64
getCurrentMsTimestamp = do
  MkSystemTime sec nano <- getSystemTime
  let !ts = floor @Double $ (fromIntegral sec * 1e3) + (fromIntegral nano / 1e6)
  return ts
