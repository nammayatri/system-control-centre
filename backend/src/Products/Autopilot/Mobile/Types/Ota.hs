{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DuplicateRecordFields #-}

{- | Types for OTA-inside-mobile-releases
(docs\/OTA_MOBILE_RELEASE_INTEGRATION.md §5.4/§2b).

'OtaPush' mirrors an @ota_push@ row (ids as Text — cast in SQL).
Response records field-name-match the wire JSON (generic derive,
omitNothingFields). Release STATUS is never in these types: the frontend
reads it live from the airborne BFF (Decision C).
-}
module Products.Autopilot.Mobile.Types.Ota (
    OtaPushStatus (..),
    otaStatusText,
    parseOtaStatus,
    isTerminalOta,
    OtaPush (..),
    OtaLink (..),
    OtaPushResp (..),
    OtaLinkResp (..),
    OtaCapableApp (..),
    OtaActivePush (..),
    OtaGroupResp (..),
    OtaDispatchReq (..),
    OtaDispatchResp (..),
    OtaReleaseConfig (..),
    OtaReleaseReq (..),
    OtaReleaseResp (..),
    OtaOngoingRelease (..),
    OtaAttachReq (..),
    OtaPackageReleaseReq (..),
    OtaProvPkgReq (..),
    OtaProvReq (..),
    OtaProvAnchor (..),
    OtaProvPkgResp (..),
    OtaProvResp (..),
    OtaAdoptBranchReq (..),
    OtaRunJob (..),
    OtaRunStep (..),
    OtaRunJobsResp (..),
    pushToResp,
    linkToResp,
) where

import Data.Aeson (FromJSON (..), Options (..), ToJSON (..), Value, defaultOptions, genericToJSON)
import Data.Int (Int64)
import Data.Map.Strict (Map)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (UTCTime)
import GHC.Generics (Generic)

-- ─── Push status ───────────────────────────────────────────────────

data OtaPushStatus = OtaDispatched | OtaRunning | OtaBundlePushed | OtaFailed
    deriving (Show, Eq, Ord, Enum, Bounded)

otaStatusText :: OtaPushStatus -> Text
otaStatusText OtaDispatched = "DISPATCHED"
otaStatusText OtaRunning = "RUNNING"
otaStatusText OtaBundlePushed = "BUNDLE_PUSHED"
otaStatusText OtaFailed = "FAILED"

parseOtaStatus :: Text -> Maybe OtaPushStatus
parseOtaStatus "DISPATCHED" = Just OtaDispatched
parseOtaStatus "RUNNING" = Just OtaRunning
parseOtaStatus "BUNDLE_PUSHED" = Just OtaBundlePushed
parseOtaStatus "FAILED" = Just OtaFailed
parseOtaStatus _ = Nothing

-- | Terminal rows no longer block the global dispatch guard.
isTerminalOta :: OtaPushStatus -> Bool
isTerminalOta OtaBundlePushed = True
isTerminalOta OtaFailed = True
isTerminalOta _ = False

-- ─── DB rows ───────────────────────────────────────────────────────

data OtaPush = OtaPush
    { opId :: Text
    , opGroupId :: Text
    , opAppName :: Text
    , opPlatform :: Text
    , opAirborneAppRef :: Text
    , opEnv :: Text
    , opRequestedBump :: Text
    , opStatus :: Text
    , opSourceRef :: Text
    , opDispatchBatchId :: Text
    , opExternalRunId :: Maybe Int64
    , opCommitSha :: Maybe Text
    , opBaselinePackageVersion :: Maybe Int
    , opPackageVersion :: Maybe Int
    , opFinalVersion :: Maybe Text
    , opResolvedVia :: Maybe Text
    , opError :: Maybe Text
    , opDispatchedBy :: Text
    , opDispatchedAt :: UTCTime
    , opUpdatedAt :: UTCTime
    }
    deriving (Show, Generic)

data OtaLink = OtaLink
    { olId :: Text
    , olPushId :: Text
    , olAirborneAppRef :: Text
    , olAirborneReleaseId :: Text
    , olPackageVersion :: Int
    , olDimensions :: Maybe Value
    , olCreatedBy :: Text
    , olCreatedAt :: UTCTime
    , olGroupId :: Text
    , olGroupLabel :: Maybe Text
    , olSourceRef :: Text
    }
    deriving (Show, Generic)

-- ─── Wire responses ────────────────────────────────────────────────

data OtaPushResp = OtaPushResp
    { id :: Text
    , appName :: Text
    , platform :: Text
    , airborneAppRef :: Text
    , env :: Text
    , status :: Text
    , requestedBump :: Text
    , sourceRef :: Text
    , externalRunId :: Maybe Int64
    , runUrl :: Maybe Text
    , commitSha :: Maybe Text
    , finalVersion :: Maybe Text
    , packageVersion :: Maybe Int
    , resolvedVia :: Maybe Text
    , error :: Maybe Text
    , dispatchedBy :: Text
    , dispatchedAt :: UTCTime
    , updatedAt :: UTCTime
    }
    deriving (Show, Generic)

instance ToJSON OtaPushResp where
    toJSON = genericToJSON defaultOptions{omitNothingFields = True}

data OtaLinkResp = OtaLinkResp
    { linkId :: Text
    , airborneAppRef :: Text
    , airborneReleaseId :: Text
    , packageVersion :: Int
    , dimensions :: Maybe Value
    , createdBy :: Text
    , createdAt :: UTCTime
    , groupId :: Text
    , groupLabel :: Maybe Text
    , sourceRef :: Text
    }
    deriving (Show, Generic)

instance ToJSON OtaLinkResp where
    toJSON = genericToJSON defaultOptions{omitNothingFields = True}

-- | One step inside a CI job (checkout, build, upload …).
data OtaRunStep = OtaRunStep
    { name :: Text
    , status :: Text
    , conclusion :: Maybe Text
    , startedAt :: Maybe UTCTime
    , completedAt :: Maybe UTCTime
    }
    deriving (Show, Generic)

instance ToJSON OtaRunStep where
    toJSON = genericToJSON defaultOptions{omitNothingFields = True}

-- | One CI job of a push's workflow run — the inline "run matrix" view.
data OtaRunJob = OtaRunJob
    { name :: Text
    , status :: Text
    , conclusion :: Maybe Text
    , htmlUrl :: Text
    , startedAt :: Maybe UTCTime
    , completedAt :: Maybe UTCTime
    , steps :: [OtaRunStep]
    }
    deriving (Show, Generic)

instance ToJSON OtaRunJob where
    toJSON = genericToJSON defaultOptions{omitNothingFields = True}

newtype OtaRunJobsResp = OtaRunJobsResp {jobs :: [OtaRunJob]}
    deriving (Show, Generic)

instance ToJSON OtaRunJobsResp

data OtaCapableApp = OtaCapableApp
    { appName :: Text
    , platform :: Text
    , airborneAppRef :: Text
    , pushEligible :: Bool
    , ineligibleReason :: Maybe Text
    , superseded :: Bool
    -- ^ build was replaced on the store — the composer nudges version
    -- targeting so straggler hotfixes don't serve newer natives untargeted
    , releaseBlocked :: Maybe Text
    -- ^ Just reason when the native build's state (draft \/ building \/
    -- discarded \/ failed) forbids CREATING pushes\/releases from it. Operate
    -- verbs on ongoing releases stay allowed.
    }
    deriving (Show, Generic)

