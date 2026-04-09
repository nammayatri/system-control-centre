{- | Deployment-target-agnostic workflow types: 'ReleaseCategory' (what
kind of release) and 'ReleaseWFStatus' (generic lifecycle stages).
-}
module Products.Autopilot.Types.Workflow (
    -- * Release Category
    ReleaseCategory (..),
    getDefaultDeploymentTarget,

    -- * Generic Workflow Stages
    ReleaseWFStatus (..),
)
where

import Data.Aeson (FromJSON, ToJSON)
import Data.Text (Text)
import GHC.Generics (Generic)

-- | Release category — selects workflow and target-state type.
data ReleaseCategory
    = -- | Backend microservices (REST / gRPC).
      BackendService
    | -- | Backend scheduled jobs (no VS/DR).
      BackendScheduler
    | -- | ConfigMap / Secret updates.
      BackendConfig
    | -- | VirtualService edits (lock/unlock/apply/revert).
      VSEdit
    deriving (Eq, Show, Read, Generic, Ord)

instance ToJSON ReleaseCategory

instance FromJSON ReleaseCategory

getDefaultDeploymentTarget :: ReleaseCategory -> Text
getDefaultDeploymentTarget BackendService = "kubernetes"
getDefaultDeploymentTarget BackendScheduler = "kubernetes"
getDefaultDeploymentTarget BackendConfig = "kubernetes-config"
getDefaultDeploymentTarget VSEdit = "kubernetes"

{- | Generic release workflow stages. Category-specific sub-stages live
in @targetState@.

@INIT → PREPARING → DEPLOYING → MONITORING → FINALIZING → DONE@, with
@ROLLING_BACK@ as the error branch.
-}
data ReleaseWFStatus
    = INIT
    | PREPARING
    | DEPLOYING
    | MONITORING
    | FINALIZING
    | DONE
    | ROLLING_BACK
    deriving (Eq, Show, Read, Generic, Ord)

instance ToJSON ReleaseWFStatus

instance FromJSON ReleaseWFStatus
