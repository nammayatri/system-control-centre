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
    classifyAiError,
    readStoredReview,
    reviewBlocksApproval,
    reviewStatusInfo,
    runConfigReview,
 )
import Products.Autopilot.Handlers.Ai (AiActionReq (..))
import Products.Autopilot.Queries.ReleaseTracker (findReleaseTracker)

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
    , crState :: Maybe Text
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
            , "state" .= crState r
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
                Left e -> let (st, rsn) = classifyAiError e in pure (unavailableWithState st rsn)
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
                Just sr -> pure (fromStored sr (reviewBlocksApproval tr))
                Nothing -> case reviewStatusInfo tr of
                    Just (st, mReason) -> pure (unavailableWithState st (fromMaybe (defaultStateReason st) mReason))
                    Nothing -> pure (unavailableWithState "none" "No AI review has run for this config yet")

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
        , crState = Just "done"
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
        , crState = Nothing
        }

unavailableWithState :: Text -> Text -> ConfigReviewResp
unavailableWithState state reason = (unavailable reason){crState = Just state}

-- | Fallback human reason when a state marker carried none.
defaultStateReason :: Text -> Text
defaultStateReason "pending" = "AI review is in progress."
defaultStateReason "failed" = "AI review failed to run."
defaultStateReason "unavailable" = "AI review is unavailable."
defaultStateReason _ = "No AI review has run for this config yet."
