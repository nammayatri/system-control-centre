{-# LANGUAGE OverloadedStrings #-}

{- | AI review layer for ConfigMap (BackendConfig) deployments.

When an operator changes a backend deployment's configuration (the Dhall-derived
K8s ConfigMap tracked as a @BackendConfig@ release), this runs the before/after
config diff plus a platform-authored Markdown rules file through the shared AI
engine ('Shared.AI.Service.runAiTask', task 'TaskConfigReview') and records a
verdict — SAFE / POTENTIALLY_BREAKING / BREAKING — with reasoning.

The rules file is resolved per app-group with a global fallback:
@\<dir\>/\<appGroup\>.md@, else @\<dir\>/default.md@, else a small built-in
default — so the feature degrades gracefully when no file is shipped.
-}
module Products.Autopilot.ConfigReview (
    StoredReview (..),
    runConfigReview,
    readStoredReview,
    acknowledgeReview,
    reviewBlocksApproval,
    resolveRulesFile,
) where

import Control.Monad.IO.Class (liftIO)
import Core.Environment (Flow, MonadFlow, logInfo)
import Data.Aeson (Value (..), object, (.=))
import Data.Aeson.Key qualified as K
import Data.Aeson.KeyMap qualified as KM
import Data.List (sortBy)
import Data.Maybe (fromMaybe, isNothing, listToMaybe)
import Data.Ord (Down (..), comparing)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Data.Time.Clock (getCurrentTime)
import Data.Time.Format (defaultTimeLocale, formatTime)
import Products.Autopilot.ConfigDiff (configMapBeforeAfter, decodeBase64Config, deploymentBeforeAfter)
import Products.Autopilot.Queries.ReleaseTracker (
    findReleaseTracker,
    insertReleaseEvent,
    listReleaseEventsByCategory,
    updateReleaseTrackerMetadata,
 )
import Products.Autopilot.Types (ReleaseCategory (..), ReleaseTracker (..))
import Products.Autopilot.Types.Storage.Schema qualified as S
import Shared.AI.Prompts (fence)
import Shared.AI.Service (runAiTask)
import Shared.AI.Types (AiError (..), AiResult (..), AiSubject (..), AiTask (..))
import Shared.Config.Runtime (getConfigBoolForProduct, getConfigTextForProduct)
import System.Directory (doesFileExist)
import System.FilePath ((</>))

-- ─── Verdict ───────────────────────────────────────────────────────

-- | Canonical verdict strings (also what the model is asked to emit).
verdictSafe, verdictPotentially, verdictBreaking :: Text
verdictSafe = "SAFE"
verdictPotentially = "POTENTIALLY_BREAKING"
verdictBreaking = "BREAKING"

-- | A breaking-ish verdict blocks approval until acknowledged.
verdictIsBreaking :: Text -> Bool
verdictIsBreaking v = v == verdictPotentially || v == verdictBreaking

parseVerdict :: Text -> Text
parseVerdict txt =
    let firstLine =
            T.toUpper . T.strip . fromMaybe "" . listToMaybe $
                filter (not . T.null) (map T.strip (T.lines txt))
     in if "POTENTIALLY" `T.isInfixOf` firstLine && "BREAKING" `T.isInfixOf` firstLine
            then verdictPotentially
            else
                if "SAFE" `T.isInfixOf` firstLine
                    then verdictSafe
                    else
                        if "BREAKING" `T.isInfixOf` firstLine
                            then verdictBreaking
                            else verdictPotentially

-- ─── Stored review (metadata.ai_review + latest event) ─────────────

-- | The persisted review state surfaced to the UI.
data StoredReview = StoredReview
    { srVerdict :: Text
    , srSummary :: Maybe Text
    , srModel :: Maybe Text
    , srCached :: Maybe Bool
    , srReviewedAt :: Maybe Text
    , srAckBy :: Maybe Text
    , srAckAt :: Maybe Text
    }

metaObject :: ReleaseTracker -> KM.KeyMap Value
metaObject tr = case metadata tr of
    Just (Object o) -> o
    _ -> KM.empty

aiReviewObject :: ReleaseTracker -> Maybe (KM.KeyMap Value)
aiReviewObject tr = case KM.lookup (K.fromText "ai_review") (metaObject tr) of
    Just (Object o) -> Just o
    _ -> Nothing

