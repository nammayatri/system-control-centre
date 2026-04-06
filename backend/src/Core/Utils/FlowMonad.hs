-- | Backwards-compatible re-export. Use Core.Environment directly.
module Core.Utils.FlowMonad (Flow, runFlow, getConfig, getDBEnv, inDB, inConfig) where

import Core.Environment (Flow, getConfig, getDBEnv, inConfig, inDB, runFlow)
