{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE NumericUnderscores #-}

{- | Type-safe time durations. Eliminates the @threadDelay 5_000_000@ class
of bugs (was that 5 seconds? 5ms? 5 microseconds?) by carrying the unit
in the type.

== Usage

@
import Core.Types.Time

-- Was:  liftIO (threadDelay 5_000_000)            -- which unit was this?
-- Now:  threadDelaySec 5                          -- obviously seconds
--   or: threadDelay (Minutes 2)                   -- obviously minutes

-- Configs become unit-explicit:
data BackoffCfg = BackoffCfg { initialDelay :: Seconds, maxDelay :: Minutes }
@
-}
module Core.Types.Time (
    -- * Newtypes
    Microseconds (..),
    Milliseconds (..),
    Seconds (..),
    Minutes (..),
    Hours (..),
    Days (..),

    -- * Conversions to micros (the canonical unit for threadDelay)
    Duration (..),

    -- * Sleep helpers
    threadDelay,
    threadDelaySec,
    threadDelayMin,
)
where

import qualified Control.Concurrent as C
import Control.Monad.IO.Class (MonadIO, liftIO)
import Data.Aeson (FromJSON, ToJSON)
import Database.PostgreSQL.Simple.FromField (FromField)
import Database.PostgreSQL.Simple.ToField (ToField)
import GHC.Generics (Generic)

newtype Microseconds = Microseconds {getMicroseconds :: Int}
    deriving stock (Show, Generic)
    deriving newtype (Eq, Ord, Num, ToJSON, FromJSON, ToField, FromField)

newtype Milliseconds = Milliseconds {getMilliseconds :: Int}
    deriving stock (Show, Generic)
    deriving newtype (Eq, Ord, Num, ToJSON, FromJSON, ToField, FromField)

newtype Seconds = Seconds {getSeconds :: Int}
    deriving stock (Show, Generic)
    deriving newtype (Eq, Ord, Num, ToJSON, FromJSON, ToField, FromField)

newtype Minutes = Minutes {getMinutes :: Int}
    deriving stock (Show, Generic)
    deriving newtype (Eq, Ord, Num, ToJSON, FromJSON, ToField, FromField)

newtype Hours = Hours {getHours :: Int}
    deriving stock (Show, Generic)
    deriving newtype (Eq, Ord, Num, ToJSON, FromJSON, ToField, FromField)

newtype Days = Days {getDays :: Int}
    deriving stock (Show, Generic)
    deriving newtype (Eq, Ord, Num, ToJSON, FromJSON, ToField, FromField)

-- | Anything that can be expressed as microseconds.
class Duration a where
    toMicros :: a -> Int

instance Duration Microseconds where toMicros (Microseconds n) = n
instance Duration Milliseconds where toMicros (Milliseconds n) = n * 1_000
instance Duration Seconds where toMicros (Seconds n) = n * 1_000_000
instance Duration Minutes where toMicros (Minutes n) = n * 60 * 1_000_000
instance Duration Hours where toMicros (Hours n) = n * 3_600 * 1_000_000
instance Duration Days where toMicros (Days n) = n * 86_400 * 1_000_000

-- | Type-safe @threadDelay@. Accepts any 'Duration'.
threadDelay :: (Duration d, MonadIO m) => d -> m ()
threadDelay d = liftIO (C.threadDelay (toMicros d))

{- | Convenience wrapper that takes a plain Int seconds value.
@threadDelaySec 5@ is equivalent to @threadDelay (Seconds 5)@.
-}
threadDelaySec :: (MonadIO m) => Int -> m ()
threadDelaySec = threadDelay . Seconds

-- | Convenience wrapper that takes a plain Int minutes value.
threadDelayMin :: (MonadIO m) => Int -> m ()
threadDelayMin = threadDelay . Minutes
