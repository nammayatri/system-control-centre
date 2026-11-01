{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}

{- | Pinned apps — the per-person app list Mobile Releases v2 filters to.

GET  /mobile/me/pins → the caller's pinned app_catalog ids (pin order).
PUT  /mobile/me/pins → replace the caller's pins with the given ids.

Only ever touches the caller's own rows, so MB_RELEASE_VIEW is enough.
Unknown catalog ids are dropped silently (the catalog FK would reject them).
-}
module Products.Autopilot.Mobile.Handlers.Pins (
    Pins (..),
    getPinsH,
    putPinsH,
) where

import Control.Monad (void)
import Core.Auth.Protected (AuthedPerson (..))
import Core.DB.Connection (withConn)
import Core.Environment (Flow, withDb)
import Data.Aeson (FromJSON, ToJSON)
import Data.Int (Int32)
import Data.List (nub)
import Database.PostgreSQL.Simple (In (..), Only (..), execute, query, withTransaction)
import GHC.Generics (Generic)

newtype Pins = Pins {appCatalogIds :: [Int32]}
    deriving (Show, Generic)

instance ToJSON Pins
instance FromJSON Pins

getPinsH :: AuthedPerson -> Flow Pins
getPinsH ap = do
    rows <-
        withDb $ \db -> withConn db $ \conn ->
            query conn "SELECT app_catalog_id FROM mobile_app_pin WHERE person_id = ? ORDER BY created_at, app_catalog_id" (Only (apPersonId ap))
    pure (Pins [i | Only i <- rows])

putPinsH :: AuthedPerson -> Pins -> Flow Pins
putPinsH ap (Pins ids) = do
    withDb $ \db -> withConn db $ \conn -> withTransaction conn $ do
        void $ execute conn "DELETE FROM mobile_app_pin WHERE person_id = ?" (Only (apPersonId ap))
        case nub ids of
            [] -> pure ()
            uniq ->
                void $
                    execute
                        conn
                        "INSERT INTO mobile_app_pin (person_id, app_catalog_id) SELECT ?, id FROM app_catalog WHERE id IN ? ON CONFLICT DO NOTHING"
                        (apPersonId ap, In uniq)
    getPinsH ap
