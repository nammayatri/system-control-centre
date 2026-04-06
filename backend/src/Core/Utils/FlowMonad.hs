-- | Backwards-compatible re-export for existing handlers.
--
-- Existing handlers: @import Core.Utils.FlowMonad@
-- New handlers:      @import Core.AppM@ + @import Core.AppError@
module Core.Utils.FlowMonad
  ( Flow,
    runFlow,
    getConfig,
    getDBEnv,
    inDB,
    inConfig,
    logInfo,
    logError,
    logWarning,
    logDebug,
  )
where

import Core.Environment (Flow, getConfig, getDBEnv, inConfig, inDB, logDebug, logError, logInfo, logWarning, runFlow)
