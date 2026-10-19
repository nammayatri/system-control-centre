{-# LANGUAGE OverloadedStrings #-}

{- | Entry point for the HPA scheduler's background work, started from @app/Main.hs@.

Two independent switches, both read from the environment (or the secrets file):

* @SC_HPA_SCHEDULER_ENABLED@ (default __off__): the reconciler that turns schedules into
  applies, and the workers that change HPAs. This is the part that writes to clusters, so
  it must be turned on deliberately.
* @SC_HPA_OBSERVER_ENABLED@ (default on): the read-only sampler behind the performance panel.

Every loop is supervised (a crash restarts it) and safe to run on several pods at once:
the observer and reconciler elect a leader through a lease, and workers claim rows with
leases, so a pod dying hands its work to another.
-}
module Products.Autopilot.Hpa.Loops (
    hpaLoops,
    schedulerEnabled,
    observerEnabled,
)
where

import Control.Concurrent.Async (mapConcurrently_)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Reader (ask)
import Core.Environment (Flow, logInfo, runFlow)
import Core.Secrets (lookupEnvSecret)
import Data.Text (Text)
import Data.Text qualified as T
import Data.UUID qualified as UUID
import Data.UUID.V4 qualified as UUID
import Products.Autopilot.Hpa.Observer (observerLoop)
import Products.Autopilot.Hpa.Reconcile (reconcileLoop)
import Products.Autopilot.Hpa.Worker (runWorkers)

envFlag :: Text -> Bool -> Flow Bool
envFlag name def = do
    m <- lookupEnvSecret (T.unpack name)
    pure $ case fmap T.toLower m of
        Just v -> v `elem` ["1", "true", "yes", "on"]
        Nothing -> def

schedulerEnabled :: Flow Bool
schedulerEnabled = envFlag "SC_HPA_SCHEDULER_ENABLED" False

observerEnabled :: Flow Bool
observerEnabled = envFlag "SC_HPA_OBSERVER_ENABLED" True

-- | How many applies may run at once.
workerCount :: Int
workerCount = 4

hpaLoops :: Flow ()
hpaLoops = do
    sched <- schedulerEnabled
    obs <- observerEnabled
    holder <- liftIO (T.take 8 . UUID.toText <$> UUID.nextRandom)
    logInfo ("[hpa] scheduler " <> onOff sched <> ", observer " <> onOff obs <> " (pod " <> holder <> ")")
    st <- ask
    let loops =
            [reconcileLoop holder >> pure () | sched]
                <> [runWorkers workerCount | sched]
                <> [observerLoop holder | obs]
    liftIO (mapConcurrently_ (runFlow st) loops)
  where
    onOff b = if b then "ON" else "off"