instance ToJSON OtaCapableApp where
    toJSON = genericToJSON defaultOptions{omitNothingFields = True}

-- | The globally-active push batch (Decision D) — who is blocking dispatch.
data OtaActivePush = OtaActivePush
    { groupId :: Text
    , dispatchedBy :: Text
    , dispatchedAt :: UTCTime
    }
    deriving (Show, Generic)

instance ToJSON OtaActivePush where
    toJSON = genericToJSON defaultOptions{omitNothingFields = True}

data OtaGroupResp = OtaGroupResp
    { available :: Bool
    , groupSourceRef :: Maybe Text
    , activePush :: Maybe OtaActivePush
    , rows :: [OtaPushResp]
    , links :: [OtaLinkResp]
    , capableApps :: [OtaCapableApp]
    }
    deriving (Show, Generic)

instance ToJSON OtaGroupResp where
    toJSON = genericToJSON defaultOptions{omitNothingFields = True}

-- ─── Requests ──────────────────────────────────────────────────────

data OtaDispatchReq = OtaDispatchReq
    { versionBump :: Text
    , apps :: Maybe [Text]
    , platforms :: Maybe [Text]
    , notifySlack :: Maybe Bool
    , runner :: Maybe Text
    -- ^ CI runner pool; absent/empty = "ios-debug". GH validates against
    -- the workflow's choice options.
    }
    deriving (Show, Generic)

