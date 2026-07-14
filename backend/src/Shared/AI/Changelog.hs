{-# LANGUAGE OverloadedStrings #-}

{- | Commit grouping, surface filtering, and digesting for the release changelog.

The long summary is built deterministically here (no AI, the commits are never
sent to a model) — so it is instant, complete, and never truncates. The AI is
used only for a short synopsis, and even then it receives a compact category
DIGEST ('shortSynopsisInput'), not the raw commits, so the call is fast.

'filterCommitsForSurface' scopes the changelog to the app being released: a
consumer (customer) app drops @provider:@/@driver:@ commits, a provider (driver)
app drops @consumer:@/@customer:@ commits; un-prefixed (shared) commits stay.
-}
module Shared.AI.Changelog (
    CommitItem (..),
    dropAutomationCommits,
    isAutomationCommit,
    filterCommitsForSurface,
    otherSideLabel,
    ownSideLabel,
    groupByCategory,
    chunksOf,
    renderChunkForAi,
    renderChunkDeterministic,
    renderLongSummary,
    renderShortSummary,
    shortSynopsisInput,
) where

import Data.Char (isAlpha)
import Data.List (sortOn)
import Data.Text (Text)
import qualified Data.Text as T

-- | One commit to summarise. (Distinct field prefix @cg@ to avoid clashing with
-- the mobile handler's @CommitInfo@ \/ @ci*@ fields.)
data CommitItem = CommitItem
    { cgSha :: Text
    , cgSubject :: Text
    , cgAuthor :: Text
    }

-- ─── Automation filtering ───────────────────────────────────────────────────

{- | Automation noise a changelog should not carry: commits AUTHORED by bots
(@…[bot]@ logins, github-actions, dependabot) and pure release PLUMBING —
version-bump \/ skip-ci commits that CI pushes under a human token. The message
patterns are deliberately narrow (prefix-anchored) so a real change mentioning
"bump" is never dropped.
-}
isAutomationCommit :: Text -> Text -> Bool
isAutomationCommit author subject = botAuthor || plumbingSubject
  where
    la = T.toLower (T.strip author)
    ls = T.toLower (T.strip subject)
    botAuthor =
        "[bot]" `T.isSuffixOf` la
            || la `elem` ["github-actions", "github actions", "actions-user", "dependabot", "renovate"]
    plumbingSubject =
        "[skip ci]" `T.isInfixOf` ls
            || any
                (`T.isPrefixOf` ls)
                [ "chore(release)"
                , "chore: bump version"
                , "chore: release"
                , "bump version"
                , "bump versioncode"
                , "bump build number"
                , "release: bump version"
                ]

-- | 'isAutomationCommit' over a commit list — the one filter the default
-- (deterministic) changelog and the AI input both go through.
dropAutomationCommits :: [CommitItem] -> [CommitItem]
dropAutomationCommits = filter (\c -> not (isAutomationCommit (cgAuthor c) (cgSubject c)))

-- ─── Surface (consumer / provider) filtering ────────────────────────────────

data Side = Consumer | Provider | Shared
    deriving (Eq)

{- | Which side a commit belongs to, from a leading @consumer:@/@provider:@
(monorepo convention), also seeing through a @Revert "provider: …"@ wrapper.
Un-prefixed commits are 'Shared' (kept for both apps).
-}
commitSide :: Text -> Side
commitSide subj =
    let s0 = T.toLower (T.strip subj)
        s = case T.stripPrefix "revert \"" s0 of
            Just r -> r
            Nothing -> s0
        tok = T.takeWhile (\c -> c /= ':' && c /= ' ' && c /= '(') s
     in if tok `elem` ["provider", "driver"]
            then Provider
            else
                if tok `elem` ["consumer", "customer", "rider"]
                    then Consumer
                    else Shared

-- | The side of the app being released, from its @surface@.
surfaceSide :: Text -> Side
surfaceSide s = case T.toLower (T.strip s) of
    x
        | x `elem` ["driver", "provider", "partner"] -> Provider
        | x `elem` ["customer", "consumer", "rider", "user"] -> Consumer
        | otherwise -> Shared

{- | The label of the side EXCLUDED for a given app surface: a consumer app
excludes "provider" commits, a provider app excludes "consumer". Used to name the
exclusion in the summary instead of a vague "other-surface".
-}
otherSideLabel :: Text -> Text
otherSideLabel surface = case surfaceSide surface of
    Consumer -> "provider"
    Provider -> "consumer"
    Shared -> "other-surface"

-- | The app's OWN side label (for the summary header): a customer app is
-- "consumer", a driver app is "provider"; otherwise the surface as-is.
ownSideLabel :: Text -> Text
ownSideLabel surface = case surfaceSide surface of
    Consumer -> "consumer"
    Provider -> "provider"
    Shared -> T.toLower (T.strip surface)

{- | Keep only commits relevant to the selected app's surface: drop the OTHER
side's commits; keep this side's + shared. Unknown surface ⇒ keep everything.
-}
filterCommitsForSurface :: Text -> [CommitItem] -> [CommitItem]
filterCommitsForSurface surface = filter keep
  where
    side = surfaceSide surface
    keep ci = case (side, commitSide (cgSubject ci)) of
        (Consumer, Provider) -> False
        (Provider, Consumer) -> False
        _ -> True

-- ─── Category grouping ──────────────────────────────────────────────────────

-- | A display bucket with a stable sort order.
data Category = Category {catLabel :: Text, catOrder :: Int}
    deriving (Eq)

-- | Map a conventional-commit type to a category. Unknown/absent → "Other".
classify :: Text -> Category
classify subj = case conventionalType subj of
    Just t
        | t `elem` ["feat", "feature"] -> Category "✨ Features" 1
        | t `elem` ["fix", "bugfix", "hotfix"] -> Category "🐛 Bug Fixes" 2
        | t == "perf" -> Category "⚡ Performance" 3
        | t == "refactor" -> Category "♻️ Refactors" 4
        | t == "revert" -> Category "⏪ Reverts" 5
        | t == "docs" -> Category "📝 Docs" 6
        | t `elem` ["test", "tests"] -> Category "✅ Tests" 7
        | t `elem` ["chore", "build", "ci", "deps", "style"] -> Category "🧹 Chores / CI" 8
    _ -> Category "📦 Other Changes" 9

{- | Extract a conventional-commit type: the leading alpha word before the first
@:@, ignoring an optional @(scope)@ and @!@. e.g. @"feat(ui)!: x"@ → @"feat"@;
@"update readme"@ (no colon) → Nothing → "Other".
-}
conventionalType :: Text -> Maybe Text
conventionalType s =
    let (before, rest) = T.breakOn ":" (T.strip s)
        typ = T.toLower (T.takeWhile isAlpha before)
     in if not (T.null rest) && not (T.null typ) && T.length before <= 24
            then Just typ
            else Nothing

-- | Commits grouped by category (categories in display order, commits in input order).
groupByCategory :: [CommitItem] -> [(Text, [CommitItem])]
groupByCategory cs =
    [ (catLabel c, items)
    | c <- ordered
    , let items = filter ((== c) . classify . cgSubject) cs
    , not (null items)
    ]
  where
    ordered = sortOn catOrder (dedup (map (classify . cgSubject) cs))
    dedup = foldr (\x acc -> if x `elem` acc then acc else x : acc) []

-- | Split a list into bounded chunks (n >= 1).
chunksOf :: Int -> [a] -> [[a]]
chunksOf n xs
    | n <= 0 = [xs]
    | null xs = []
    | otherwise = let (h, t) = splitAt n xs in h : chunksOf n t

-- | AI input for one chunk: sha + subject + author, one per line.
renderChunkForAi :: [CommitItem] -> Text
renderChunkForAi cs =
    T.unlines ["- " <> cgSha c <> " " <> cgSubject c <> " (" <> cgAuthor c <> ")" | c <- cs]

-- | Deterministic bullets for a chunk.
renderChunkDeterministic :: [CommitItem] -> Text
renderChunkDeterministic cs =
    T.intercalate "\n" ["- " <> cgSubject c <> "  — " <> cgAuthor c | c <- cs]

{- | The long summary: every commit, grouped by type, with author. Deterministic
(no AI) — always complete, instant.
-}
renderLongSummary :: [CommitItem] -> Text
renderLongSummary [] = "_No commits since the last release._"
renderLongSummary cs =
    T.intercalate "\n\n" $
        map
            (\(label, items) -> "## " <> label <> "\n" <> renderChunkDeterministic items)
            (groupByCategory cs)

{- | Deterministic one-line synopsis (counts by category) for the @summary_short@
slot when AI is off or every model fails — the instant floor. GENERIC (no app name,
no totals) so it can also serve as store release notes; caps to the top categories so
it stays one line.
-}
renderShortSummary :: [CommitItem] -> Text
renderShortSummary [] = ""
renderShortSummary cs =
    let plainLabel = T.toLower . T.unwords . drop 1 . T.words -- "✨ Features" → "features"
        phrase label items =
            let l = plainLabel label
                word
                    | "feature" `T.isInfixOf` l = "new features"
                    | "fix" `T.isInfixOf` l = "fixes"
                    | "performance" `T.isInfixOf` l = "performance improvements"
                    | otherwise = l
             in T.pack (show (length items)) <> " " <> word
        parts = [phrase label items | (label, items) <- groupByCategory cs, not (null items)]
     in case take 3 parts of
            [] -> "Maintenance and internal changes."
            ps -> T.intercalate ", " ps <> "."

{- | Compact category DIGEST for the short AI synopsis — per category, the count
plus the first few subjects (not the raw commits). Small input ⇒ fast call.
-}
shortSynopsisInput :: [CommitItem] -> Text
shortSynopsisInput cs =
    T.intercalate "\n" $
        map
            ( \(label, items) ->
                label
                    <> " ("
                    <> T.pack (show (length items))
                    <> "): "
                    <> T.intercalate "; " (map cgSubject (take 3 items))
                    <> (if length items > 3 then " …" else "")
            )
            (groupByCategory cs)