getTextField :: Text -> KM.KeyMap Value -> Maybe Text
getTextField key o = case KM.lookup (K.fromText key) o of
    Just (String s) -> Just s
    _ -> Nothing

{- | Does this tracker's review currently block approval? True when the verdict
is breaking-ish and no acknowledgement has been recorded.
-}
reviewBlocksApproval :: ReleaseTracker -> Bool
reviewBlocksApproval tr = case aiReviewObject tr of
    Just o ->
        maybe False verdictIsBreaking (getTextField "verdict" o)
            && isNothing (getTextField "ack_by" o)
    Nothing -> False

-- ─── Rules file resolution ─────────────────────────────────────────

defaultRulesDir :: Text
defaultRulesDir = "dhall-configs/config-review-rules"

-- | Keep only path-safe characters so an app-group name can't traverse paths.
sanitizeSegment :: Text -> Text
sanitizeSegment = T.filter (\c -> c == '.' || c == '_' || c == '-' || c `elem` alnum)
  where
    alnum = ['a' .. 'z'] ++ ['A' .. 'Z'] ++ ['0' .. '9']

builtinDefaultRules :: Text
builtinDefaultRules =
    T.unlines
        [ "# Config change breaking-risk rules (built-in default)"
        , ""
        , "Flag a change as potentially breaking if it does any of the following:"
        , "- Removes or renames an existing configuration key."
        , "- Changes a database / redis / kafka host, port, name, or credentials reference."
        , "- Reduces a connection-pool size, replica count, or resource limit."
        , "- Flips a feature flag that gates production behaviour."
        , "- Changes an external URL, endpoint, timeout, or rate limit."
        , "- Changes a secret reference or auth/permission setting."
        , "Pure additions of new, unused keys are usually SAFE."
        ]

{- | Resolve the review rules Markdown for an app-group: per-group file first,
then a global @default.md@, then a small built-in default. The directory is
configurable via server_config @ai_config_review_rules_dir@.
-}
resolveRulesFile :: (MonadFlow m) => Text -> m Text
resolveRulesFile appGroup = do
    dir <- getConfigTextForProduct "ai_config_review_rules_dir" (Just "autopilot") defaultRulesDir
    let base = T.unpack (T.dropWhileEnd (== '/') (T.strip dir))
        seg = sanitizeSegment appGroup
        candidates =
            [base </> T.unpack seg <> ".md" | not (T.null seg)]
                ++ [base </> "default.md"]
    liftIO (firstExisting candidates)
  where
    firstExisting [] = pure builtinDefaultRules
    firstExisting (p : ps) = do
        ok <- doesFileExist p
        if ok then TIO.readFile p else firstExisting ps

-- ─── Run + persist ─────────────────────────────────────────────────

