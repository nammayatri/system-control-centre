{-# LANGUAGE OverloadedStrings #-}

{- | Re-exports all K8s operations for backwards compatibility.
Prefer importing specific modules: K8s.Execute, K8s.Deployment, K8s.VirtualService,
K8s.DestinationRule, K8s.HPA.
-}
module Products.Autopilot.K8s.Kubectl (
    module Products.Autopilot.K8s.Execute,
    module Products.Autopilot.K8s.Deployment,
    module Products.Autopilot.K8s.VirtualService,
    module Products.Autopilot.K8s.DestinationRule,
    module Products.Autopilot.K8s.HPA,
    runningVersionFromK8s,
)
where

import Core.Config (Config)
import Data.Text (Text)
import Products.Autopilot.K8s.Deployment
import Products.Autopilot.K8s.DestinationRule
import Products.Autopilot.K8s.Execute
import Products.Autopilot.K8s.HPA
import Products.Autopilot.K8s.VirtualService

{- | The currently-deployed version for a service, as used to seed a release's
old version. For normal services this is the highest-weight VirtualService
subset; for schedulers (which have no VS) it's the deployment with the most
ready replicas. Returns Nothing on any miss or k8s error — callers treat that
as "unknown" and fall back to their own defaulting.

Shared by the create-release handler and the running-version endpoint so the
resolution logic lives in exactly one place.
-}
runningVersionFromK8s :: Config -> Text -> Text -> Text -> Bool -> IO (Maybe Text)
runningVersionFromK8s cfg ns vsName svcHost isScheduler = do
    res <-
        if isScheduler
            then getRunningSchedulerVersion cfg ns svcHost
            else getPrimarySubsetFromVirtualService cfg ns vsName svcHost
    pure (either (const Nothing) id res)
