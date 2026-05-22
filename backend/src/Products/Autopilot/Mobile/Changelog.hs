{-# LANGUAGE OverloadedStrings #-}

{- | Pure helpers for the mobile-revert flow:

* 'bumpPatch' — semver patch-bump (1.2.3 → 1.2.4) with fallbacks for
  non-conforming version strings.
* 'renderRevertChangelog' — produce a markdown changelog body for a
  revert release from the list of commits being rolled back.

Both functions are pure so they can be unit-tested without DB or HTTP.
-}
module Products.Autopilot.Mobile.Changelog (
    bumpPatch,
    renderRevertChangelog,
) where

import Data.Text (Text)
import qualified Data.Text as T
import Products.Autopilot.Mobile.Github.Compare (CommitInfo (..))
import Text.Read (readMaybe)

{- | Bump the patch component of a semver-style version string by 1.

* @"1.2.3"@   → @"1.2.4"@
* @"1.2"@     → @"1.2.1"@   (2-segment versions get a third segment)
* @"1"@       → @"1.0.1"@   (single-segment versions are zero-padded)
* @"1.2.beta"@ → @"1.2.beta.1"@  (non-numeric patch — append @.1@)
* @""@        → @"0.0.1"@   (empty input falls back to a starting point)

This is the default for revert version-name bumping. Operators can
override in the UI; the server only enforces strict-greater-than
(never equal to bad's name, never lower).
-}
bumpPatch :: Text -> Text
bumpPatch v
    | T.null v = "0.0.1"
    | otherwise = case T.splitOn "." v of
        [maj, mn, patch] -> case readMaybe (T.unpack patch) :: Maybe Int of
            Just n -> maj <> "." <> mn <> "." <> T.pack (show (n + 1))
            Nothing -> v <> ".1"
        [maj, mn] -> maj <> "." <> mn <> ".1"
        [maj] -> maj <> ".0.1"
        parts -> T.intercalate "." parts <> ".1"

{- | Render a short, single-line release-note message for a revert.

Just enough to identify the revert on the build artifact and in
Slack: a fixed label naming the bad version. Commit detail lives in
the structured cards on the SCC UI; duplicating it inside the
@change_log@ input the GH Actions workflow consumes adds noise to
notifications without adding signal.

Output shape:

> Revert v{badVer}

Unused parameters retained in the signature for API stability —
'prevVer' / 'prevSha' / 'newVer' / 'mNewCode' / commits list are
still useful to callers (e.g. logs) and removing them would churn
the handler.
-}
renderRevertChangelog ::
    -- | Bad version name (e.g. "1.2.3")
    Text ->
    -- | Previous good version name — unused (kept for API stability)
    Text ->
    -- | Previous good short SHA — unused (kept for API stability)
    Text ->
    -- | New version name for the revert — unused (kept for API stability)
    Text ->
    -- | New version code — unused (kept for API stability)
    Maybe Int ->
    -- | Commits being rolled back — unused (kept for API stability)
    [CommitInfo] ->
    Text
renderRevertChangelog badVer _prevVer _prevSha _newVer _mNewCode _commits =
    "Revert v" <> badVer
