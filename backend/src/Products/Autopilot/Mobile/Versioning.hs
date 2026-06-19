{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}

{- | Thin dispatcher over the platform-specific version-resolution
clients in "Products.Autopilot.Mobile.Versioning.Play" (Google Play
Console) and "Products.Autopilot.Mobile.Versioning.Apple" (App Store
Connect).

Both call sites — @execResolveVersion@ in "Mobile.Workflow" and
@previewVersionsH@ in "Mobile.Handlers.Versions" — call
'resolveNextVersion' here and pattern-match on the returned
'VersionResolution'. Branching on @app_catalog.platform@ lives here, not
in each caller.

Re-exports the public surface of both backend modules so existing
imports of @Products.Autopilot.Mobile.Versioning@ (the pre-rename
location) continue to work for legacy types like 'PlayApiError' and
'PlayCreds'. The new @Play@ / @Apple@ qualified names are also
available via @import qualified ... .Versioning.Play as P@ if a caller
wants direct access without the dispatcher.
-}
module Products.Autopilot.Mobile.Versioning (
    -- * Dispatcher
    VersionResolution (..),
    resolveNextVersion,
    resolveNextVersionWithToken,

    -- * Re-exports from "Mobile.Versioning.Play"
    module Products.Autopilot.Mobile.Versioning.Play,

    -- * Re-exports from "Mobile.Versioning.Apple"
    module Products.Autopilot.Mobile.Versioning.Apple,
) where

import Core.Environment (MonadFlow)
import Data.Int (Int32)
import Data.Text (Text)
import GHC.Generics (Generic)

import Products.Autopilot.Mobile.Versioning.Apple hiding (resolve, resolveWithToken)
import qualified Products.Autopilot.Mobile.Versioning.Apple as A
import Products.Autopilot.Mobile.Versioning.Play hiding (resolve)
import qualified Products.Autopilot.Mobile.Versioning.Play as P

{- | Resolved next-version for one app, with platform-specific shape.

* 'AndroidVersion' carries both fields (matches Play's two-input API:
  @inputs.version_name@ + @inputs.version_code@).
* 'IosVersion' carries only @vNumber@ (matches Apple's
  @inputs.version_number@ — the build number is computed by the
  iOS workflow's @fastlane fetch_build_number@).

Callers should pattern-match instead of unwrapping by accessor.
-}
data VersionResolution
    = AndroidVersion {vName :: Text, vCode :: Int32}
    | IosVersion {vNumber :: Text}
    deriving (Eq, Show, Generic)

{- | Dispatch by platform.

* @"android"@ → 'P.resolve' on the row's @package_name@ (Play package).
* @"ios"@     → 'A.resolve' on the row's @package_name@ (iOS bundle id).
* Anything else → @Left "unsupported platform: <value>"@.

The two helpers share the same shape:
@Text -> m (Either Text <platform-specific>)@ — so this dispatcher is
mostly mechanical bookkeeping. Error tags are pre-rendered by the
helpers (see @Play.renderPlayErr@ / @Apple.renderAscErr@) so callers
get a stable, machine-readable string suitable for audit events.
-}
resolveNextVersion ::
    (MonadFlow m) =>
    -- | Store account (@app_catalog.store_account@); 'Nothing' = default key. iOS only.
    Maybe Text ->
    -- | Platform — value of @app_catalog.platform@.
    Text ->
    -- | Package name or bundle id — value of @app_catalog.package_name@.
    Text ->
    m (Either Text VersionResolution)
resolveNextVersion mAcct platform pkg =
    case platform of
        "android" -> do
            res <- P.resolve pkg
            pure (fmap (\(n, c) -> AndroidVersion n c) res)
        "ios" -> do
            res <- A.resolve mAcct pkg
            pure (fmap IosVersion res)
        other -> pure (Left ("unsupported platform: " <> other))

resolveNextVersionWithToken ::
    (MonadFlow m) =>
    -- | Pre-minted ASC bearer token (shared across a batch to avoid
    --   Apple rejecting duplicate JWTs minted in the same second).
    Maybe Text ->
    -- | Platform — value of @app_catalog.platform@.
    Text ->
    -- | Package name or bundle id — value of @app_catalog.package_name@.
    Text ->
    m (Either Text VersionResolution)
resolveNextVersionWithToken mAscToken platform pkg =
    case platform of
        "android" -> do
            res <- P.resolve pkg
            pure (fmap (\(n, c) -> AndroidVersion n c) res)
        "ios" -> case mAscToken of
            Just token -> do
                res <- A.resolveWithToken token pkg
                pure (fmap IosVersion res)
            -- No token = this app's store account has no ASC creds configured. Don't
            -- fall back to the default key (that would hit the wrong Apple team).
            Nothing -> pure (Left "asc_creds_missing")
        other -> pure (Left ("unsupported platform: " <> other))
