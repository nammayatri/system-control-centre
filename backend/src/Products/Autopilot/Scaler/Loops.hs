{-# LANGUAGE OverloadedStrings #-}

{- | Entry point for the capacity scaler's background work, started from @app/Main.hs@ next to the HPA
scheduler's.

One switch, read from the environment (or the secrets file): @SC_SCALER_SCHEDULER_ENABLED@ (default __off__)
starts the reconciler that turns schedules into applies and the workers that resize targets and edit
autoscaler jobs. This is the part that writes to Google Cloud, so it must be turned on deliberately. The HTTP
API (targets, live state, preview, schedules, the autoscaler editor, the ledger) works either way.

Every loop is supervised (a crash restarts it) and safe to run on several pods at once: the reconciler elects a
leader through a lease and workers claim rows with leases.
-}
module Products.Autopilot.Scaler.Loops (
    scalerLoops,
    schedulerEnabled,
)
where

import Control.Concurrent.Async (mapConcurrently_)
import Control.Monad (when)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Reader (ask)
import Core.Environment (Flow, logInfo, runFlow)
import Core.Secrets (lookupEnvSecret)
import Data.Text (Text)
import Data.Text qualified as T
import Data.UUID qualified as UUID
import Data.UUID.V4 qualified as UUID
import Products.Autopilot.Scaler.Reconcile (reconcileLoop)
import Products.Autopilot.Scaler.Worker (runWorkers)

schedulerEnabled :: Flow Bool
schedulerEnabled = do
    m <- lookupEnvSecret "SC_SCALER_SCHEDULER_ENABLED"
    pure $ case fmap T.toLower m of
        Just v -> v `elem` ["1", "true", "yes", "on"]
        Nothing -> False

-- | How many applies may run at once. Resizes are rare and slow, so a few are plenty.
workerCount :: Int
workerCount = 2

scalerLoops :: Flow ()
scalerLoops = do
    on <- schedulerEnabled
    holder <- liftIO (T.take 8 . UUID.toText <$> UUID.nextRandom)
    logInfo ("[scaler] scheduler " <> onOff on <> " (pod " <> holder <> ")")
    st <- ask
    let loops = [reconcileLoop holder, runWorkers workerCount]
    when on (liftIO (mapConcurrently_ (runFlow st) loops))
  where
    onOff :: Bool -> Text
    onOff b = if b then "ON" else "off"
