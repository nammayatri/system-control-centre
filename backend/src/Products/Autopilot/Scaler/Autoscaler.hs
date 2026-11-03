{-# LANGUAGE OverloadedStrings #-}

{- | Viewing and changing the autoscaler that drives a target, from the console. The autoscaler reads its
settings from the payload of a Cloud Scheduler job; this module reads that payload, validates an edit,
writes it back, and keeps a history so a change can be reviewed and put back.

Safety rules:

* only a short list of settings can be changed, and only ones that already exist in the entry (see
  'Logic.editableKeys'); the entry's identity (cluster, pool, project, region) is never touched;
* an edit carries the payload it was made against; if the job changed since (someone else edited it, or a
  scheduled hold pinned the minimum) it is refused rather than overwriting;
* while a scheduled change is holding the minimum, that setting is read-only, so a manual edit and the
  hold cannot fight over it;
* every change is read back and recorded with both entries.
-}
module Products.Autopilot.Scaler.Autoscaler (
    AutoscalerView (..),
    EditErr (..),
    editErrText,
    readAutoscaler,
    editAutoscaler,
    revertAutoscaler,
    setAutoscalerPaused,
)
where

import Control.Monad.IO.Class (liftIO)
import Core.Environment (Flow)
import Data.Aeson (Value (..), (.=))
import Data.Aeson qualified as A
import Data.Aeson.Key qualified as K
import Data.Aeson.KeyMap qualified as KM
import Data.Text (Text)
import Data.Text qualified as T
import Products.Autopilot.Hpa.Types (isTerminalApply, parseApplyStatus)
import Products.Autopilot.Scaler.Gcp
import Products.Autopilot.Scaler.Logic
import Products.Autopilot.Scaler.Store
import Products.Autopilot.Scaler.Types

-- | What the editor shows: the job, its state, and this target's entry.
data AutoscalerView = AutoscalerView
    { avJob :: Text
    , avJobLocation :: Text
    , avState :: Text
    , avSchedule :: Text
    , avData :: Text
    -- ^ The payload as read (base64). Sent back with an edit to detect a change in between.
    , avEntry :: Value
    , avEditable :: [(Text, KeyKind)]
    , avHeldBy :: Maybe Text
    -- ^ An in-flight scaler apply that is holding the minimum, if any.
    }
    deriving (Eq, Show)

data EditErr
    = -- | The request is invalid; every problem.
      EditBad [Text]
    | -- | The job changed since it was read, or a hold owns the setting.
      EditConflict Text
    | EditNotFound Text
    | EditCloud Text
    deriving (Eq, Show)

editErrText :: EditErr -> Text
editErrText (EditBad ms) = T.intercalate "; " ms
editErrText (EditConflict m) = m
editErrText (EditNotFound m) = m
editErrText (EditCloud m) = m

fromGcp :: GcpErr -> EditErr
fromGcp (GcpNotFound m) = EditNotFound m
fromGcp (GcpConflict m) = EditConflict m
fromGcp (GcpFailed m) = EditCloud m

-- | An apply that currently owns the minimum (it wrote, or is about to write, a pin that is not yet put back).
holdingApply :: Text -> Target -> Flow (Maybe Text)
holdingApply cloud t = do
    rows <- inflightApplies cloud (tgKind t) (tgId t)
    pure $ case [arId r | r <- rows, holds r] of
        (x : _) -> Just x
        [] -> Nothing
  where
    holds r = case (parseApplyStatus (arStatus r), arAfterSpec r >>= decodeAfter) of
        (Just s, Just a) -> not (isTerminalApply s) && (saPinned a /= Nothing || saPinIntent a /= Nothing)
        _ -> False
    decodeAfter v = case A.fromJSON v of
        A.Success a -> Just (a :: ScaleAfter)
        A.Error _ -> Nothing

readAutoscaler :: Gcp -> Text -> Target -> Flow (Either EditErr AutoscalerView)
readAutoscaler gcp cloud t = case tgJob t of
    Nothing -> pure (Left (EditNotFound "this target has no autoscaler job configured"))
    Just job -> do
        r <- liftIO (gcpGetJob gcp t)
        case r of
            Left e -> pure (Left (fromGcp e))
            Right j -> case decodeJobData (sjData j) >>= entryFor (autoscalerKeys t) of
                Left e -> pure (Left (EditBad [e]))
                Right entry -> do
                    held <- holdingApply cloud t
                    pure (Right (AutoscalerView job (jobLocationOf t) (sjState j) (sjSchedule j) (sjData j) entry (editableKeys (tgKind t)) held))

{- | Apply an edit. @expected@ is the payload the editor was showing; the edit is refused if the job has
changed since. @note@ is a free-text reason kept in the history.
-}
editAutoscaler :: Gcp -> Text -> Target -> Text -> Text -> EditReq -> Text -> Text -> Flow (Either EditErr Value)
editAutoscaler gcp cloud t actor action req expected note = case tgJob t of
    Nothing -> pure (Left (EditNotFound "this target has no autoscaler job configured"))
    Just _ -> do
        got <- liftIO (gcpGetJob gcp t)
        case got of
            Left e -> pure (Left (fromGcp e))
            Right job
                | sjData job /= expected ->
                    pure (Left (EditConflict "the autoscaler config changed since you opened it; reload and try again"))
                | otherwise -> do
                    held <- holdingApply cloud t
                    let keys = autoscalerKeys t
                        touchesMinimum = akMinKey keys `elem` map fst (erSet req)
                    case (held, touchesMinimum) of
                        (Just aid, True) ->
                            pure (Left (EditConflict ("a scheduled change (" <> aid <> ") is holding " <> akMinKey keys <> " right now; restore it first, or edit the schedule")))
                        _ -> case decodeJobData (sjData job) of
                            Left e -> pure (Left (EditBad [e]))
                            Right payload -> case applyEdit keys (tgKind t) req payload of
                                Left problems -> pure (Left (EditBad problems))
                                Right (new, before, after)
                                    | before == after -> pure (Left (EditBad ["nothing to change"]))
                                    | otherwise -> write job new before after
  where
    write job new before after = do
        w <- liftIO (gcpSetJobData gcp t job (encodeJobData new))
        case w of
            Left e -> pure (Left (fromGcp e))
            Right () -> do
                back <- liftIO (gcpGetJob gcp t)
                let landed = case back of
                        Right j -> (decodeJobData (sjData j) >>= entryFor (autoscalerKeys t)) == Right after
                        Left _ -> False
                addAutoscalerHistory cloud (tgKind t) (tgId t) actor action (nonEmpty note) (Just before) (Just after)
                if landed
                    then pure (Right after)
                    else pure (Left (EditCloud "the change was sent but did not read back as written; check the autoscaler job"))
    nonEmpty s = if T.null (T.strip s) then Nothing else Just (T.strip s)

{- | Put a past change back: the settings and rules of the history row's @before@ entry become the current
ones, through the same validated path as any edit.
-}
revertAutoscaler :: Gcp -> Text -> Target -> Text -> Int -> Text -> Flow (Either EditErr Value)
revertAutoscaler gcp cloud t actor hid expected = do
    h <- getAutoscalerHistory cloud (tgKind t) (tgId t) hid
    case h of
        Nothing -> pure (Left (EditNotFound "history entry not found"))
        Just (Nothing, _) -> pure (Left (EditBad ["that history entry has nothing to put back"]))
        Just (Just (Object before), _) -> do
            cur <- readAutoscaler gcp cloud t
            case cur of
                Left e -> pure (Left e)
                Right v -> case avEntry v of
                    Object now ->
                        let sets = [(k, x) | (k, _) <- editableKeys (tgKind t), Just x <- [KM.lookup (K.fromText k) before], KM.lookup (K.fromText k) now /= Just x]
                            rules = case KM.lookup "scalingRules" before of
                                Just r | KM.lookup "scalingRules" now /= Just r -> Just r
                                _ -> Nothing
                         in editAutoscaler gcp cloud t actor "REVERT" (EditReq sets rules) expected ("reverts change " <> T.pack (show hid))
                    _ -> pure (Left (EditBad ["the current entry is not an object"]))
        Just _ -> pure (Left (EditBad ["that history entry is not a config entry"]))

-- | Pause or resume the job that feeds the autoscaler. A paused job means no scaling decisions at all.
setAutoscalerPaused :: Gcp -> Text -> Target -> Text -> Bool -> Text -> Flow (Either EditErr ())
setAutoscalerPaused gcp cloud t actor paused note = case tgJob t of
    Nothing -> pure (Left (EditNotFound "this target has no autoscaler job configured"))
    Just _ -> do
        r <- liftIO (gcpSetJobPaused gcp t paused)
        case r of
            Left e -> pure (Left (fromGcp e))
            Right () -> do
                let st b = A.object ["state" .= (if b then "PAUSED" else "ENABLED" :: Text)]
                addAutoscalerHistory cloud (tgKind t) (tgId t) actor (if paused then "PAUSE" else "RESUME") (nonEmpty note) (Just (st (not paused))) (Just (st paused))
                pure (Right ())
  where
    nonEmpty s = if T.null (T.strip s) then Nothing else Just (T.strip s)
