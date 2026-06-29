{-# LANGUAGE LambdaCase #-}

-- | Build-kind axis: does a build have a Play/ASC store
-- lifecycle at all? The ONE classifier, replacing the scattered isDebug /
-- destination checks. Orthogonal to the release 'Phase'.
module Products.Autopilot.Mobile.Lifecycle.BuildKind (
    BuildKind (..),
    buildKind,
    hasStoreIdentity,
    claimsStoreIdentity,
) where

import Products.Autopilot.Mobile.Types (MobileBuildContext (..), isDebugBuildType)

-- | Debug = master/QA + debug apps. FirebaseInternal = provider/driver Firebase
-- (and any non-Play/ASC destination). StoreBound = consumer android/ios +
-- provider GooglePlay — the only kind with a store lifecycle.
data BuildKind = Debug | FirebaseInternal | StoreBound
    deriving (Eq, Show)

-- | StoreBound iff a non-debug build targeting Play/ASC. Destination Nothing =
-- consumer (Play+ASC); "GooglePlay" = provider Play. Everything else non-debug
-- (Firebase, other stores) has no SCC-managed store lifecycle.
buildKind :: MobileBuildContext -> BuildKind
buildKind c
    | isDebugBuildType (mbcBuildType c) = Debug
    | mbcDestination c `elem` [Nothing, Just "GooglePlay"] = StoreBound
    | otherwise = FirebaseInternal

-- | Eligibility: only a StoreBound build owns a (version, code) store identity.
hasStoreIdentity :: BuildKind -> Bool
hasStoreIdentity = \case
    StoreBound -> True
    _ -> False

claimsStoreIdentity :: MobileBuildContext -> Bool
claimsStoreIdentity = hasStoreIdentity . buildKind
