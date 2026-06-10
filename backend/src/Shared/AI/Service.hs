{-# LANGUAGE OverloadedStrings #-}

{- | The task orchestrator: gate → prompt → hash → cache → provider → audit →
cache. The one function handlers call. @createdBy@ is the operator email (passed
in, so @Shared@ need not depend on the auth layer). Daily spend is capped on the
Grid key (gateway-enforced), so there is no app-side budget gate here.
-}
module Shared.AI.Service (runAiTask) where

import Control.Monad.IO.Class (liftIO)
import Core.Environment (MonadFlow)
import Data.Int (Int32)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Clock (diffUTCTime, getCurrentTime)
import Shared.AI.Config (loadAiConfig)
import Shared.AI.Prompts (buildPrompt)
import Shared.AI.Provider (complete)
import Shared.AI.Queries (cacheAiSummary, computePromptHash, insertAiAuditLog, lookupAiSummaryCache)
import Shared.AI.Types

-- | @fencedUser@ is already delimited (commit \<context\>, and for Q&A the \<question\>).
runAiTask ::
    (MonadFlow m) =>
    -- | createdBy (operator email)
    Text ->
    AiTask ->
    AiSubject ->
    -- | fenced user content
    Text ->
    -- | force regenerate (bypass cache read)
    Bool ->
    m (Either AiError AiResult)
runAiTask createdBy task subject fencedUser force = do
    ecfg <- loadAiConfig
    case ecfg of
        Left e -> pure (Left e)
        Right cfg -> do
            let (sys, usr) = buildPrompt task fencedUser
                phash =
                    computePromptHash $
                        T.intercalate
                            "\US"
                            [ aiModel cfg
                            , taskText task
                            , T.pack (show (aiTemperature cfg))
                            , sys
                            , usr
                            ]
            mHit <-
                if force
                    then pure Nothing
                    else
                        lookupAiSummaryCache
                            (asType subject)
                            (asId subject)
                            (taskText task)
                            (aiModel cfg)
                            phash
            now <- liftIO getCurrentTime
            case mHit of
                Just (txt, inT, outT) -> do
                    audit cfg phash inT outT 0 "cache_hit" Nothing
                    pure (Right (AiResult txt (aiModel cfg) True inT outT now))
                Nothing -> do
                    t0 <- liftIO getCurrentTime
                    res <- complete cfg (AiCompletion sys usr (aiModel cfg) (aiTemperature cfg))
                    t1 <- liftIO getCurrentTime
                    let ms = round (realToFrac (diffUTCTime t1 t0) * 1000 :: Double) :: Int32
                    case res of
                        Left e -> do
                            audit cfg phash 0 0 ms "error" (Just (aiErrorReason e))
                            pure (Left e)
                        Right r -> do
                            cacheAiSummary
                                (asType subject)
                                (asId subject)
                                (taskText task)
                                (aiModel cfg)
                                phash
                                (acrText r)
                                (acrInputTokens r)
                                (acrOutputTokens r)
                                (aiCacheTtlHrs cfg)
                            audit cfg phash (acrInputTokens r) (acrOutputTokens r) ms "ok" Nothing
                            pure
                                ( Right
                                    ( AiResult
                                        (acrText r)
                                        (aiModel cfg)
                                        False
                                        (acrInputTokens r)
                                        (acrOutputTokens r)
                                        t1
                                    )
                                )
  where
    audit cfg phash inT outT ms status mErr =
        insertAiAuditLog
            (asType subject)
            (asId subject)
            (taskText task)
            (aiModel cfg)
            phash
            inT
            outT
            ms
            status
            mErr
            createdBy
