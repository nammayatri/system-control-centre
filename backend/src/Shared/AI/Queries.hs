{-# LANGUAGE OverloadedStrings #-}

{- | Cache + audit persistence for the AI engine. The cache is content-addressed
(see 'computePromptHash'); TTL is enforced at query time and the upsert refreshes
the row on the plain unique key (no partial index — see migration 0023).
-}
module Shared.AI.Queries (
    computePromptHash,
    lookupAiSummaryCache,
    cacheAiSummary,
    insertAiAuditLog,
    lookupReleaseSummary,
    upsertReleaseSummary,
    claimReleaseSummary,
) where

import Core.DB.Connection (runDB, withConn)
import Core.Environment (MonadFlow, withDb)
import Crypto.Hash (Digest, SHA256, hash)
import Data.Int (Int32)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Data.Time.Clock (NominalDiffTime, addUTCTime, getCurrentTime)
import Database.Beam
import Database.Beam.Postgres ()
import Database.PostgreSQL.Simple (Only (..), execute, query)
import Shared.Types.Storage.AiSchema

-- | SHA-256 (lowercase hex) of the prompt material; the cache key.
computePromptHash :: Text -> Text
computePromptHash t =
    T.pack (show (hash (TE.encodeUtf8 t) :: Digest SHA256))

{- | Look up a still-valid cached summary by its content key. Returns
@(summary, input_tokens, output_tokens)@.
-}
lookupAiSummaryCache ::
    (MonadFlow m) =>
    Text ->
    Text ->
    Text ->
    Text ->
    Text ->
    m (Maybe (Text, Int32, Int32))
lookupAiSummaryCache subjType subjId task model phash = withDb $ \db -> do
    now <- getCurrentTime
    rows <-
        runDB db $
            runSelectReturningList $
                select $ do
                    c <- all_ (aiSummaryCache aiDb)
                    guard_ (ascSubjectType c ==. val_ subjType)
                    guard_ (ascSubjectId c ==. val_ subjId)
                    guard_ (ascTask c ==. val_ task)
                    guard_ (ascModel c ==. val_ model)
                    guard_ (ascPromptHash c ==. val_ phash)
                    guard_ (ascCacheValidUntil c >. val_ now)
                    pure c
    pure $ case rows of
        (r : _) -> Just (ascSummary r, ascInputTokens r, ascOutputTokens r)
        [] -> Nothing

{- | Upsert a summary into the cache (refresh on the content key). Raw SQL so the
@ON CONFLICT@ targets the plain unique index and the whole thing is one statement.
-}
cacheAiSummary ::
    (MonadFlow m) =>
    Text ->
    Text ->
    Text ->
    Text ->
    Text ->
    Text ->
    Int32 ->
    Int32 ->
    Double ->
    m ()
cacheAiSummary subjType subjId task model phash summary inTok outTok ttlHrs = withDb $ \db -> do
    now <- getCurrentTime
    let validUntil = addUTCTime (realToFrac (ttlHrs * 3600) :: NominalDiffTime) now
    withConn db $ \conn -> do
        _ <-
            execute
                conn
                "INSERT INTO ai_summary_cache \
                \  (subject_type, subject_id, task, model, prompt_hash, summary, input_tokens, output_tokens, cache_valid_until) \
                \VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?) \
                \ON CONFLICT (subject_type, subject_id, task, model, prompt_hash) \
                \DO UPDATE SET summary = EXCLUDED.summary, input_tokens = EXCLUDED.input_tokens, \
                \  output_tokens = EXCLUDED.output_tokens, cache_valid_until = EXCLUDED.cache_valid_until"
                (subjType, subjId, task, model, phash, summary, inTok, outTok, validUntil)
        pure ()

-- | Append a row to the AI audit log (every call: hit, ok, or error).
insertAiAuditLog ::
    (MonadFlow m) =>
    Text ->
    Text ->
    Text ->
    Text ->
    Text ->
    Int32 ->
    Int32 ->
    Int32 ->
    Text ->
    Maybe Text ->
    Text ->
    m ()
insertAiAuditLog subjType subjId task model phash inTok outTok latencyMs status mErr createdBy =
    withDb $ \db -> do
        now <- getCurrentTime
        runDB db $
            runInsert $
                insert (aiAuditLog aiDb) $
                    insertExpressions
                        [ AiAuditLogT
                            { aalId = default_
                            , aalSubjectType = val_ subjType
                            , aalSubjectId = val_ subjId
                            , aalTask = val_ task
                            , aalModel = val_ model
                            , aalPromptHash = val_ phash
                            , aalInputTokens = val_ inTok
                            , aalOutputTokens = val_ outTok
                            , aalLatencyMs = val_ latencyMs
                            , aalStatus = val_ status
                            , aalError = val_ mErr
                            , aalCreatedBy = val_ createdBy
                            , aalCreatedAt = val_ now
                            }
                        ]

-- ─── Release changelog summary (async, content-keyed) ───────────────────────

{- | Cache (or refresh) a generated summary on the content key. The handler is
synchronous: look up; on a miss, generate then upsert here.
-}
upsertReleaseSummary :: (MonadFlow m) => Text -> Text -> Text -> Text -> Int -> m ()
upsertReleaseSummary contentKey longTxt shortTxt model commitCount = withDb $ \db ->
    withConn db $ \conn -> do
        _ <-
            execute
                conn
                "INSERT INTO release_summary (content_key, status, summary_long, summary_short, model, commit_count) \
                \VALUES (?, 'ready', ?, ?, ?, ?) \
                \ON CONFLICT (content_key) DO UPDATE SET status = 'ready', \
                \  summary_long = EXCLUDED.summary_long, summary_short = EXCLUDED.summary_short, \
                \  model = EXCLUDED.model, commit_count = EXCLUDED.commit_count, updated_at = now()"
                (contentKey, longTxt, shortTxt, model, commitCount)
        pure ()

{- | Claim generation for a content key. Inserts a fresh @pending@ row (with the
deterministic changelog as the placeholder @summary_long@ so the UI shows
something immediately), or — if a row already exists — reclaims it ONLY when it
@failed@ or is a @pending@ row orphaned for >10 minutes (e.g. by a restart). The
unique index on @content_key@ makes this the one-generator lock: 'True' means THIS
caller won and should run the generator; 'False' means a fresh @pending@ (someone
else is generating) or a @ready@ row (already done) — don't clobber it.

The 10-minute window MUST exceed the worst-case generation time (the fallback
chain = N models × the per-model timeout). If it's shorter, a slow generation gets
reclaimed mid-flight, spawning a DUPLICATE generator — and duplicates cascade into
concurrent-request overload. Keep this comfortably above @len fallbacks × timeout@.
-}
claimReleaseSummary :: (MonadFlow m) => Text -> Text -> Int -> m Bool
claimReleaseSummary contentKey placeholderLong commitCount = withDb $ \db ->
    withConn db $ \conn -> do
        rows <-
            query
                conn
                "INSERT INTO release_summary (content_key, status, summary_long, commit_count) \
                \VALUES (?, 'pending', ?, ?) \
                \ON CONFLICT (content_key) DO UPDATE SET \
                \  status = 'pending', summary_long = EXCLUDED.summary_long, \
                \  commit_count = EXCLUDED.commit_count, model = NULL, error = NULL, updated_at = now() \
                \WHERE release_summary.status = 'failed' \
                \   OR (release_summary.status = 'pending' AND release_summary.updated_at < now() - interval '10 minutes') \
                \RETURNING id"
                (contentKey, placeholderLong, commitCount) ::
                IO [Only Int]
        pure (not (null rows))

-- | Read a summary row: @(status, long, short, model, commit_count)@.
lookupReleaseSummary ::
    (MonadFlow m) =>
    Text ->
    m (Maybe (Text, Maybe Text, Maybe Text, Maybe Text, Int))
lookupReleaseSummary contentKey = withDb $ \db ->
    withConn db $ \conn -> do
        rows <-
            query
                conn
                "SELECT status, summary_long, summary_short, model, commit_count \
                \FROM release_summary WHERE content_key = ? LIMIT 1"
                (Only contentKey) ::
                IO [(Text, Maybe Text, Maybe Text, Maybe Text, Int)]
        pure $ case rows of
            (r : _) -> Just r
            [] -> Nothing
