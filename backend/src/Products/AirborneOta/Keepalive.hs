{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

{- | Daily PAT keepalive. The PAT wraps a Keycloak offline refresh token that
idles out after 30 days unused; one forced re-issue per day keeps it alive
forever and turns a dying PAT into a visible UI banner (via the outcome
recorded in 'recordKeepalive', surfaced by @GET \/airborne\/health@) instead
of a silent full-product 401. (The app list is driven live off airborne, so
there is no local mapping to reconcile here.) Deliberately a single tick — do
not add another background poller.

Multi-replica: every replica ticks daily ON PURPOSE — the outcome lives in a
process-local ref read by @GET \/airborne\/health@, so each replica must
refresh its own view or the banner would depend on which pod serves the
request. The tick is idempotent (a forced token re-issue), so duplicates are
harmless.
-}
module Products.AirborneOta.Keepalive (airborneKeepaliveLoop) where

import Control.Monad (forever)
import Control.Monad.Catch (SomeException, catch)
import Core.Environment (Flow, logError, logInfo, logWarning)
import Core.Secrets (lookupEnvSecret)
import Core.Types.Time (Seconds (..), threadDelay)
import Data.Maybe (isNothing)
import Data.Text qualified as T

import Products.AirborneOta.Client (forceTokenRefresh, recordKeepalive)

{- | Re-issue attempts per tick before recording failure. The PAT path spans
airborne + Keycloak, so a transient blip should not read as a dying PAT.
-}
maxAttempts :: Int
maxAttempts = 3

airborneKeepaliveLoop :: Flow ()
airborneKeepaliveLoop = do
    mCid <- lookupEnvSecret "SC_AIRBORNE_PAT_CLIENT_ID"
    if isNothing mCid
        then logWarning "[airborne-keepalive] PAT not configured — keepalive disabled"
        else forever $ do
            tick
            threadDelay (Seconds 86400)
  where
    -- Retries with a short backoff; only the last failure is recorded.
    tick = attempt 1

    attempt :: Int -> Flow ()
    attempt n =
        ( do
            _ <- forceTokenRefresh
            recordKeepalive True Nothing
            logInfo "[airborne-keepalive] PAT re-issue ok"
        )
            `catch` \(e :: SomeException) ->
                if n < maxAttempts
                    then do
                        logWarning
                            ( "[airborne-keepalive] PAT re-issue attempt "
                                <> T.pack (show n)
                                <> " failed, retrying: "
                                <> T.pack (show e)
                            )
                        threadDelay (Seconds 30)
                        attempt (n + 1)
                    else do
                        -- Recorded state is the alert channel: healthH surfaces it and
                        -- the OTA banner tells the operator to re-enrol before users
                        -- see a full-product 401. ERROR log stays as the ops trail.
                        recordKeepalive False (Just (T.take 300 (T.pack (show e))))
                        logError ("[airborne-keepalive] PAT RE-ISSUE FAILED: " <> T.pack (show e))
