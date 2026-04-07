{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE OverloadedStrings #-}

{- | Phantom-typed identifiers — prevents mixing IDs of different domains
at compile time.

== Usage

@
import Core.Types.Id
import qualified Products.Autopilot.Types.Release as Release
import qualified Core.Auth.Types as Auth

-- Type aliases per domain (defined where the entity lives):
type ReleaseId = Id Release.ReleaseTracker
type PersonId  = Id Auth.Person

-- Now you cannot pass a PersonId where a ReleaseId is expected:
findReleaseTracker :: DBEnv -> ReleaseId -> IO (Maybe ReleaseTracker)
@

A new typed ID can be added in 0 lines — it is just an empty newtype tag
on top of the underlying 'Text'. JSON / SQL / HTTP path-capture wire
formats are unchanged, so this is a zero-cost migration from
@releaseId :: Text@ to @releaseId :: Id ReleaseTracker@.
-}
module Core.Types.Id (
    Id (..),
    cast,
    generateGUID,
    shortGUID,
)
where

import Control.Monad.IO.Class (MonadIO, liftIO)
import Data.Aeson (FromJSON, ToJSON)
import Data.String (IsString)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.UUID as UUID
import qualified Data.UUID.V4 as UUID4
import Database.PostgreSQL.Simple.FromField (FromField)
import Database.PostgreSQL.Simple.ToField (ToField)
import GHC.Generics (Generic)
import Servant (FromHttpApiData, ToHttpApiData)

{- | Phantom-typed identifier. The @a@ parameter is purely a marker
— at runtime it is just 'Text'.
-}
newtype Id a = Id {getId :: Text}
    deriving stock (Show, Generic)
    deriving newtype
        ( Eq
        , Ord
        , IsString
        , ToJSON
        , FromJSON
        , ToHttpApiData
        , FromHttpApiData
        , ToField
        , FromField
        )

{- | Re-tag an Id between phantom types. Use sparingly — only at the
boundary where an external system hands you back an Id of an
intermediate type (e.g. a JOIN result).
-}
cast :: Id a -> Id b
cast (Id t) = Id t

-- | Generate a fresh UUIDv4-based 'Id'.
generateGUID :: (MonadIO m) => m (Id a)
generateGUID = liftIO $ Id . UUID.toText <$> UUID4.nextRandom

{- | Like 'generateGUID' but returns the first 8 hex chars only.
Useful for short request-correlation tags in logs.
-}
shortGUID :: (MonadIO m) => m (Id a)
shortGUID = do
    Id full <- generateGUID
    pure (Id (T.take 8 full))
