{-# LANGUAGE OverloadedStrings #-}

module NammaAP.Shared.Queries.ServerConfig
  ( getEnabledServerConfigValue
  , listAllServerConfigs
  , upsertServerConfig
  ) where

-- Re-export from the original module
import NammaAP.Products.Autopilot.Queries.ServerConfig
