{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

{- | Release-group read model (fleet design §5, Phase 2).

* @GET /mobile/groups?since=@ — operator-created groups with their derived
  stage summary. Active (CREATED/INPROGRESS) groups are always included;
  @since@ bounds only finished ones. Store-sync pseudo-groups are excluded by
  the query ('findMobileGroupTrackersSince').
* @GET /mobile/groups/:gid@ — full members (same enriched row shape as
  @GET /releases@), summary, approve/dispatch eligibility, per-app store
  freshness — and the store-monitor staleness kick, so the console's store
  numbers stay fresh without a poller.

A group has no stored state: everything here is derived per request from the
member rows (see 'deriveGroupSummary').
-}
module Products.Autopilot.Mobile.Handlers.Groups (
    GroupsListResp (..),
    GroupListItem (..),
    GroupMemberLite (..),
    GroupDetailResp (..),
    ChangelogSlackState (..),
    AppFreshness (..),
    listGroupsH,
    groupDetailH,
    resendGroupChangelogH,
) where

import Control.Monad (unless, void)
import Control.Monad.Catch (throwM)
import Control.Monad.IO.Class (liftIO)
import Core.AppError (APIError (..))
import Core.Auth.Protected (AuthedPerson)
import Core.Environment (Flow, forkFlow)
import Data.Aeson (Value (..))
import qualified Data.Aeson.Key as K
import qualified Data.Aeson.KeyMap as KM
import Data.Int (Int32)
import Data.List (sortOn)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe, listToMaybe, mapMaybe)
import Data.Ord (Down (..))
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time (UTCTime, addUTCTime, diffUTCTime, getCurrentTime)
import GHC.Generics (Generic)
import Products.Autopilot.Actions.Release (injectPromotable, injectStoreState)
import Products.Autopilot.Mobile.Lifecycle.GroupSummary (GroupSummary (..), MemberFact (..), deriveGroupSummary, effectivePhase)
import Products.Autopilot.Mobile.Queries.AppCatalog (listAppCatalog)
import Products.Autopilot.Mobile.Queries.StoreStatus (listStoreStatus, productionVersionsByApp, storeCellsByApp)
import Products.Autopilot.Mobile.StoreSync (refreshStoreStatusOne)
import Products.Autopilot.Mobile.Types (isDebugBuildType)
import Products.Autopilot.Mobile.Types.Storage (AppCatalog, AppCatalogT (..), StoreStatus, StoreStatusT (..))
import Products.Autopilot.Notifications (sendGroupChangelogSlackIfSettled)
import Products.Autopilot.Queries.ReleaseTracker (GroupedTracker, TrackerWithTarget, findMobileGroupTrackersSince, findReleaseTrackersByGroupId, getChangelogSlackState)
import Products.Autopilot.RuntimeConfig (getAndroidReviewRolloutFraction, getMobileBuildType, getStoreRefreshCooldownSeconds)
import Products.Autopilot.Types (ReleaseTracker (..))
import Products.Autopilot.Types.Release (ReleaseStatus (..))
import Data.Aeson (ToJSON (..), genericToJSON)
import Shared.JSON (stripPrefixOptions)

-- ─── Response types ────────────────────────────────────────────────

