{-# LANGUAGE LambdaCase #-}

-- | Release phase: the single canonical lifecycle value a
-- mobile row carries. A sum type, so illegal combinations (review AND rolling)
-- are unrepresentable. Everything status-bearing is a pure projection of this.
module Products.Autopilot.Mobile.Lifecycle.Phase (
    ReleasePhase (..),
    PhaseTag (..),
    phaseTag,
    validNext,
    canTransition,
    Projection (..),
    project,
    Variant (..),
    Display (..),
    displayStatus,
    displayStatusInferred,
    variantSlug,
    phaseSlug,
    pEngineStatus,
    phaseToWfStatus,
    phaseFromFields,
    isFailedTerminal,
    holdsStoreIdentity,
    promotableStage,
    abortable,
) where

import Data.Text (Text)
import qualified Data.Text as T
import Products.Autopilot.Mobile.Lifecycle.BuildKind (BuildKind (..), hasStoreIdentity)
import Products.Autopilot.Mobile.Types (MobileBuildWFStatus (..))
import Products.Autopilot.Types.Release (ReleaseStatus (..))

-- | The fraction in RollingOut/Halted is a 0–1 fraction (project multiplies by
-- 100 for the percent column). Distributed carries the non-store build kind.
data ReleasePhase
    = Building
    | BuildFailed Text
    | Distributed BuildKind -- Debug / Firebase terminal: no review/rollout, ever
    | InternalHeld -- on Play internal / iOS TestFlight, promotable
    | InReview
    | Approved -- approved, held (not released)
    | RollingOut Double
    | Halted Double
    | Live
    | Rejected Text
    | Superseded
    | Aborted
    deriving (Eq, Show)

-- | Payload-free tag for transition checks — comparing full ReleasePhase would
-- compare the Double/Text payloads and wrongly reject a legal % bump .
data PhaseTag
    = TBuilding
    | TBuildFailed
    | TDistributed
    | TInternalHeld
    | TInReview
    | TApproved
    | TRollingOut
    | THalted
    | TLive
    | TRejected
    | TSuperseded
    | TAborted
    deriving (Eq, Show)

phaseTag :: ReleasePhase -> PhaseTag
phaseTag = \case
    Building -> TBuilding
    BuildFailed _ -> TBuildFailed
    Distributed _ -> TDistributed
    InternalHeld -> TInternalHeld
    InReview -> TInReview
    Approved -> TApproved
    RollingOut _ -> TRollingOut
    Halted _ -> THalted
    Live -> TLive
    Rejected _ -> TRejected
    Superseded -> TSuperseded
    Aborted -> TAborted

-- | Legal next-tags. TRollingOut→TRollingOut is a % bump. Terminals go nowhere.
validNext :: PhaseTag -> [PhaseTag]
validNext = \case
    TBuilding -> [TInternalHeld, TDistributed, TBuildFailed, TAborted]
    TInternalHeld -> [TInReview, TSuperseded, TAborted]
    TInReview -> [TApproved, TRejected, TAborted]
    TApproved -> [TRollingOut, TLive, TSuperseded, TAborted]
    TRollingOut -> [TRollingOut, THalted, TLive, TSuperseded]
    THalted -> [TRollingOut, TLive, TSuperseded]
    _ -> []

canTransition :: ReleasePhase -> ReleasePhase -> Bool
canTransition cur next = phaseTag next `elem` validNext (phaseTag cur)

-- | The denormalised status columns, all derived here . project InReview
-- nulls rollout, project (RollingOut _) nulls review — the stale-sibling bug
-- is gone at the source.
data Projection = Projection
    { pReview :: Maybe Text -- review_status:  in_review | approved | rejected | NULL
    , pRollout :: Maybe Text -- rollout_status: rolling_out | halted | completed | superseded | NULL
    , pPercent :: Maybe Double -- rollout_percent (0–100)
    , pTrack :: Maybe Text -- store_track:    internal | production | NULL
    }
    deriving (Eq, Show)

project :: ReleasePhase -> Projection
project = \case
    InternalHeld -> Projection Nothing Nothing Nothing (Just "internal")
    InReview -> Projection (Just "in_review") Nothing Nothing (Just "production")
    Approved -> Projection (Just "approved") Nothing Nothing (Just "production")
    RollingOut p -> Projection Nothing (Just "rolling_out") (Just (p * 100)) (Just "production")
    Halted p -> Projection Nothing (Just "halted") (Just (p * 100)) (Just "production")
    Live -> Projection Nothing (Just "completed") (Just 100) (Just "production")
    Superseded -> Projection Nothing (Just "superseded") Nothing (Just "production")
    Rejected _ -> Projection (Just "rejected") Nothing Nothing (Just "production")
    _ -> Projection Nothing Nothing Nothing Nothing -- Building / BuildFailed / Distributed / Aborted

-- | Badge variant — the one set every surface renders.
data Variant = Amber | Zinc | Blue | Purple | Success | Info | Warning | Danger | Default
    deriving (Eq, Show)

data Display = Display {dLabel :: Text, dVariant :: Variant}
    deriving (Eq, Show)

{- | 'displayStatus' with the Android inference softening: a verdict INFERRED from
the Play track (Google exposes no review state) reads "Pending review", not a
confident "In review". Only InReview softens — approved/rejected are
operator-recorded verdicts even on inferred rows.
-}
displayStatusInferred :: Bool -> ReleasePhase -> Display
displayStatusInferred True InReview = Display "Pending review" Purple
displayStatusInferred _ ph = displayStatus ph

-- | The single status deriver used by list, detail, and monitor.
displayStatus :: ReleasePhase -> Display
displayStatus = \case
    Distributed FirebaseInternal -> Display "Firebase internal" Amber
    Distributed Debug -> Display "Debug build" Zinc
    Distributed StoreBound -> Display "Distributed" Zinc -- unreachable, kept total
    InternalHeld -> Display "Ready to promote" Blue
    InReview -> Display "In review" Purple
    Approved -> Display "Approved · held" Success
    RollingOut p -> Display ("Rolling out " <> pctText p) Info
    Halted p -> Display ("Halted · " <> pctText p) Warning
    Live -> Display "Released · 100%" Success
    Rejected _ -> Display "Rejected" Danger
    Superseded -> Display "Superseded" Default
    BuildFailed _ -> Display "Build failed" Danger
    Aborted -> Display "Aborted" Danger
    Building -> Display "Building" Default

-- | A 0–1 fraction as a percent, trimmed to 1 decimal (0.01 → "1", 0.125 → "12.5").
pctText :: Double -> Text
pctText p =
    let n = fromIntegral (round (p * 1000) :: Int) / 10 :: Double
     in T.pack (if n == fromIntegral (round n :: Int) then show (round n :: Int) else show n) <> "%"

-- | Machine phase tag for the frontend — lets it branch on the phase (e.g.
-- cross-row promote suppression) without string-matching the display label.
phaseSlug :: ReleasePhase -> Text
phaseSlug = \case
    Building -> "building"
    BuildFailed _ -> "build_failed"
    Distributed _ -> "distributed"
    InternalHeld -> "internal_held"
    InReview -> "in_review"
    Approved -> "approved"
    RollingOut _ -> "rolling_out"
    Halted _ -> "halted"
    Live -> "live"
    Rejected _ -> "rejected"
    Superseded -> "superseded"
    Aborted -> "aborted"

-- | Badge-variant slug the frontend renders (matches its BadgeVariant union).
-- Amber/Zinc fold onto warning/default (the FE has no amber/zinc).
variantSlug :: Variant -> Text
variantSlug = \case
    Amber -> "warning"
    Zinc -> "default"
    Blue -> "blue"
    Purple -> "purple"
    Success -> "success"
    Info -> "info"
    Warning -> "warning"
    Danger -> "danger"
    Default -> "default"

-- | The generic engine status (rt_status) projected from the phase, so
-- it can never disagree with the lifecycle.
pEngineStatus :: ReleasePhase -> ReleaseStatus
pEngineStatus = \case
    Building -> INPROGRESS
    InternalHeld -> INPROGRESS
    InReview -> INPROGRESS
    Approved -> INPROGRESS
    RollingOut _ -> INPROGRESS
    Halted _ -> INPROGRESS
    Live -> COMPLETED
    Superseded -> COMPLETED
    Rejected _ -> ABORTED
    Aborted -> USER_ABORTED
    BuildFailed _ -> ABORTED
    Distributed _ -> COMPLETED

-- | A failed terminal never shipped → it releases its version-code slot.
isFailedTerminal :: ReleasePhase -> Bool
isFailedTerminal = \case
    Aborted -> True
    BuildFailed _ -> True
    _ -> False

-- | Whether this row holds the version-code identity slot now: eligible
-- by kind AND not a failed terminal.
holdsStoreIdentity :: BuildKind -> ReleasePhase -> Bool
holdsStoreIdentity kind phase = hasStoreIdentity kind && not (isFailedTerminal phase)

-- | Promotable stage: held on internal, nothing started yet. The full
-- "can promote" also needs the build to be ahead of production.
promotableStage :: ReleasePhase -> Bool
promotableStage = \case
    InternalHeld -> True
    _ -> False

-- | Whether Abort still applies. Only a build with no store/distributable artifact
-- yet (still Building) can be cancelled. Once it's on a store track — or terminal
-- (rejected / superseded / live / failed) — Abort can't un-ship it (it re-surfaces
-- via store-sync), so the UI must not offer it. The BE truth for the FE's Abort gate.
abortable :: ReleasePhase -> Bool
abortable = \case
    Building -> True
    _ -> False

