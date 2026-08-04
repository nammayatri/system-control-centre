{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

{- | POST /mobile/releases/:id/verify-store — the manual heal button.

A failed build row whose GitHub job died AFTER the store upload (tag push,
notify, runner crash) strands a live store artifact behind a FAILED badge.
This handler re-verifies the row against store truth ("Products.Autopilot.Mobile.Heal")
and, on a confirmed artifact, flips it back into the in-flight lifecycle at
MBSubmittedToStore — the scheduler then resumes at ConfirmTag and the release
continues normally. Idempotent from the operator's side: a miss changes
nothing and reports why.
-}
module Products.Autopilot.Mobile.Handlers.Heal (
    VerifyStoreResp (..),
    verifyStoreH,
) where

import Control.Applicative ((<|>))
import Control.Monad (when)
import Control.Monad.Catch (throwM)
import Control.Monad.IO.Class (liftIO)
import Core.AppError (APIError (..))
import Core.Auth.Protected (AuthedPerson (..))
import Core.Environment (Flow)
import Data.Aeson (FromJSON, ToJSON, object, (.=))
import Data.Int (Int32)
import Data.List (find)
import Data.Proxy (Proxy (..))
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time.Clock (getCurrentTime)
import GHC.Generics (Generic)
import Products.Autopilot.Mobile.Auth (requireAppPerm)
import Products.Autopilot.Mobile.Github (Job (..), listJobs)
import Products.Autopilot.Mobile.Github.Auth (loadGhCreds)
import Products.Autopilot.Mobile.Heal (
    JobFailureShape (..),
    RunIdentity (..),
    StoreVerifyResult (..),
    classifyFailedJob,
    fetchRunIdentity,
    verifyStoreArtifact,
 )
import Products.Autopilot.Mobile.Queries.Tracker (
    appCatalogForRowRaw,
    findMobileReleaseById,
    findMobileVersionRow,
    gitOwner,
    gitRepo,
    healBuildSubmitted,
    logEvent,
 )
import Products.Autopilot.Mobile.Types (
    MobileBuildContext (..),
    MobileBuildTargetState (..),
    MobileBuildWFStatus (..),
    isDebugBuildType,
 )
import Products.Autopilot.Mobile.Types.Storage (AppCatalog, AppCatalogT (..))
import Products.Autopilot.Types.Storage.Schema (ReleaseTrackerT (..))
import Products.Mobile.Types.Permission (MobilePermission (..))

-- | What the operator sees after pressing "Verify on store".
data VerifyStoreResp = VerifyStoreResp
    { vsResult :: Text
    -- ^ "healed" | "not_found"
    , vsDetail :: Text
    , vsObservedCode :: Maybe Int32
    }
    deriving (Eq, Show, Generic)

instance ToJSON VerifyStoreResp
instance FromJSON VerifyStoreResp

verifyStoreH :: AuthedPerson -> Text -> Flow VerifyStoreResp
verifyStoreH ap rid = do
    mRel <- findMobileReleaseById rid
    (row, mTarget) <- maybe (bad ("Mobile release not found: " <> rid)) pure mRel
    target <- maybe (bad ("Not a parseable mobile release: " <> rid)) pure mTarget
    ac <- appCatalogForRowRaw row
    requireAppPerm (Proxy @'MB_MOBILE_DISPATCH) ap (acName ac) (acPlatform ac)
    let ctx = mbContext target
        version = rtNewVersion row
    failReason <- case mbWfStatus target of
        MBFailed r -> pure r
        other -> bad ("Only failed builds can be verified against the store (current: " <> tshow other <> ").")
    when (isDebugBuildType (mbcBuildType ctx)) $
        bad "Debug builds never reach a store — nothing to verify."
    when (mbcDestination ctx == Just "Firebase") $
        bad "Firebase App Distribution builds never reach a store — nothing to verify."
    -- Identity-slot guard: a failed-untagged row releases its (version) slot, so
    -- a newer release row may own this version by now. Healing would fork the
    -- identity — refuse and name the owner instead.
    mOwner <- findMobileVersionRow (rtAppGroup row) (rtService row) (rtEnv row) version Nothing
    case mOwner of
        Just owner
            | rtId owner /= rid ->
                bad
                    ( "Version "
                        <> version
                        <> " is now owned by release "
                        <> rtId owner
                        <> " — healing this row would collide; resolve manually."
                    )
        _ -> pure ()
    -- CI evidence (best-effort): step shape short-circuits clear non-uploads;
    -- the log's exact build number sharpens the store match. Any failure here
    -- degrades to Nothing — the store check below stays the decider.
    (mShape, mLogCode) <- ciEvidence ac target version
    case mShape of
        Just UploadFailed ->
            pure (notFound "CI shows the store-upload step itself failed — there is no artifact to heal.")
        Just UploadNotReached ->
            pure (notFound "CI failed before the store-upload step ran — there is no artifact to heal.")
        _ -> do
            let mCode = mbcVersionCode ctx <|> mLogCode
            verifyStoreArtifact ac version mCode (mbBuildStartedAt target) >>= \case
                VerifyErrored e -> bad ("Store verification failed: " <> e)
                ArtifactMissing ->
                    pure . notFound $
                        "The store has no build "
                            <> version
                            <> maybe "" (\c -> " (" <> tshow c <> ")") mCode
                            <> " — the CI failure was real. Create a new release (or a revert) to ship."
                ArtifactFound mObs -> do
                    now <- liftIO getCurrentTime
                    healBuildSubmitted now rid mObs
                    logEvent rid "BUILD_HEALED_FROM_STORE" $
                        object
                            [ "trigger" .= ("manual" :: Text)
                            , "actor" .= apEmail ap
                            , "observed_code" .= mObs
                            , "failed_reason" .= failReason
                            , "ci_step_evidence" .= fmap tshow mShape
                            ]
                    pure
                        VerifyStoreResp
                            { vsResult = "healed"
                            , vsDetail = "Artifact verified on the store — release resumed; the tag will be confirmed and the lifecycle continues."
                            , vsObservedCode = mObs
                            }
  where
    notFound d = VerifyStoreResp{vsResult = "not_found", vsDetail = d, vsObservedCode = Nothing}

{- | Layer 1+2 evidence from the failed run: the matrix job's step shape and the
exact build code parsed from its log (accepted only when the log's version
matches this row — a rewired job name must not donate a foreign code).
-}
ciEvidence :: AppCatalog -> MobileBuildTargetState -> Text -> Flow (Maybe JobFailureShape, Maybe Int32)
ciEvidence ac target version = case mbExternalRunId target of
    Nothing -> pure (Nothing, Nothing)
    Just runId -> do
        creds <- loadGhCreds
        let owner = gitOwner ac
            repo = gitRepo ac
        listJobs creds owner repo runId >>= \case
            Left _ -> pure (Nothing, Nothing)
            Right jobs -> case find ((== mbcMatrixJobName (mbContext target)) . jName) jobs of
                Nothing -> pure (Nothing, Nothing)
                Just j -> do
                    eIdent <- fetchRunIdentity creds owner repo (jId j)
                    let mCode = case eIdent of
                            Right ident | riVersionName ident == version -> riVersionCode ident
                            _ -> Nothing
                    pure (Just (classifyFailedJob j), mCode)

bad :: Text -> Flow a
bad = throwM . BadRequest

tshow :: (Show a) => a -> Text
tshow = T.pack . show