instance FromJSON OtaDispatchReq

data OtaDispatchResp = OtaDispatchResp
    { dispatched :: Int
    , rows :: [OtaPushResp]
    }
    deriving (Show, Generic)

instance ToJSON OtaDispatchResp where
    toJSON = genericToJSON defaultOptions{omitNothingFields = True}

data OtaReleaseConfig = OtaReleaseConfig
    { bootTimeout :: Maybe Int
    , releaseConfigTimeout :: Maybe Int
    , properties :: Maybe Value
    }
    deriving (Show, Generic)

instance FromJSON OtaReleaseConfig

data OtaReleaseReq = OtaReleaseReq
    { dimensions :: Maybe (Map Text Value)
    , initialTrafficPercent :: Maybe Int
    , config :: Maybe OtaReleaseConfig
    , lazyFiles :: Maybe [Text]
    }
    deriving (Show, Generic)

instance FromJSON OtaReleaseReq

data OtaReleaseResp = OtaReleaseResp
    { released :: Bool
    , ramped :: Bool
    , airborneReleaseId :: Text
    , link :: OtaLinkResp
    , firstRelease :: Maybe Bool
    }
    deriving (Show, Generic)

instance ToJSON OtaReleaseResp where
    toJSON = genericToJSON defaultOptions{omitNothingFields = True}

{- | One CREATED|INPROGRESS upstream release, as surfaced in the SCC 409
conflict payload. @link@ resolves globally when the release is SCC-created.
-}
data OtaOngoingRelease = OtaOngoingRelease
    { airborneReleaseId :: Text
    , status :: Text
    , packageVersion :: Maybe Int
    , trafficPercentage :: Maybe Int
    , dimensions :: Maybe Value
    , link :: Maybe OtaLinkResp
    }
    deriving (Show, Generic)

instance ToJSON OtaOngoingRelease where
    toJSON = genericToJSON defaultOptions{omitNothingFields = True}

newtype OtaAttachReq = OtaAttachReq
    { packageVersion :: Int
    }
    deriving (Show, Generic)

instance FromJSON OtaAttachReq

-- | Package-born release request (no push row) — lineage-gated server-side.
data OtaPackageReleaseReq = OtaPackageReleaseReq
    { airborneAppRef :: Text
    , packageVersion :: Int
    , packageTag :: Maybe Text -- catalyst version string, for tag-ledger lookup
    , dimensions :: Maybe (Map Text Value)
    , initialTrafficPercent :: Maybe Int
    , config :: Maybe OtaReleaseConfig
    , lazyFiles :: Maybe [Text]
    }
    deriving (Show, Generic)

instance FromJSON OtaPackageReleaseReq

-- ─── Provenance (git-tag ledger, doc §11b) ─────────────────────────