-- | The mb_wf_status mirror for a phase. Just = setPhase writes it into the
-- target-state JSON. Nothing = leave wf-status as the build pipeline set it
-- (Building / InternalHeld / Superseded keep theirs).
phaseToWfStatus :: ReleasePhase -> Maybe MobileBuildWFStatus
phaseToWfStatus = \case
    InReview -> Just MBInReview
    Approved -> Just MBReviewApproved
    Rejected _ -> Just MBReviewRejected
    RollingOut _ -> Just MBRollingOut
    Halted _ -> Just MBRollingOut -- halted = mid-rollout, resumable (no MBHalted status)
    Live -> Just MBCompleted
    Aborted -> Just MBAborted
    -- Terminalize WITHOUT COMPLETED so Finalize gives USER_ABORTED, not COMPLETED →
    -- markReleaseRevertedBy stays unfired. "Superseded" display comes from rollout_status.
    Superseded -> Just MBAborted
    _ -> Nothing -- InternalHeld/Building/BuildFailed/Distributed: column-only or pipeline-owned

-- | Reconstruct the phase from a row's columns — the inverse of project, used to
-- read current phase. Rollout wins over review. Reject reason isn't a
-- column, so it comes back "" (the guard compares tags only).
phaseFromFields ::
    BuildKind ->
    MobileBuildWFStatus ->
    Maybe Text -> -- review_status
    Maybe Text -> -- rollout_status
    Maybe Double -> -- rollout_percent (0–100)
    Maybe Text -> -- store_track
    ReleasePhase
phaseFromFields kind wf review rollout pct track =
    case rollout of
        Just "rolling_out" -> RollingOut (fromPct pct)
        Just "halted" -> Halted (fromPct pct)
        Just "completed" -> Live
        Just "superseded" -> Superseded
        _ -> case review of
            Just "approved" -> Approved
            Just "rejected" -> Rejected ""
            Just "in_review" -> InReview
            Just "submitted" -> InReview
            _ -> case wf of
                MBAborted -> Aborted
                MBFailed e -> BuildFailed e
                _
                    -- debug/firebase: a terminal non-store build is Distributed; still building → Building
                    | not (hasStoreIdentity kind) -> if wf `elem` [MBCompleted, MBTagPushed] then Distributed kind else Building
                    -- Review states need no wf fallback here: setPhase writes the
                    -- review column and the wf mirror together, and every caller
                    -- passes the ROW's review (§16) — already handled above.
                    | wf == MBTagPushed -> InternalHeld -- built, held, awaiting promote
                    | track `elem` [Just "internal", Just "testflight"] -> InternalHeld
                    | wf == MBCompleted -> Live
                    | otherwise -> Building
  where
    fromPct = maybe 0 (/ 100)
