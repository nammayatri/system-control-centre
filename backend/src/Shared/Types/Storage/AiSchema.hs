{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TypeFamilies #-}

{- | Cross-product AI tables: @ai_summary_cache@ (memoised summaries) and
@ai_audit_log@ (every call, for cost/incident review). Self-contained under
@Shared@ so any product can reuse the engine. Serial @Int32@ PKs mirror
@release_events@; the cache is keyed by content (see 'Shared.AI.Queries').
-}
module Shared.Types.Storage.AiSchema (
    AiSummaryCacheT (..),
    AiSummaryCache,
    AiAuditLogT (..),
    AiAuditLog,
    AiDb (..),
    aiDb,
) where

import Data.Text (Text)
import Data.Time.Clock (UTCTime)
import Database.Beam
import GHC.Int (Int32)

data AiSummaryCacheT f = AiSummaryCacheT
    { ascId :: Columnar f Int32
    , ascSubjectType :: Columnar f Text
    , ascSubjectId :: Columnar f Text
    , ascTask :: Columnar f Text
    , ascModel :: Columnar f Text
    , ascPromptHash :: Columnar f Text
    , ascSummary :: Columnar f Text
    , ascInputTokens :: Columnar f Int32
    , ascOutputTokens :: Columnar f Int32
    , ascCacheValidUntil :: Columnar f UTCTime
    , ascCreatedAt :: Columnar f UTCTime
    }
    deriving (Generic, Beamable)

type AiSummaryCache = AiSummaryCacheT Identity

deriving instance Show AiSummaryCache

instance Table AiSummaryCacheT where
    data PrimaryKey AiSummaryCacheT f = AiSummaryCacheId (Columnar f Int32) deriving (Generic, Beamable)
    primaryKey = AiSummaryCacheId . ascId

data AiAuditLogT f = AiAuditLogT
    { aalId :: Columnar f Int32
    , aalSubjectType :: Columnar f Text
    , aalSubjectId :: Columnar f Text
    , aalTask :: Columnar f Text
    , aalModel :: Columnar f Text
    , aalPromptHash :: Columnar f Text
    , aalInputTokens :: Columnar f Int32
    , aalOutputTokens :: Columnar f Int32
    , aalLatencyMs :: Columnar f Int32
    , aalStatus :: Columnar f Text
    , aalError :: Columnar f (Maybe Text)
    , aalCreatedBy :: Columnar f Text
    , aalCreatedAt :: Columnar f UTCTime
    }
    deriving (Generic, Beamable)

type AiAuditLog = AiAuditLogT Identity

deriving instance Show AiAuditLog

instance Table AiAuditLogT where
    data PrimaryKey AiAuditLogT f = AiAuditLogId (Columnar f Int32) deriving (Generic, Beamable)
    primaryKey = AiAuditLogId . aalId

data AiDb f = AiDb
    { aiSummaryCache :: f (TableEntity AiSummaryCacheT)
    , aiAuditLog :: f (TableEntity AiAuditLogT)
    }
    deriving (Generic, Database be)

aiDb :: DatabaseSettings be AiDb
aiDb =
    defaultDbSettings
        `withDbModification` dbModification
            { aiSummaryCache =
                setEntityName "ai_summary_cache"
                    <> modifyTableFields
                        tableModification
                            { ascId = fieldNamed "id"
                            , ascSubjectType = fieldNamed "subject_type"
                            , ascSubjectId = fieldNamed "subject_id"
                            , ascTask = fieldNamed "task"
                            , ascModel = fieldNamed "model"
                            , ascPromptHash = fieldNamed "prompt_hash"
                            , ascSummary = fieldNamed "summary"
                            , ascInputTokens = fieldNamed "input_tokens"
                            , ascOutputTokens = fieldNamed "output_tokens"
                            , ascCacheValidUntil = fieldNamed "cache_valid_until"
                            , ascCreatedAt = fieldNamed "created_at"
                            }
            , aiAuditLog =
                setEntityName "ai_audit_log"
                    <> modifyTableFields
                        tableModification
                            { aalId = fieldNamed "id"
                            , aalSubjectType = fieldNamed "subject_type"
                            , aalSubjectId = fieldNamed "subject_id"
                            , aalTask = fieldNamed "task"
                            , aalModel = fieldNamed "model"
                            , aalPromptHash = fieldNamed "prompt_hash"
                            , aalInputTokens = fieldNamed "input_tokens"
                            , aalOutputTokens = fieldNamed "output_tokens"
                            , aalLatencyMs = fieldNamed "latency_ms"
                            , aalStatus = fieldNamed "status"
                            , aalError = fieldNamed "error"
                            , aalCreatedBy = fieldNamed "created_by"
                            , aalCreatedAt = fieldNamed "created_at"
                            }
            }
