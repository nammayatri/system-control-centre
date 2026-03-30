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
)
where

import Products.Autopilot.K8s.Deployment
import Products.Autopilot.K8s.DestinationRule
import Products.Autopilot.K8s.Execute
import Products.Autopilot.K8s.HPA
import Products.Autopilot.K8s.VirtualService
