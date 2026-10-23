{- | Devbox Releases: rows of the 0055 tables and the shapes around them.

A release is one set of feature branches (backend + control-center, and
optionally the apps) running on a fleet dev-box. Status words are the ones
the table's CHECK constraints allow; the list page's filter chips map onto
them through 'statusFilterStatuses'.
-}
module Products.Devbox.Types (
    DevboxRelease (..),
    DevboxEvent (..),
    DevboxBuild (..),
    NewRelease (..),
    CreateError (..),
    StatusFilter (..),
    textToStatusFilter,
    statusFilterStatuses,
    activeStatuses,
    FilterCounts (..),
    appBuildSpecs,
)
where

import Data.Aeson (ToJSON (..), Value, object, (.=))
import Data.Int (Int64)
import Data.Text (Text)
import Data.Time (UTCTime)
import Database.PostgreSQL.Simple.FromRow (FromRow (..), field)
import Database.PostgreSQL.Simple.Types (PGArray (..))

-- | One row of @devbox_release@ (columns in table order).
data DevboxRelease = DevboxRelease
    { drId :: Text
    , drWorkspace :: Text
    , drStatus :: Text
    , drStage :: Text
    , drCurrentAction :: Text
    , drBackendBranch :: Text
    , drBackendSha :: Text
    , drCcBranch :: Maybe Text
    , drCcSha :: Maybe Text
    , drFrontendBranch :: Maybe Text
    , drFrontendSha :: Maybe Text
    , drBuildAndroid :: Bool
    , drBuildIos :: Bool
    , drDataSource :: Text
    , drDataVersion :: Maybe Text
    , drDevboxName :: Maybe Text
    , drDevboxHost :: Maybe Text
    , drDevboxUser :: Maybe Text
    , drBackendUrl :: Maybe Text
    , drCcUrl :: Maybe Text
    , drGhRunId :: Maybe Int64
    , drGhRunUrl :: Maybe Text
    , drError :: Maybe Text
    , drCreatedBy :: Text
    , drStoppedBy :: Maybe Text
    , drStopReason :: Maybe Text
    , drCreatedAt :: UTCTime
    , drUpdatedAt :: UTCTime
    , drReadyAt :: Maybe UTCTime
    , drExpiresAt :: UTCTime
    , drStoppedAt :: Maybe UTCTime
    , drAppBuilds :: [Text]
    -- ^ app builds asked for, as 'app:platform' (rider:android, driver:ios, …)
    }
    deriving (Show)

instance FromRow DevboxRelease where
    fromRow =
        DevboxRelease
            <$> field <*> field <*> field <*> field <*> field
            <*> field <*> field <*> field <*> field <*> field
            <*> field <*> field <*> field <*> field <*> field
            <*> field <*> field <*> field <*> field <*> field
            <*> field <*> field <*> field <*> field <*> field
            <*> field <*> field <*> field <*> field <*> field
            <*> field
            <*> (fromPGArray <$> field)

instance ToJSON DevboxRelease where
    toJSON r =
        object
            [ "id" .= drId r
            , "workspace" .= drWorkspace r
            , "status" .= drStatus r
            , "stage" .= drStage r
            , "currentAction" .= drCurrentAction r
            , "backendBranch" .= drBackendBranch r
            , "backendSha" .= drBackendSha r
            , "ccBranch" .= drCcBranch r
            , "ccSha" .= drCcSha r
            , "frontendBranch" .= drFrontendBranch r
            , "frontendSha" .= drFrontendSha r
            , "buildAndroid" .= drBuildAndroid r
            , "buildIos" .= drBuildIos r
            , "dataSource" .= drDataSource r
            , "dataVersion" .= drDataVersion r
            , "devboxName" .= drDevboxName r
            , "devboxHost" .= drDevboxHost r
            , "devboxUser" .= drDevboxUser r
            , "backendUrl" .= drBackendUrl r
            , "ccUrl" .= drCcUrl r
            , "ghRunId" .= drGhRunId r
            , "ghRunUrl" .= drGhRunUrl r
            , "error" .= drError r
            , "createdBy" .= drCreatedBy r
            , "stoppedBy" .= drStoppedBy r
            , "stopReason" .= drStopReason r
            , "createdAt" .= drCreatedAt r
            , "updatedAt" .= drUpdatedAt r
            , "readyAt" .= drReadyAt r
            , "expiresAt" .= drExpiresAt r
            , "stoppedAt" .= drStoppedAt r
            , "appBuilds" .= drAppBuilds r
            ]

-- | One row of @devbox_release_event@: a stage started / done / failed, a stop, an expiry.
data DevboxEvent = DevboxEvent
    { deId :: Int64
    , deReleaseId :: Text
    , deStage :: Text
    , deLabel :: Text
    , dePayload :: Value
    , deGhStepUrl :: Maybe Text
    , deCreatedAt :: UTCTime
    }
    deriving (Show)

