-- | Backwards-compatible re-export. Use Core.Environment directly.
module Core.Utils.FlowMonad (Flow, runFlow, getConfig, getDBEnv) where

import Core.Environment (Flow, getConfig, getDBEnv, runFlow)
