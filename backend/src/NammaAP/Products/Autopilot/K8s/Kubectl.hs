{-# LANGUAGE OverloadedStrings #-}

-- | Re-exports all K8s operations for backwards compatibility.
-- Prefer importing specific modules: K8s.Execute, K8s.Deployment, K8s.VirtualService,
-- K8s.DestinationRule, K8s.HPA.
module NammaAP.Products.Autopilot.K8s.Kubectl
  ( module NammaAP.Products.Autopilot.K8s.Execute
  , module NammaAP.Products.Autopilot.K8s.Deployment
  , module NammaAP.Products.Autopilot.K8s.VirtualService
  , module NammaAP.Products.Autopilot.K8s.DestinationRule
  , module NammaAP.Products.Autopilot.K8s.HPA
  ) where

import NammaAP.Products.Autopilot.K8s.Execute
import NammaAP.Products.Autopilot.K8s.Deployment
import NammaAP.Products.Autopilot.K8s.VirtualService
import NammaAP.Products.Autopilot.K8s.DestinationRule
import NammaAP.Products.Autopilot.K8s.HPA
