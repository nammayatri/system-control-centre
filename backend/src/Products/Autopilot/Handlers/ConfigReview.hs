{-# LANGUAGE OverloadedStrings #-}

{- | HTTP handlers for the ConfigMap AI review layer.

@POST /tracker/configmap/:id/ai/review@ runs (or force re-runs) the breaking-change
review;

-}
module Products.Autopilot.Handlers.ConfigReview (
    ConfigReviewResp (..),
    reviewConfigMapH,
    getConfigReviewH,
    ackReviewH,
) where

import Core.Auth.Protected (AuthedPerson (..))
import Core.Environment (Flow)
import Data.Aeson (ToJSON (..), object, (.=))
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Products.Autopilot.ConfigReview (
    StoredReview (..),
    acknowledgeReview,
    readStoredReview,
    reviewBlocksApproval,
    runConfigReview,
 )
import Products.Autopilot.Handlers.Ai (AiActionReq (..))
import Products.Autopilot.Queries.ReleaseTracker (findReleaseTracker)
import Shared.AI.Types (aiErrorReason)

-- ─── Wire type ─────────────────────────────────────────────────────

data ConfigReviewResp = ConfigReviewResp
    { crAvailable :: Bool
    , crReason :: Maybe Text
    , crVerdict :: Maybe Text
    , crSummary :: Maybe Text
    , crModel :: Maybe Text
    , crCached :: Maybe Bool
    , crReviewedAt :: Maybe Text
    , crAckBy :: Maybe Text
    , crAckAt :: Maybe Text
    , crBlocksApproval :: Bool
    }

instance ToJSON ConfigReviewResp where
    toJSON r =
        object
            [ "available" .= crAvailable r
            , "reason" .= crReason r
            , "verdict" .= crVerdict r
            , "summary" .= crSummary r
            , "model" .= crModel r
            , "cached" .= crCached r
            , "reviewedAt" .= crReviewedAt r
            , "ackBy" .= crAckBy r
            , "ackAt" .= crAckAt r
            , "blocksApproval" .= crBlocksApproval r
            ]

-- ─── Handlers ──────────────────────────────────────────────────────

-- | Run (or force re-run) the AI config review for a ConfigMap tracker.
reviewConfigMapH :: AuthedPerson -> Text -> AiActionReq -> Flow ConfigReviewResp
reviewConfigMapH ap cmId req = do
    mt <- findReleaseTracker cmId
    case mt of
        Nothing -> pure (unavailable "ConfigMap tracker not found")
        Just (tr, _) -> do
            res <- runConfigReview (apEmail ap) tr (fromMaybe False (aiForce req))
            case res of
                Left e -> pure (unavailable (aiErrorReason e))
                Right sr -> do
                    -- Re-read so blocksApproval reflects the just-persisted verdict.
                    blocks <- maybe False (reviewBlocksApproval . fst) <$> findReleaseTracker cmId
                    pure (fromStored sr blocks)



ackReviewH :: AuthedPerson -> Text -> Flow ConfigReviewResp
ackReviewH ap rid = do
    acknowledgeReview rid (apEmail ap)
    getConfigReviewH ap rid

-- | Latest persisted verdict + reasoning for a ConfigMap tracker.
getConfigReviewH :: AuthedPerson -> Text -> Flow ConfigReviewResp
getConfigReviewH _ap cmId = do
    mt <- findReleaseTracker cmId
    case mt of
        Nothing -> pure (unavailable "ConfigMap tracker not found")
        Just (tr, _) -> do
            msr <- readStoredReview tr
            case msr of
                Nothing -> pure (unavailable "No AI review has run for this config yet")
                Just sr -> pure (fromStored sr (reviewBlocksApproval tr))

-- ─── Helpers ───────────────────────────────────────────────────────

fromStored :: StoredReview -> Bool -> ConfigReviewResp
fromStored sr blocks =
    ConfigReviewResp
        { crAvailable = True
        , crReason = Nothing
        , crVerdict = Just (srVerdict sr)
        , crSummary = srSummary sr
        , crModel = srModel sr
        , crCached = srCached sr
        , crReviewedAt = srReviewedAt sr
        , crAckBy = srAckBy sr
        , crAckAt = srAckAt sr
        , crBlocksApproval = blocks
        }

unavailable :: Text -> ConfigReviewResp
unavailable reason =
    ConfigReviewResp
        { crAvailable = False
        , crReason = Just reason
        , crVerdict = Nothing
        , crSummary = Nothing
        , crModel = Nothing
        , crCached = Nothing
        , crReviewedAt = Nothing
        , crAckBy = Nothing
        , crAckAt = Nothing
        , crBlocksApproval = False
        }