data OtaProvPkgReq = OtaProvPkgReq
    { version :: Int
    , tag :: Maybe Text -- airborne package tag (the catalyst version string)
    }
    deriving (Show, Generic)

instance FromJSON OtaProvPkgReq

data OtaProvReq = OtaProvReq
    { airborneAppRef :: Text
    , packages :: [OtaProvPkgReq]
    }
    deriving (Show, Generic)

instance FromJSON OtaProvReq

-- | The build anchor: the commit this group's native build was cut from.
-- resolvedVia: scc (row already carried it) | native-tag (recovered from the
-- build tag ledger — store-sync rows) | none.
data OtaProvAnchor = OtaProvAnchor
    { commitSha :: Maybe Text
    , sourceRef :: Maybe Text
    , resolvedVia :: Text
    }
    deriving (Show, Generic)

instance ToJSON OtaProvAnchor where
    toJSON = genericToJSON defaultOptions{omitNothingFields = True}

-- | relation: identical | ahead | behind | diverged | unknown — the git
-- ancestry of the package's commit relative to the anchor.
data OtaProvPkgResp = OtaProvPkgResp
    { packageVersion :: Int
    , commitSha :: Maybe Text
    , repoTag :: Maybe Text
    , relation :: Text
    , aheadBy :: Maybe Int
    , behindBy :: Maybe Int
    }
    deriving (Show, Generic)

instance ToJSON OtaProvPkgResp where
    toJSON = genericToJSON defaultOptions{omitNothingFields = True}

data OtaProvResp = OtaProvResp
    { anchor :: OtaProvAnchor
    , packages :: [OtaProvPkgResp]
    }
    deriving (Show, Generic)

instance ToJSON OtaProvResp where
    toJSON = genericToJSON defaultOptions{omitNothingFields = True}

data OtaAdoptBranchReq = OtaAdoptBranchReq
    { airborneAppRef :: Text
    , branch :: Text
    , acknowledgeMismatch :: Maybe Bool
    -- ^ True = the user saw the "branch does not contain the build commit"
    -- warning and adopted anyway (legit after a squash-merge, where the
    -- original sha survives on no branch).
    }
    deriving (Show, Generic)

instance FromJSON OtaAdoptBranchReq

-- ─── Row → wire conversions ────────────────────────────────────────

-- | @runsBase@ = "https:\/\/github.com\/\<owner\>\/\<repo\>\/actions\/runs".
pushToResp :: Maybe Text -> OtaPush -> OtaPushResp
pushToResp runsBase p =
    OtaPushResp
        { id = opId p
        , appName = opAppName p
        , platform = opPlatform p
        , airborneAppRef = opAirborneAppRef p
        , env = opEnv p
        , status = opStatus p
        , requestedBump = opRequestedBump p
        , sourceRef = opSourceRef p
        , externalRunId = opExternalRunId p
        , runUrl = do
            base <- runsBase
            rid <- opExternalRunId p
            pure (base <> "/" <> T.pack (show rid))
        , commitSha = opCommitSha p
        , finalVersion = opFinalVersion p
        , packageVersion = opPackageVersion p
        , resolvedVia = opResolvedVia p
        , error = opError p
        , dispatchedBy = opDispatchedBy p
        , dispatchedAt = opDispatchedAt p
        , updatedAt = opUpdatedAt p
        }

linkToResp :: OtaLink -> OtaLinkResp
linkToResp l =
    OtaLinkResp
        { linkId = olId l
        , airborneAppRef = olAirborneAppRef l
        , airborneReleaseId = olAirborneReleaseId l
        , packageVersion = olPackageVersion l
        , dimensions = olDimensions l
        , createdBy = olCreatedBy l
        , createdAt = olCreatedAt l
        , groupId = olGroupId l
        , groupLabel = olGroupLabel l
        , sourceRef = olSourceRef l
        }