isoNow :: (MonadFlow m) => m Text
isoNow = do
    now <- liftIO getCurrentTime
    pure (T.pack (formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%S%QZ" now))

{- | Merge an @ai_review@ object into the tracker's metadata -}
writeAiReview :: Text -> KM.KeyMap Value -> Flow ()
writeAiReview rid reviewObj = do
    mFresh <- findReleaseTracker rid
    let base = maybe KM.empty (metaObject . fst) mFresh
        merged = KM.insert (K.fromText "ai_review") (Object reviewObj) base
    updateReleaseTrackerMetadata rid (Object merged)

reviewParams ::
    ReleaseCategory ->
    Maybe (Text, Text, ReleaseTracker -> Flow (Text, Text), Text -> Text)
reviewParams BackendConfig = Just ("ai_config_review_enabled", "configmap", configMapBeforeAfter, decodeBase64Config)
reviewParams BackendService = Just ("ai_deployment_review_enabled", "deployment", deploymentBeforeAfter, id)
reviewParams _ = Nothing

{- | Run the AI breaking-change review for a tracker and persist the result.
Handles ConfigMap (BackendConfig) and deployment (BackendService) releases;
-}

runConfigReview :: Text -> ReleaseTracker -> Bool -> Flow (Either AiError StoredReview)
runConfigReview createdBy tracker force =
    case reviewParams (category tracker) of
        Nothing -> pure (Left AiDisabled)
        Just (enableFlag, subjectType, extract, postProcess) -> do
            enabled <- getConfigBoolForProduct enableFlag (Just "autopilot") True
            if not enabled
                then pure (Left AiDisabled)
                else do
                    let rid = releaseId tracker
                    (beforeRaw, afterRaw) <- extract tracker
                    let before = postProcess beforeRaw
                        after = postProcess afterRaw
                    if T.strip before == T.strip after
                        then persist rid verdictSafe "No changes detected in the configuration data." Nothing (Just False)
                        else do
                            rules <- resolveRulesFile (appGroup tracker)
                            let fenced =
                                    fence "rules" rules
                                        <> "\n"
                                        <> fence "before" before
                                        <> "\n"
                                        <> fence "after" after
                            res <- runAiTask createdBy TaskConfigReview (AiSubject subjectType rid) fenced force
                            case res of
                                Left e -> do
                                    logInfo $ "[CONFIG-REVIEW] AI call failed for " <> rid <> ": " <> aiErrorReasonT e
                                    pure (Left e)
                                Right r ->
                                    persist rid (parseVerdict (arText r)) (arText r) (Just (arModel r)) (Just (arCached r))
  where
    aiErrorReasonT = T.pack . show
    persist rid verdict summary mModel mCached = do
        reviewedAt <- isoNow
        let reviewObj =
                KM.fromList
                    [ (K.fromText "verdict", String verdict)
                    , (K.fromText "reviewed_at", String reviewedAt)
                    , (K.fromText "ack_by", Null)
                    , (K.fromText "ack_at", Null)
                    , (K.fromText "model", maybe Null String mModel)
                    ]
        insertReleaseEvent
            rid
            "AI"
            "AI_CONFIG_REVIEW"
            ( object
                [ "verdict" .= verdict
                , "summary" .= summary
                , "model" .= mModel
                , "cached" .= mCached
                , "reviewed_at" .= reviewedAt
                ]
            )
        writeAiReview rid reviewObj
        logInfo $ "[CONFIG-REVIEW] " <> rid <> " verdict=" <> verdict
        pure $
            Right
                StoredReview
                    { srVerdict = verdict
                    , srSummary = Just summary
                    , srModel = mModel
                    , srCached = mCached
                    , srReviewedAt = Just reviewedAt
                    , srAckBy = Nothing
                    , srAckAt = Nothing
                    }

{- | Record an operator acknowledgement of the current review verdict, so a
breaking change can proceed to approval. No-op when there is no review to ack.
-}
acknowledgeReview :: Text -> Text -> Flow ()
acknowledgeReview rid email = do
    mFresh <- findReleaseTracker rid
    case aiReviewObject . fst =<< mFresh of
        Nothing -> pure ()
        Just o -> do
            ackAt <- isoNow
            let updated =
                    KM.insert (K.fromText "ack_by") (String email)
                        . KM.insert (K.fromText "ack_at") (String ackAt)
                        $ o
            writeAiReview rid updated
            logInfo $ "[CONFIG-REVIEW] " <> rid <> " acknowledged by " <> email

{- | Reconstruct the persisted review for the detail endpoint: verdict +
acknowledgement from @metadata.ai_review@, reasoning + model from the latest
@AI_CONFIG_REVIEW@ event. 'Nothing' when no review has run yet.
-}
readStoredReview :: ReleaseTracker -> Flow (Maybe StoredReview)
readStoredReview tracker = case aiReviewObject tracker of
    Nothing -> pure Nothing
    Just o -> do
        events <- listReleaseEventsByCategory (releaseId tracker) "AI"
        let matching = filter (\e -> S.reLabel e == "AI_CONFIG_REVIEW") events
            latest = listToMaybe (sortBy (comparing (Down . S.reCreatedAt)) matching)
            summary = latest >>= (eventField "summary" . S.rePayload)
            evModel = latest >>= (eventField "model" . S.rePayload)
        pure $
            Just
                StoredReview
                    { srVerdict = fromMaybe verdictPotentially (getTextField "verdict" o)
                    , srSummary = summary
                    , srModel = getTextField "model" o `orElse` evModel
                    , srCached = Nothing
                    , srReviewedAt = getTextField "reviewed_at" o
                    , srAckBy = getTextField "ack_by" o
                    , srAckAt = getTextField "ack_at" o
                    }
  where
    orElse (Just x) _ = Just x
    orElse Nothing y = y
    eventField key (Object ev) = case KM.lookup (K.fromText key) ev of
        Just (String s) -> Just s
        _ -> Nothing
    eventField _ _ = Nothing
