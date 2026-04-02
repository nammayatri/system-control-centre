{-# LANGUAGE OverloadedStrings #-}

module Shared.Queries.ServerConfig
  ( getEnabledServerConfigValue,
    listAllServerConfigs,
    upsertServerConfig,
  )
where

-- Re-export from the original module
import Products.Autopilot.Queries.ServerConfig
