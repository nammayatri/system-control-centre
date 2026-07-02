{-# LANGUAGE OverloadedStrings #-}

{- | Release changelog generation by CHUNKED map-reduce.

The surface-filtered commits are split into small slices (~40), each sent to the
model with 'chunkCategorizeSystem'; the model returns one @CATEGORY|summary@ line
per commit. The lines from every chunk are grouped, in code, into the final
categorized changelog (header, top changes, the notable categories, an Internal
section listing the rest, and a reconciliation line) — so EVERY commit is present.

Why chunk: with thinking disabled (see 'Shared.AI.Provider') glm-flash is clean and
fast on a bounded slice (~8s for 40 commits), but a single 200+-commit call runs
away into repetition (measured: 120k+ chars and climbing). Bounding the slice keeps
each call coherent; assembly in code keeps the whole reliable. A chunk whose AI call
fails (after a retry) falls back to a code categorization of its commits, so the
commit still appears. The call is audited.
-}
module Shared.AI.ReleaseSummary (generateReleaseSummaries, generateWithFallback) where

import Control.Monad.IO.Class (liftIO)
import Core.Environment (MonadFlow)
import Data.Int (Int32)
import Data.Maybe (mapMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Clock (diffUTCTime, getCurrentTime)
import Shared.AI.Changelog (CommitItem (..))
import Shared.AI.Prompts (chunkCategorizeSystem, fence, synopsisSystem)
import Shared.AI.Provider (complete)
import Shared.AI.Queries (computePromptHash, insertAiAuditLog)
import Shared.AI.Types

-- | Commits per AI call. Small enough that glm-flash stays coherent (a single
-- 200+-commit call runs away into repetition); large enough to keep the call count
-- low. ~40 lands each chunk at ~8s.
chunkSize :: Int
chunkSize = 40

-- | Changelog categories, in render order with their Slack-mrkdwn headers.
data Cat = CFeature | CFix | CPerf | CBreaking | CAttention | CInternal
    deriving (Eq)

cats :: [(Cat, Text)]
cats =
    [ (CFeature, "✨ Features")
    , (CFix, "🐛 Fixes")
    , (CPerf, "⚡ Performance")
    , (CBreaking, "⚠️ Breaking Changes")
    , (CAttention, "🔍 Needs attention")
    , (CInternal, "🔧 Internal")
    ]

isNotable :: Cat -> Bool
isNotable CInternal = False
isNotable _ = True

-- | Parse the model's CATEGORY token (lenient).
parseCat :: Text -> Maybe Cat
parseCat t = case T.toUpper (T.strip t) of
    "FEATURE" -> Just CFeature
    "FEATURES" -> Just CFeature
    "FEAT" -> Just CFeature
    "FIX" -> Just CFix
    "FIXES" -> Just CFix
    "BUG" -> Just CFix
    "PERF" -> Just CPerf
    "PERFORMANCE" -> Just CPerf
    "BREAKING" -> Just CBreaking
    "ATTENTION" -> Just CAttention
    "INTERNAL" -> Just CInternal
    _ -> Nothing

-- | Code categorization of a commit by conventional-commit prefix / keywords.
-- Used as the per-chunk fallback when an AI call fails, so no commit is dropped.
catOf :: CommitItem -> Cat
catOf c =
    let s = T.toLower (cgSubject c)
        pfx ps = any (`T.isPrefixOf` s) ps
        inf ps = any (`T.isInfixOf` s) ps
     in if inf ["auth", "payment", "permission", "migrat"]
            then CAttention
            else
                if inf ["breaking", "!:"]
                    then CBreaking
                    else
                        if pfx ["feat", "add"]
                            then CFeature
                            else
                                if pfx ["perf"]
                                    then CPerf
                                    else
                                        if pfx ["fix", "bug", "hotfix"]
                                            then CFix
                                            else
                                                if pfx ["chore", "ci", "build", "test", "doc", "style", "refactor", "bump", "merge", "deps", "revert"]
                                                    then CInternal
                                                    else CFix

-- | Parse one chunk response into @(category, summary)@ pairs. Tolerant of leading
-- bullet/asterisk noise; an unrecognised category defaults to a notable Fix.
parseChunk :: Text -> [(Cat, Text)]
parseChunk = mapMaybe parseLine . T.lines
  where
    parseLine raw =
        let l = T.strip (T.dropWhile (\ch -> ch == '-' || ch == '•' || ch == '*' || ch == ' ') raw)
            (catTxt, rest) = T.breakOn "|" l
         in if T.null rest
                then Nothing
                else
                    let s = T.strip (T.drop 1 rest)
                     in if T.null s then Nothing else Just (maybe CFix id (parseCat catTxt), s)

chunksOf :: Int -> [a] -> [[a]]
chunksOf _ [] = []
chunksOf n xs = let (h, t) = splitAt n xs in h : chunksOf n t

-- | Generate one chunk's categorized lines: AI (one retry), else code fallback so
-- every commit in the slice still appears.
genChunk :: (MonadFlow m) => Text -> AiConfig -> [CommitItem] -> m [(Cat, Text)]
genChunk createdBy cfg batch = go (2 :: Int)
  where
    commitLines = T.unlines (map (\c -> "- " <> cgSubject c <> " (" <> cgAuthor c <> ")") batch)
    userMsg = fence "context" commitLines
    fallback = map (\c -> (catOf c, T.strip (cgSubject c) <> " — " <> cgAuthor c)) batch
    -- Accept the AI output only if it is EXACTLY one line per commit — that is what
    -- keeps the final reconciliation exact (notable + internal = in-app total). On a
    -- mismatch, retry; if it still won't, fall back to a code categorization of the
    -- slice (also exactly one line per commit), so the count is right either way.
    go n = do
        e <- aiComplete createdBy cfg "release_notes_chunk" chunkCategorizeSystem userMsg
        case e of
            Right t | let ls = parseChunk t, length ls == length batch -> pure ls
            _ | n > 1 -> go (n - 1)
            _ -> pure fallback

{- | @(long changelog, short)@. Chunks the commits, categorizes each slice, assembles
the full every-commit changelog, then derives a 1–2 line synopsis for @summary_short@
(see 'genShort'). 'Nothing' only when there are no commits.
-}
generateReleaseSummaries :: (MonadFlow m) => Text -> AiConfig -> Text -> Text -> Int -> Text -> [CommitItem] -> m (Maybe (Text, Text))
generateReleaseSummaries createdBy cfg appLabel version excluded excludedSide commits = do
    grouped <- concat <$> mapM (genChunk createdBy cfg) (chunksOf chunkSize commits)
    if null grouped
        then pure Nothing
        else do
            short <- genShort createdBy cfg grouped
            pure $ Just (renderChangelog appLabel version (length commits) excluded excludedSide grouped, short)

{- | A 1–2 sentence synopsis for the @summary_short@ slot. One small, fast AI call
('synopsisSystem') over only the NOTABLE changes — a bounded input, so it stays quick
even on a 200-commit release — with a deterministic counts fallback so the field is
never empty when there are commits. Thinking is already disabled in 'Shared.AI.Provider'.
-}
genShort :: (MonadFlow m) => Text -> AiConfig -> [(Cat, Text)] -> m Text
genShort createdBy cfg grouped = do
    e <- aiComplete createdBy cfg "release_notes_short" synopsisSystem userMsg
    pure $ case e of
        Right t -> let s = cleanShort t in if T.null s then fallback else s
        Left _ -> fallback
  where
    notable = [s | (c, s) <- grouped, isNotable c]
    -- Headline changes are enough for a synopsis; cap the slice so a huge release
    -- still makes one quick call. Fall back to the raw lines if nothing is notable.
    -- Drop the "— author" tail (LAST em-dash separator) so the notes stay generic.
    stripAuthor t = case T.breakOnEnd " — " t of
        (pre, _) | not (T.null pre) -> T.strip (T.dropEnd 3 pre)
        _ -> T.strip t
    picked = map stripAuthor (take 40 (if null notable then map snd grouped else notable))
    userMsg = fence "context" (T.unlines (map ("- " <>) picked))
    fallback = deterministicShort grouped

-- | Tidy the model's synopsis: drop leading bullet/markdown noise, collapse to one
-- prose blob, and cap the length so the UI summary box stays small.
cleanShort :: Text -> Text
cleanShort t =
    let s = T.strip . T.dropWhile (\c -> c `elem` ['-', '*', '\8226', ' ']) . T.unwords . T.words $ t
     in if T.length s <= 320 then s else T.take 319 s <> "\8230"

-- | Deterministic synopsis from the category counts — the floor when the synopsis AI
-- call fails. Generic (no app name, no totals), so it too can serve as store release
-- notes; never empty on a generated changelog.
deterministicShort :: [(Cat, Text)] -> Text
deterministicShort grouped =
    let tshow = T.pack . show
        n cat = length [() | (c, _) <- grouped, c == cat]
        parts =
            [ tshow k <> " " <> lbl
            | (cat, lbl) <-
                [ (CFeature, "new features")
                , (CFix, "fixes")
                , (CPerf, "performance improvements")
                , (CBreaking, "breaking changes")
                , (CAttention, "changes needing review")
                ]
            , let k = n cat
            , k > 0
            ]
     in case parts of
            [] -> "This release contains maintenance and internal changes."
            ps -> "This release includes " <> T.intercalate ", " ps <> "."

-- | Assemble grouped @(category, summary)@ lines into the Slack-mrkdwn changelog.
renderChangelog :: Text -> Text -> Int -> Int -> Text -> [(Cat, Text)] -> Text
renderChangelog appLabel version inApp excluded excludedSide grouped =
    T.unlines (headerLine : "" : topSection ++ bodySections ++ [acctLine])
  where
    tshow = T.pack . show
    bullet s = "• " <> s
    grandTotal = inApp + excluded
    notableLines = [s | (c, s) <- grouped, isNotable c]
    notableCount = length notableLines
    internalCount = length grouped - notableCount
    verPart = if T.null (T.strip version) then "" else " — " <> T.strip version
    exclNote =
        if excluded > 0
            then " (" <> tshow excluded <> " " <> excludedSide <> " commits excluded)"
            else ""
    headerLine =
        "📱 " <> appLabel <> verPart <> " — " <> tshow grandTotal <> " commits, " <> tshow notableCount <> " notable changes" <> exclNote
    topSection =
        let top = take 5 notableLines
         in if null top then [] else "*Top changes:*" : map bullet top ++ [""]
    bodySections = concatMap renderCat cats
    renderCat (c, label) =
        let ls = [s | (c', s) <- grouped, c' == c]
         in if null ls then [] else ("*" <> label <> "*") : map bullet ls ++ [""]
    exclPart = if excluded > 0 then " + " <> tshow excluded <> " excluded" else ""
    acctLine =
        "✅ Accounted for: "
            <> tshow notableCount
            <> " notable + "
            <> tshow internalCount
            <> " internal"
            <> exclPart
            <> " = "
            <> tshow grandTotal
            <> " commits"

{- | Generate, retrying the whole chunked run up to 'maxAttempts' times (a run only
fails to produce anything when commits is empty). Returns @(long, short, model)@.
Keep @maxAttempts × per-call timeout × chunk count@ within reason vs the
'claimReleaseSummary' stale-reclaim window (10 min).
-}
generateWithFallback :: (MonadFlow m) => Text -> AiConfig -> Text -> Text -> Int -> Text -> [CommitItem] -> m (Maybe (Text, Text, Text))
generateWithFallback createdBy cfg appLabel version excluded excludedSide commits =
    go maxAttempts
  where
    maxAttempts = 2 :: Int
    go n = do
        res <- generateReleaseSummaries createdBy cfg appLabel version excluded excludedSide commits
        case res of
            Just (lng, sht) -> pure (Just (lng, sht, aiModel cfg))
            Nothing | n > 1 -> go (n - 1)
            Nothing -> pure Nothing

-- | One audited completion. The caller supplies the final (fenced) user message.
aiComplete :: (MonadFlow m) => Text -> AiConfig -> Text -> Text -> Text -> m (Either AiError Text)
aiComplete createdBy cfg taskName systemPrompt userMsg = do
    let phash = computePromptHash $ T.intercalate "\US" [aiModel cfg, taskName, systemPrompt, userMsg]
    t0 <- liftIO getCurrentTime
    res <- complete cfg (AiCompletion systemPrompt userMsg (aiModel cfg) (aiTemperature cfg))
    t1 <- liftIO getCurrentTime
    let ms = round (realToFrac (diffUTCTime t1 t0) * 1000 :: Double) :: Int32
    case res of
        Left e -> do
            insertAiAuditLog "changelog" taskName taskName (aiModel cfg) phash 0 0 ms "error" (Just (aiErrorReason e)) createdBy
            pure (Left e)
        Right r -> do
            insertAiAuditLog "changelog" taskName taskName (aiModel cfg) phash (acrInputTokens r) (acrOutputTokens r) ms "ok" Nothing createdBy
            pure (Right (acrText r))