instance FromRow DevboxEvent where
    fromRow = DevboxEvent <$> field <*> field <*> field <*> field <*> field <*> field <*> field

instance ToJSON DevboxEvent where
    toJSON e =
        object
            [ "id" .= deId e
            , "releaseId" .= deReleaseId e
            , "stage" .= deStage e
            , "label" .= deLabel e
            , "payload" .= dePayload e
            , "ghStepUrl" .= deGhStepUrl e
            , "createdAt" .= deCreatedAt e
            ]

-- | One row of @devbox_release_build@: an Android or iOS app build for a release.
data DevboxBuild = DevboxBuild
    { dbId :: Int64
    , dbReleaseId :: Text
    , dbPlatform :: Text
    , dbStatus :: Text
    , dbGhRunId :: Maybe Int64
    , dbGhRunUrl :: Maybe Text
    , dbDownloadUrl :: Maybe Text
    , dbBuildNumber :: Maybe Text
    , dbError :: Maybe Text
    , dbCreatedAt :: UTCTime
    , dbUpdatedAt :: UTCTime
    , dbApp :: Text
    -- ^ rider | driver
    }
    deriving (Show)

instance FromRow DevboxBuild where
    fromRow =
        DevboxBuild
            <$> field <*> field <*> field <*> field <*> field <*> field
            <*> field <*> field <*> field <*> field <*> field <*> field

instance ToJSON DevboxBuild where
    toJSON b =
        object
            [ "id" .= dbId b
            , "releaseId" .= dbReleaseId b
            , "platform" .= dbPlatform b
            , "status" .= dbStatus b
            , "ghRunId" .= dbGhRunId b
            , "ghRunUrl" .= dbGhRunUrl b
            , "downloadUrl" .= dbDownloadUrl b
            , "buildNumber" .= dbBuildNumber b
            , "error" .= dbError b
            , "createdAt" .= dbCreatedAt b
            , "updatedAt" .= dbUpdatedAt b
            , "app" .= dbApp b
            ]

{- | What the create handler hands to 'Products.Devbox.Queries.createRelease':
the validated form, with each branch already pinned to a commit.
-}
data NewRelease = NewRelease
    { nrId :: Text
    , nrWorkspace :: Text
    , nrBackendBranch :: Text
    , nrBackendSha :: Text
    , nrCcBranch :: Maybe Text
    , nrCcSha :: Maybe Text
    , nrFrontendBranch :: Maybe Text
    , nrFrontendSha :: Maybe Text
    , nrBuildAndroid :: Bool
    , nrBuildIos :: Bool
    , nrDataSource :: Text
    , nrDataVersion :: Maybe Text
    , nrCreatedBy :: Text
    , nrAppBuilds :: [Text]
    }
    deriving (Show)

-- | Why a release was not created. The active ones are returned so the page can link to them.
data CreateError
    = -- | the creator already has this many active releases (the limit)
      TooManyActive Int
    | -- | this backend branch already has an active release
      BranchActive DevboxRelease
    | -- | this workspace name is used by an active release
      WorkspaceActive DevboxRelease
    deriving (Show)

-- | The list page's filter chips.
data StatusFilter = FilterAll | FilterRunning | FilterInProgress | FilterStopped
    deriving (Show, Eq, Enum, Bounded)

textToStatusFilter :: Text -> Maybe StatusFilter
textToStatusFilter "all" = Just FilterAll
textToStatusFilter "running" = Just FilterRunning
textToStatusFilter "in_progress" = Just FilterInProgress
textToStatusFilter "stopped" = Just FilterStopped
textToStatusFilter _ = Nothing

-- | The statuses a chip shows; Nothing = every status.
statusFilterStatuses :: StatusFilter -> Maybe [Text]
statusFilterStatuses FilterAll = Nothing
statusFilterStatuses FilterRunning = Just ["READY"]
statusFilterStatuses FilterInProgress = Just ["QUEUED", "RUNNING", "STOPPING"]
statusFilterStatuses FilterStopped = Just ["STOPPED", "FAILED"]

-- | A release that still holds its workspace (and counts towards the per-person limit).
activeStatuses :: [Text]
activeStatuses = ["QUEUED", "RUNNING", "READY", "STOPPING"]

-- | The number on each filter chip.
data FilterCounts = FilterCounts
    { fcAll :: Int64
    , fcRunning :: Int64
    , fcInProgress :: Int64
    , fcStopped :: Int64
    }
    deriving (Show)

instance FromRow FilterCounts where
    fromRow = FilterCounts <$> field <*> field <*> field <*> field

instance ToJSON FilterCounts where
    toJSON c =
        object
            [ "all" .= fcAll c
            , "running" .= fcRunning c
            , "inProgress" .= fcInProgress c
            , "stopped" .= fcStopped c
            ]

-- | The app builds a release may ask for, as stored in @app_builds@.
appBuildSpecs :: [Text]
appBuildSpecs = ["rider:android", "driver:android", "rider:ios", "driver:ios"]
