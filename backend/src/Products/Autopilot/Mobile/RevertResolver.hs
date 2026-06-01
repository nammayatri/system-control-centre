{-# LANGUAGE OverloadedStrings #-}

{- | Pure resolution of a mobile /rollback/ target.

Revert is really two operations (see "Products.Autopilot.Mobile.Handlers.Revert"):

  * a __rollback__ — an SCC release is bad, so we go back to the previous
    /lower/ good version; and
  * a store-drift __re-assert__ — the store shows an unexpected version, so
    we re-push our /latest/ intended SCC build (handled separately and
    unchanged).

This module owns the rollback side and fixes a subtle correctness bug. The
previous implementation ordered candidates by @created_at@, but store-sync
writes rows for /older/ versions at /later/ times (it records whatever the
store currently shows whenever the poller runs). So creation time is __not__
the release sequence — using it picks the wrong target, or none at all.

We instead order by the key the store itself enforces:

@
  (Android version_code, semver(version_name), created_at)
@

@version_code@ is store-enforced monotonic on Android, so it is
authoritative; @semver(version_name)@ covers iOS (no code) and breaks code
ties; @created_at@ only separates genuine re-releases of one version.

Resolution is split __target vs source__ because the version users were on
may have no SCC build artifact (e.g. a store-synced version SCC never built):
'rpTarget' is the version to /display/, 'rpSource' the tag\/commit to
/rebuild from/. When they differ, the operator confirms the choice rather
than the backend guessing.

The module is intentionally decoupled from Beam\/JSON so it is pure and
unit-testable; callers build 'RevertCand' values from rows.
-}
module Products.Autopilot.Mobile.RevertResolver (
    RevertCand (..),
    SeqKey (..),
    RollbackPlan (..),
    parseSemver,
    seqKey,
    compareSeq,
    resolveRollback,
) where

import Data.Char (isDigit)
import Data.Int (Int32)
import Data.List (sortBy)
import Data.Maybe (fromMaybe, mapMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Clock (UTCTime)
import Text.Read (readMaybe)

{- | A candidate release for rollback resolution. Built from a
@release_tracker@ row plus its parsed mobile state, but kept free of
Beam\/JSON so the resolver stays pure.
-}
data RevertCand = RevertCand
    { rcId :: Text
    , rcVersionName :: Text
    -- ^ @new_version@, e.g. @"3.3.17"@.
    , rcVersionCode :: Maybe Int32
    -- ^ Android store-enforced version code; 'Nothing' on iOS.
    , rcTag :: Maybe Text
    -- ^ @mbcTagPushed@. Buildable iff present and non-empty.
    , rcCommitSha :: Maybe Text
    -- ^ @commit_sha@, for display only.
    , rcCreatedAt :: UTCTime
    }
    deriving (Eq, Show)

-- | Ordering key matching how the store ranks releases. See module header.
data SeqKey = SeqKey
    { skCode :: Maybe Int32
    , skSemver :: [Int]
    , skCreatedAt :: UTCTime
    }
    deriving (Eq, Show)

{- | Parse a version name into a list of integer components:
@"3.3.17"@ becomes @[3,3,17]@. Tolerant — any non-numeric junk maps to
@0@, so a malformed version sorts low and never throws. Integer (not
lexical) comparison is what makes @3.3.9 < 3.3.10@ hold.
-}
parseSemver :: Text -> [Int]
parseSemver =
    map (fromMaybe 0 . readMaybe . T.unpack)
        . filter (not . T.null)
        . T.splitOn "."
        . T.filter (\c -> isDigit c || c == '.')

seqKey :: RevertCand -> SeqKey
seqKey c = SeqKey (rcVersionCode c) (parseSemver (rcVersionName c)) (rcCreatedAt c)

{- | Total order matching store ranking. @version_code@ dominates (on
Android every row carries one); @semver@ breaks code ties and covers iOS;
@created_at@ is the final tiebreaker.

Note: for 'Maybe' 'Int32', 'Nothing' '<' 'Just', which is irrelevant
within a single platform (all rows agree on presence).
-}
compareSeq :: SeqKey -> SeqKey -> Ordering
compareSeq a b =
    compare (skCode a) (skCode b)
        <> compare (skSemver a) (skSemver b)
        <> compare (skCreatedAt a) (skCreatedAt b)

{- | The outcome of resolving a rollback. The first field of the
artifact-bearing constructors is always the /target/ (version to display),
the second the /source/ (tag\/commit to rebuild from).
-}
data RollbackPlan
    = -- | Target has a usable tag; source == target. The clean case.
      Rollback RevertCand RevertCand
    | -- | Target (the version users were on) has no build artifact, but a
      -- lower version does. Operator confirms rebuilding from the lower
      -- source rather than the backend silently shipping older code.
      RebuildLower RevertCand RevertCand
    | -- | Target has no artifact and nothing buildable sits below it.
      -- Operator must supply a source commit to rebuild from.
      NeedsManualSource RevertCand
    | -- | @bad@ is the lowest known version; there is nothing to roll back to.
      NoPriorRelease
    deriving (Eq, Show)

{- | Resolve the rollback for @bad@ given all eligible candidates.

Candidates must already be filtered to COMPLETED, non-debug, non-reverted
rows for the same @(app_group, service, env)@, excluding @bad@ itself.
Crucially, __store-sync rows are included__: they record real versions
users were on, so they are valid rollback /targets/ (even when they carry
no SCC artifact of their own).

Pure; ordering is by 'seqKey', never by creation time.
-}
resolveRollback :: RevertCand -> [RevertCand] -> RollbackPlan
resolveRollback bad cands =
    case ordered of
        [] -> NoPriorRelease
        (tgt : _)
            | hasTag tgt -> Rollback tgt tgt
            | otherwise ->
                case mapMaybe keepTagged ordered of
                    (src : _) -> RebuildLower tgt src
                    [] -> NeedsManualSource tgt
  where
    below = filter (\c -> compareSeq (seqKey c) (seqKey bad) == LT) cands
    -- Highest version first.
    ordered = sortBy (\x y -> compareSeq (seqKey y) (seqKey x)) below
    hasTag c = maybe False (not . T.null) (rcTag c)
    keepTagged c = if hasTag c then Just c else Nothing
