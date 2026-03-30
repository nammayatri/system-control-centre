{-# LANGUAGE OverloadedStrings #-}

-- | Re-exports all K8s operations for backwards compatibility.
-- Prefer importing specific modules: K8s.Execute, K8s.Deployment, K8s.VirtualService,
-- K8s.DestinationRule, K8s.HPA.
module NammaAP.K8s.Kubectl
  ( module NammaAP.K8s.Execute
  , module NammaAP.K8s.Deployment
  , module NammaAP.K8s.VirtualService
  , module NammaAP.K8s.DestinationRule
  , module NammaAP.K8s.HPA
  ) where

import NammaAP.K8s.Execute
import NammaAP.K8s.Deployment
import NammaAP.K8s.VirtualService
import NammaAP.K8s.DestinationRule
import NammaAP.K8s.HPA
