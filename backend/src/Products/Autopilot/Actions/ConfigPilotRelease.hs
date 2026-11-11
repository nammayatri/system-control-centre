{-# LANGUAGE DataKinds #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}

module Products.Autopilot.Actions.ConfigPilotRelease
  ( CreateConfigReleaseReq (..),
    createConfigReleaseH,
  )
where

import Control.Monad.Catch (onException, throwM)
import Control.Monad.IO.Class (liftIO)
import Core.AppError (APIError (..))
import Core.Secrets (lookupEnvSecret)
import Core.Environment (Flow, logInfo)
import Data.Aeson (FromJSON (..), ToJSON (..), genericParseJSON, genericToJSON, toJSON)
import Data.Aeson qualified as A
import Data.Char (toLower)
import Data.List (nub, sort)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time.Clock (getCurrentTime)
import Data.Time.Format (defaultTimeLocale, formatTime)
import Data.UUID qualified as UUID
import Data.UUID.V4 qualified as UUID
import GHC.Generics (Generic)
import Products.Autopilot.Actions.Release (insertReleaseTrackerSafe)
import Products.Autopilot.ConfigPilot.Client (ConfigPilotItem (..), ConfigPilotMeta (..), ConfigSide (..))
import Products.Autopilot.Notifications (notifyReleaseCreated)
import Products.Autopilot.Queries.ProductService
  ( claimServiceForModification,
    findProductByName,
    findServiceByProductAndName,
    getProductCluster,
    releaseService,
  )
import Products.Autopilot.Queries.ReleaseTracker (insertReleaseEvent)
import Products.Autopilot.RuntimeConfig (isUnderMaintenance)
import Products.Autopilot.Types.Release
  ( Mode (..),
    ReleaseStatus (..),
    ReleaseTracker (..),
    RolloutStep (..),
  )
import Products.Autopilot.Types.Target (TargetState (..), emptyConfigState)
import Products.Autopilot.Types.Workflow (ReleaseCategory (..), ReleaseWFStatus (..))
import Shared.API.Response (APIResponse (..))
import Prelude

data CreateConfigReleaseReq = CreateConfigReleaseReq
  { ccrAppGroup :: Text,
    ccrService :: Text,
    ccrEnv :: Text,
    ccrSide :: ConfigSide,
    ccrMerchantShortId :: Text,
    ccrCity :: Text,
    ccrItems :: [ConfigPilotItem],
    ccrRolloutStrategy :: [RolloutStep],
    ccrMode :: Maybe Text,
    ccrDescription :: Maybe Text
  }
  deriving (Show, Generic)

jsonOpts :: A.Options
jsonOpts = A.defaultOptions {A.fieldLabelModifier = lowerFirst . drop 3}
  where
    lowerFirst (c : cs) = toLower c : cs
    lowerFirst [] = []

instance FromJSON CreateConfigReleaseReq where
  parseJSON = genericParseJSON jsonOpts

instance ToJSON CreateConfigReleaseReq where
  toJSON = genericToJSON jsonOpts

validateRequest :: CreateConfigReleaseReq -> Maybe Text
validateRequest req
  | null (ccrItems req) = Just "At least one config item is required"
  | any (\i -> version i <= 0 || T.null (T.strip (configType i))) (ccrItems req) = Just "Every item needs a configType and a positive version"
  | length (nub (map configType (ccrItems req))) /= length (ccrItems req) = Just "A config type can appear only once in a release"
  | null steps = Just "rolloutStrategy is empty"
  | any (\p -> p < 1 || p > 100) percents = Just "Rollout percentages must be between 1 and 100"
  | percents /= sort (nub percents) = Just "Rollout percentages must be strictly increasing"
  | last percents /= 100 = Just "The last rollout step must be 100"
  | any ((< 0) . cooloffMinutes) steps = Just "cooloffMinutes cannot be negative"
  | T.null (T.strip (ccrMerchantShortId req)) || T.null (T.strip (ccrCity req)) = Just "merchantShortId and city are required"
  | otherwise = Nothing
  where
    steps = ccrRolloutStrategy req
    percents = map rolloutPercent steps

createConfigReleaseH :: Maybe Text -> CreateConfigReleaseReq -> Flow APIResponse
createConfigReleaseH mKey req = do
  expected <- lookupEnvSecret "SC_CONFIGPILOT_API_KEY"
  case (expected, mKey) of
    (Just e, Just k) | e == k -> createAuthorised req
    _ -> throwM (Forbidden "Invalid or missing ConfigPilot key")

createAuthorised :: CreateConfigReleaseReq -> Flow APIResponse
createAuthorised req = do
  case validateRequest req of
    Just err -> pure $ APIResponse "ERROR" err
    Nothing -> do
      maintenance <- isUnderMaintenance
      mP <- findProductByName (ccrAppGroup req)
      mS <- findServiceByProductAndName (ccrAppGroup req) (ccrService req)
      case (maintenance, mP, mS) of
        (True, _, _) -> pure $ APIResponse "ERROR" "System is under maintenance. Release creation is disabled."
        (_, Nothing, _) -> pure $ APIResponse "ERROR" "Product not configured"
        (_, _, Nothing) -> pure $ APIResponse "ERROR" "Service not configured for product"
        (_, Just pCfg, Just _) -> do
          claimed <- claimServiceForModification (ccrAppGroup req) (ccrService req)
          if not claimed
            then pure $ APIResponse "ERROR" ("Service " <> ccrService req <> " in app group " <> ccrAppGroup req <> " already has a release in progress")
            else do
              rid <- liftIO (UUID.toText <$> UUID.nextRandom)
              now <- liftIO getCurrentTime
              let meta =
                    ConfigPilotMeta
                      { side = ccrSide req,
                        merchantShortId = ccrMerchantShortId req,
                        city = ccrCity req,
                        items = ccrItems req
                      }
                  reqMode = if fmap T.toUpper (ccrMode req) == Just "MANUAL" then MANUAL else AUTO
                  datePart = T.pack (formatTime defaultTimeLocale "%Y%m%d" now)
                  tracker =
                    ReleaseTracker
                      { releaseId = rid,
                        appGroup = ccrAppGroup req,
                        service = ccrService req,
                        env = ccrEnv req,
                        category = ConfigPilot,
                        status = CREATED,
                        releaseWFStatus = INIT,
                        mode = reqMode,
                        createdBy = "control-center",
                        approvedBy = Nothing,
                        isApproved = False,
                        isInfraApproved = True,
                        releaseTag = Just (T.intercalate "_" [ccrAppGroup req, datePart, "config", ccrService req, ccrEnv req]),
                        scheduleTime = Nothing,
                        dateCreated = Nothing,
                        lastUpdated = Nothing,
                        startTime = Nothing,
                        endTime = Nothing,
                        rolloutStrategy = ccrRolloutStrategy req,
                        rolloutHistory = [],
                        oldVersion = "base",
                        newVersion = rid,
                        versionCode = Nothing,
                        reviewStatus = Nothing,
                        info = Nothing,
                        description = ccrDescription req,
                        changeLog = Nothing,
                        metadata = Just (toJSON meta),
                        priority = 0,
                        globalId = Nothing,
                        syncEnabled = Nothing,
                        envOverrideData = Nothing,
                        slackThreadTs = Nothing,
                        releaseContext = Just (A.object ["cluster" A..= getProductCluster pCfg]),
                        sourceRef = Nothing,
                        commitSha = Nothing,
                        revertsReleaseId = Nothing,
                        abValidationStatus = Nothing,
                        abValidation = Nothing
                      }
              _ <- insertReleaseTrackerSafe tracker (ConfigState emptyConfigState) `onException` releaseService (ccrAppGroup req) (ccrService req)
              insertReleaseEvent rid "BUSINESS" "TRACKER_CREATED" (toJSON tracker)
              notifyReleaseCreated tracker
              logInfo $ "[configPilot] created release " <> rid
              pure $ APIResponse "SUCCESS" ("Tracker created: " <> rid)
