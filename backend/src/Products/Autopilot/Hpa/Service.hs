{-# LANGUAGE OverloadedStrings #-}

{- | Everything the scheduler needs to know about a service that lives in the
shared @deployment_config@ table: its namespace, VirtualService, host, and the
other hosts in the product (to keep @foo@ from claiming @foo-bar@'s HPAs).
Also the one question the scheduler must ask the release flow: is a release
running for this service right now?
-}
module Products.Autopilot.Hpa.Service (
    ServiceCtx (..),
    loadServiceCtx,
    loadServiceCtxs,
    loadGuardrail,
    releaseConflict,
)
where

import Core.Environment (MonadFlow)
import Products.Autopilot.Hpa.Store (getGuardrailRow)
import Products.Autopilot.Hpa.Types (Guardrail, defaultGuardrail)
import Products.Autopilot.Hpa.Util (decodeValue)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Products.Autopilot.Queries.ProductService (
    findProductByName,
    findServiceByProductAndName,
    getHpaMaxReplicas,
    getHpaMinReplicas,
    getProductNamespace,
    getProductVsName,
    getServiceHost,
    listReleaseConfigByProduct,
 )
import Products.Autopilot.Queries.ReleaseTracker (findActiveTrackersForService)
import Products.Autopilot.Types.Release qualified as R
import Products.Autopilot.Types.Storage.Schema qualified as S

data ServiceCtx = ServiceCtx
    { scAppGroup :: Text
    , scService :: Text
    , scHost :: Text
    -- ^ Deployment name prefix: @<host>-<version>@.
    , scNamespace :: Text
    , scVsName :: Text
    , scOtherHosts :: [Text]
    , scBaselineMin :: Int
    , scBaselineMax :: Int
    -- ^ The release-time HPA bounds in @deployment_config@ (what a new release starts from).
    }
    deriving (Show)

-- | 'Nothing' when the product or service is not configured (any more).
loadServiceCtx :: (MonadFlow m) => Text -> Text -> m (Maybe ServiceCtx)
loadServiceCtx app svc = do
    mProduct <- findProductByName app
    mSvc <- findServiceByProductAndName app svc
    case (mProduct, mSvc) of
        (Just p, Just s) -> do
            siblings <- listReleaseConfigByProduct app
            pure . Just $
                ServiceCtx
                    { scAppGroup = app
                    , scService = svc
                    , scHost = fromMaybe svc (getServiceHost s)
                    , scNamespace = getProductNamespace p
                    , scVsName = getProductVsName p
                    , scOtherHosts = [h | x <- siblings, Just h <- [getServiceHost x]]
                    , scBaselineMin = fromIntegral (getHpaMinReplicas s)
                    , scBaselineMax = fromIntegral (getHpaMaxReplicas s)
                    }
        _ -> pure Nothing

{- | Contexts for several services of one product, reading the product's service list once
(the per-service version re-reads it every call, which is quadratic for a whole product).
-}
loadServiceCtxs :: (MonadFlow m) => Text -> [Text] -> m [ServiceCtx]
loadServiceCtxs app svcs = do
    mProduct <- findProductByName app
    siblings <- listReleaseConfigByProduct app
    let hosts = [h | x <- siblings, Just h <- [getServiceHost x]]
    pure $ case mProduct of
        Nothing -> []
        Just p ->
            [ ServiceCtx
                { scAppGroup = app
                , scService = svc
                , scHost = fromMaybe svc (getServiceHost s)
                , scNamespace = getProductNamespace p
                , scVsName = getProductVsName p
                , scOtherHosts = hosts
                , scBaselineMin = fromIntegral (getHpaMinReplicas s)
                , scBaselineMax = fromIntegral (getHpaMaxReplicas s)
                }
            | svc <- svcs
            , s <- siblings
            , S.dcService s == Just svc
            ]

-- | The service's guardrail, or the permissive default when none is stored (or it cannot be read).
loadGuardrail :: (MonadFlow m) => Text -> Text -> Text -> m Guardrail
loadGuardrail cloud app svc = do
    mv <- getGuardrailRow cloud app svc
    pure (fromMaybe defaultGuardrail (mv >>= either (const Nothing) Just . decodeValue))

{- | Why the scheduler must not touch this service's HPAs right now, if a release
is in flight for it. Applies are deferred behind this, and so are restores: a
capacity cut in the middle of a rollout is the one thing worse than leaving
extra capacity for a while.
-}
releaseConflict :: (MonadFlow m) => Text -> Text -> m (Maybe Text)
releaseConflict app svc = do
    active <- findActiveTrackersForService app svc
    pure $ case active of
        [] -> Nothing
        ((rt, _) : _) -> Just ("release " <> R.releaseId rt <> " is " <> T.pack (show (R.status rt)))
