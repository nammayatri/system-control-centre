{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}

{- | Derived release-group summary — the fleet console's stage rollup.

A group has NO stored state (no table, no status column — see
docs/MOBILE_FLEET_RELEASE_DESIGN.md §2): everything here is a pure function of
the member rows' (status, is_approved, phase slug, platform), re-derived per
request. The phase slug input is the SAME @display_phase@ the badges render
('Lifecycle.Phase.phaseSlug' after store-state enrichment), so the summary can
never disagree with what the operator sees on the rows.

Stage rules are ordered and derived over NON-terminal members only; members in
terminal trouble (rejected / build_failed / aborted) surface as 'gsAttention'
banners instead of pinning the stage — those phases have no exit, so a stage
they controlled could never clear while live members still need controls.
-}
module Products.Autopilot.Mobile.Lifecycle.GroupSummary (
    MemberFact (..),
    GroupSummary (..),
    deriveGroupSummary,
    effectivePhase,
) where

import Data.Aeson (ToJSON (..), genericToJSON)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import GHC.Generics (Generic)
import Products.Autopilot.Types.Release (ReleaseStatus (..))
import Shared.JSON (stripPrefixOptions)

-- | One member's inputs, extracted from the enriched tracker row.
data MemberFact = MemberFact
    { mfReleaseId :: Text
    , mfApp :: Text
    , mfPlatform :: Text
    -- ^ android | ios
    , mfStatus :: ReleaseStatus
    , mfApproved :: Bool
    , mfPhase :: Text
    -- ^ 'phaseSlug' of the enriched row (building | internal_held | in_review
    -- | approved | rolling_out | halted | live | rejected | build_failed |
    -- superseded | aborted | distributed)
    }
    deriving (Eq, Show, Generic)

instance ToJSON MemberFact where
    toJSON = genericToJSON (stripPrefixOptions 2)

data GroupSummary = GroupSummary
    { gsStage :: Text
    -- ^ approval | dispatch | building | promote | in_review | releasing
    -- | rolling_out | done
    , gsCounts :: Map.Map Text Int
    -- ^ member count per phase slug (ALL members, terminal included)
    , gsAttention :: [MemberFact]
    -- ^ members needing eyes: rejected / build_failed / aborted / halted
    , gsPrimaryVerb :: Maybe Text
    -- ^ approve | dispatch | promote | release_or_rollout | rollout_controls
    }
    deriving (Eq, Show, Generic)

instance ToJSON GroupSummary where
    toJSON = genericToJSON (stripPrefixOptions 2)

-- | Phases with no outgoing transition (see 'validNext'). @halted@ is NOT
-- terminal — it resumes — but it does warrant attention.
terminalPhases :: [Text]
terminalPhases =
    [ "live"
    , "superseded"
    , "distributed"
    , "rejected"
    , "build_failed"
    , "aborted"
    , "user_aborted"
    , "discarded"
    ]

{- | Reconcile a derived phase slug with the tracker status. Aborting /
discarding a build flips rt_status but NOT mb_wf_status, so the derived phase
can still read @building@ — which would count the member as alive and pin the
group at "Building" forever. A terminal status with a non-terminal phase folds
to a slug that KEEPS the truth (who ended it): operator abort, system abort,
or discard. A terminal PHASE (rejected, build_failed, live…) always wins —
it carries more detail than the status.
-}
effectivePhase :: ReleaseStatus -> Text -> Text
effectivePhase st phase
    -- The generic "aborted" phase (wf MBAborted) pairs with USER_ABORTED —
    -- name the actor instead of the catch-all.
    | phase == "aborted" && st == USER_ABORTED = "user_aborted"
    | phase `elem` terminalPhases = phase
    | otherwise = case st of
        USER_ABORTED -> "user_aborted"
        -- The runner marks Actions-side build failures ABORTED without an
        -- MBFailed wf state (verified in data) — that's a FAILURE, not an abort.
        ABORTED -> "build_failed"
        GCLT_ABORTED -> "aborted"
        DISCARDED -> "discarded"
        _ -> phase

-- Discarded drafts are deliberate cleanup — counted, but not attention noise.
attentionPhases :: [Text]
attentionPhases = ["rejected", "build_failed", "aborted", "user_aborted", "halted"]

{- | Ordered, total stage derivation (design doc §6). The CREATED clauses key
on tracker status because a CREATED draft and a building row share the
@building@ phase — phases alone can't distinguish them.
-}
deriveGroupSummary :: [MemberFact] -> GroupSummary
deriveGroupSummary members =
    GroupSummary
        { gsStage = stage
        , gsCounts = Map.fromListWith (+) [(mfPhase m, 1) | m <- members]
        , gsAttention = [m | m <- members, mfPhase m `elem` attentionPhases]
        , gsPrimaryVerb = verb
        }
  where
    live = [m | m <- members, mfPhase m `notElem` terminalPhases]
    anyPhase p = any ((== p) . mfPhase) live
    -- promote outranks building: with 4 built (held) + 2 still building the
    -- operator's next action is promoting the 4 — "building" is machine-waiting.
    (stage, verb)
        | any (\m -> mfStatus m == CREATED && not (mfApproved m)) live = ("approval", Just "approve")
        | any (\m -> mfStatus m == CREATED && mfApproved m) live = ("dispatch", Just "dispatch")
        | anyPhase "internal_held" = ("promote", Just "promote")
        | any (\m -> mfStatus m /= CREATED && mfPhase m == "building") live = ("building", Nothing)
        | anyPhase "in_review" = ("in_review", Nothing)
        | anyPhase "approved" = ("releasing", Just "release_or_rollout")
        | anyPhase "rolling_out" || anyPhase "halted" = ("rolling_out", Just "rollout_controls")
        | otherwise = ("done", Nothing)