-- | Slim member projection for the list page (avatar stack + phase bar).
data GroupMemberLite = GroupMemberLite
    { gmlReleaseId :: Text
    , gmlApp :: Text
    , gmlSurface :: Text
    , gmlPlatform :: Text
    , gmlVersion :: Text
    , gmlVersionCode :: Maybe Int32
    , gmlPhase :: Text
    , gmlStatus :: Text
    , gmlApproved :: Bool
    , gmlRolloutPercent :: Maybe Double
    -- ^ live staged-rollout % (Android fraction / Apple day-N) when rolling
    , gmlDisplayLabel :: Maybe Text
    -- ^ the canonical badge label (e.g. \"Rolling out · 50%\") — FE chips
    -- render it verbatim so group surfaces can't drift from the row badges
    }
    deriving (Generic, Show)

instance ToJSON GroupMemberLite where
    toJSON = genericToJSON (stripPrefixOptions 3)

data GroupListItem = GroupListItem
    { gliGroupId :: Text
    , gliLabel :: Maybe Text
    , gliCreatedAt :: UTCTime
    , gliCreatedBy :: Text
    , gliSummary :: GroupSummary
    , gliMembers :: [GroupMemberLite]
    }
    deriving (Generic, Show)

instance ToJSON GroupListItem where
    toJSON = genericToJSON (stripPrefixOptions 3)

data GroupsListResp = GroupsListResp
    { glrGroups :: [GroupListItem]
    , glrSince :: UTCTime
    }
    deriving (Generic, Show)

instance ToJSON GroupsListResp where
    toJSON = genericToJSON (stripPrefixOptions 3)

-- | Age of one member app's store cache (Nothing = never synced).
data AppFreshness = AppFreshness
    { afApp :: Text
    , afSurface :: Text
    , afPlatform :: Text
    , afSyncedSecondsAgo :: Maybe Int
    }
    deriving (Generic, Show)

instance ToJSON AppFreshness where
    toJSON = genericToJSON (stripPrefixOptions 2)

data GroupDetailResp = GroupDetailResp
    { gdGroupId :: Text
    , gdLabel :: Maybe Text
    , gdCreatedAt :: UTCTime
    , gdCreatedBy :: Text
    , gdSummary :: GroupSummary
    , gdMembers :: [ReleaseTracker]
    -- ^ same enriched row shape as @GET /releases@ (promotable + store state
    -- injected), so the FE reuses its existing normalizer
    , gdEligible :: Map.Map Text [Text]
    -- ^ verb → member release ids it currently applies to (approve, dispatch)
    , gdFreshness :: [AppFreshness]
    , gdCooldownSeconds :: Int
    , gdAndroidReviewFraction :: Double
    -- ^ @android_review_rollout_fraction@ — the promote dialog prefills its
    -- Android initial-% input with this (shown as a percent).
    , gdChangelogSlack :: ChangelogSlackState
    -- ^ whether the fleet's combined changelog reached Slack (drives the
    -- "Slack failed / Resend" control on the console header).
    }
    deriving (Generic, Show)

instance ToJSON GroupDetailResp where
    toJSON = genericToJSON (stripPrefixOptions 2)

-- | Group-level changelog→Slack outcome for the console. @cssState@ is one of
-- @none@ (group didn't opt in) | @pending@ (opted in, not yet posted) | @sent@
-- | @failed@; @cssError@ carries the Slack reason when failed.
data ChangelogSlackState = ChangelogSlackState
    { cssState :: Text
    , cssError :: Maybe Text
    }
    deriving (Generic, Show)

instance ToJSON ChangelogSlackState where
    toJSON = genericToJSON (stripPrefixOptions 3)

-- | Derive the console's changelog→Slack state from the stored markers
-- (@sent_at@ / @error@) and whether any member opted in. See
-- 'getChangelogSlackState' for the (group-uniform) column semantics.
changelogSlackStateFor :: Text -> Flow ChangelogSlackState
changelogSlackStateFor gid = do
    m <- getChangelogSlackState gid
    pure $ case m of
        Just (_, _, optedIn) | not optedIn -> ChangelogSlackState "none" Nothing
        Just (Just _, _, _) -> ChangelogSlackState "sent" Nothing
        Just (Nothing, Just e, _) -> ChangelogSlackState "failed" (Just e)
        Just (Nothing, Nothing, _) -> ChangelogSlackState "pending" Nothing
        Nothing -> ChangelogSlackState "none" Nothing

-- ─── Handlers ──────────────────────────────────────────────────────

-- | Groups list. @since@ defaults to 30 days back and bounds only finished
-- groups — active ones always show (query-level guarantee).
listGroupsH :: AuthedPerson -> Maybe UTCTime -> Flow GroupsListResp
listGroupsH _ap mSince = do
    now <- liftIO getCurrentTime
    let since = fromMaybe (addUTCTime (negate (30 * 86400)) now) mSince
    rows <- findMobileGroupTrackersSince since
    enrich <- mkEnrich
    let items = map (toListItem enrich) (groupByGid rows)
    pure GroupsListResp{glrGroups = sortOn (Down . gliCreatedAt) items, glrSince = since}

-- | One group: enriched members + summary + eligibility + store freshness.
-- Kicks the same detached, cooldown-gated store refresh the monitor uses for
-- member apps whose cache is stale — the rollout numbers on the console come
-- from store_status and nothing else reconciles them.
groupDetailH :: AuthedPerson -> Text -> Flow GroupDetailResp
groupDetailH _ap gid = do
    rows <- findReleaseTrackersByGroupId gid
    (label, members0) <- case rows of
        [] -> throwM $ NotFound ("release group not found: " <> gid)
        _ -> pure (listToMaybe (mapMaybe (\(_, l, _) -> l) rows), [p | (_, _, p) <- rows])
    enrich <- mkEnrich
    let members = map enrich members0
        facts = map toFact members
        summary = deriveGroupSummary facts
        eligible =
            Map.fromList
                [ ("approve", [mfReleaseId f | f <- facts, mfStatus f == CREATED, not (mfApproved f)])
                , ("dispatch", [mfReleaseId f | f <- facts, mfStatus f == CREATED, mfApproved f])
                ]
    now <- liftIO getCurrentTime
    let createdAt = case mapMaybe dateCreated members of
            [] -> now
            ds -> minimum ds
        createdBy' = fromMaybe "" (listToMaybe (map createdBy members))
    (freshness, cooldown) <- storeFreshness members
    reviewFraction <- getAndroidReviewRolloutFraction
    slackState <- changelogSlackStateFor gid
    pure
        GroupDetailResp
            { gdGroupId = gid
            , gdLabel = label
            , gdCreatedAt = createdAt
            , gdCreatedBy = createdBy'
            , gdSummary = summary
            , gdMembers = members
            , gdEligible = eligible
            , gdFreshness = freshness
            , gdCooldownSeconds = cooldown
            , gdAndroidReviewFraction = reviewFraction
            , gdChangelogSlack = slackState
            }

-- | Manually (re)send the group's combined changelog to Slack — recovery for a
-- post that failed (e.g. a transient Slack error, or the account_inactive
-- incident). Re-runs the exact settle-time path: same gating (opted-in,
-- settled, at least one shipped), same failed-app section filtering, same
-- exactly-once CAS. So an already-sent group is a safe no-op (the claim is
-- still held) and a failed one re-wins the released claim and reposts. Returns
-- the resulting state for immediate UI feedback (synchronous ≤5s Slack call).
resendGroupChangelogH :: AuthedPerson -> Text -> Flow ChangelogSlackState
resendGroupChangelogH _ap gid = do
    rows <- findReleaseTrackersByGroupId gid
    if null rows
        then throwM $ NotFound ("release group not found: " <> gid)
        else do
            sendGroupChangelogSlackIfSettled gid Nothing
            changelogSlackStateFor gid

-- ─── Internals ─────────────────────────────────────────────────────

-- | The same enrichment @GET /releases@ applies (promotable flag + store-state
-- phase override), so group members and list rows can never disagree.
mkEnrich :: Flow (TrackerWithTarget -> ReleaseTracker)
mkEnrich = do
    prodCodes <- productionVersionsByApp
    cells <- storeCellsByApp
    pure (fst . injectStoreState cells . injectPromotable prodCodes)

-- | Stable-order grouping by group id (rows arrive creation-ordered).
groupByGid :: [GroupedTracker] -> [(Text, Maybe Text, [TrackerWithTarget])]
groupByGid rows =
    [ (gid, listToMaybe (mapMaybe (\(g, l, _) -> if g == gid then l else Nothing) rows), [p | (g, _, p) <- rows, g == gid])
    | gid <- orderedGids
    ]
  where
    orderedGids = dedup [g | (g, _, _) <- rows]
    dedup = foldr (\x acc -> if x `elem` acc then acc else x : acc) [] . reverse

toListItem :: (TrackerWithTarget -> ReleaseTracker) -> (Text, Maybe Text, [TrackerWithTarget]) -> GroupListItem
toListItem enrich (gid, label, pairs) =
    GroupListItem
        { gliGroupId = gid
        , gliLabel = label
        , gliCreatedAt = case mapMaybe dateCreated members of
            [] -> fallbackTime
            ds -> minimum ds
        , gliCreatedBy = fromMaybe "" (listToMaybe (map createdBy members))
        , gliSummary = deriveGroupSummary (map toFact members)
        , gliMembers = map toLite members
        }
  where
    members = map enrich pairs
    -- dateCreated is always Just for DB rows; epoch fallback keeps this total.
    fallbackTime = read "1970-01-01 00:00:00 UTC"

toLite :: ReleaseTracker -> GroupMemberLite
toLite t =
    GroupMemberLite
        { gmlReleaseId = releaseId t
        , gmlApp = appGroup t
        , gmlSurface = service t
        , gmlPlatform = env t
        , gmlVersion = newVersion t
        , gmlVersionCode = versionCode t
        , gmlPhase = phaseSlugOf t
        , gmlStatus = T.pack (show (status t))
        , gmlApproved = isApproved t
        , gmlRolloutPercent = ctxNumber t "rollout_percent"
        , gmlDisplayLabel = ctxText t "display_label"
        }

-- Context-key readers over the enriched release_context object.
ctxText :: ReleaseTracker -> Text -> Maybe Text
ctxText t k = case releaseContext t of
    Just (Object o) -> case KM.lookup (K.fromText k) o of
        Just (String s) -> Just s
        _ -> Nothing
    _ -> Nothing

ctxNumber :: ReleaseTracker -> Text -> Maybe Double
ctxNumber t k = case releaseContext t of
    Just (Object o) -> case KM.lookup (K.fromText k) o of
        Just (Number n) -> Just (realToFrac n)
        _ -> Nothing
    _ -> Nothing

toFact :: ReleaseTracker -> MemberFact
toFact t =
    MemberFact
        { mfReleaseId = releaseId t
        , mfApp = appGroup t
        , mfPlatform = env t
        , mfStatus = status t
        , mfApproved = isApproved t
        , mfPhase = phaseSlugOf t
        }

-- | The @display_phase@ the enrichment stamped into release_context,
-- reconciled with the tracker status ('effectivePhase'): an aborted build
-- keeps a stale non-terminal wf-phase, which must not read as "building".
phaseSlugOf :: ReleaseTracker -> Text
phaseSlugOf t = effectivePhase (status t) rawSlug
  where
    rawSlug = case releaseContext t of
        Just (Object o) -> case KM.lookup (K.fromText "display_phase") o of
            Just (String s) -> s
            _ -> "building"
        _ -> "building"

{- | Per-member-app store-cache age + the detached staleness kick (monitor
pattern: cooldown-gated, single-flight inside 'refreshStoreStatusOne', survives
this request via 'forkFlow'). Debug deployments skip both — no store data.
-}
storeFreshness :: [ReleaseTracker] -> Flow ([AppFreshness], Int)
storeFreshness members = do
    cooldown <- getStoreRefreshCooldownSeconds
    buildType <- getMobileBuildType
    if isDebugBuildType buildType
        then pure ([], cooldown)
        else do
            apps <- listAppCatalog
            statuses <- listStoreStatus
            now <- liftIO getCurrentTime
            let acByKey = Map.fromList [((acName a, acSurface a, acPlatform a), a) | a <- apps]
                -- max = OLDEST cell per app (conservative staleness)
                cellAges :: Map.Map Int32 Int
                cellAges =
                    Map.fromListWith max
                        [ (ssAppCatalogId s, round (realToFrac (diffUTCTime now (ssSyncedAt s)) :: Double))
                        | s <- statuses
                        ]
                memberKeys = dedup [(appGroup t, service t, env t) | t <- members]
                dedup = foldr (\x acc -> if x `elem` acc then acc else x : acc) []
                resolved =
                    [ ((a, s, p), ac, Map.lookup (acId ac) cellAges)
                    | (a, s, p) <- memberKeys
                    , Just ac <- [Map.lookup (a, s, p) acByKey]
                    ]
                freshness = [AppFreshness a s p age | ((a, s, p), _, age) <- resolved]
                staleApps = [ac | (_, ac, age) <- resolved, maybe True (> cooldown) age]
            unless (null staleApps) $ void (forkFlow (mapM_ refreshStoreStatusOne staleApps))
            pure (freshness, cooldown)
