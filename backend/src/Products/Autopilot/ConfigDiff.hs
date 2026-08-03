{-# LANGUAGE OverloadedStrings #-}

{- | Before/after config extraction for ConfigMap (BackendConfig) trackers.

A small leaf module (no dependency on @Actions.Release@ or the workflow) so both
the diff endpoint ('Products.Autopilot.Actions.Release.releaseDiffH') and the AI
review layer ('Products.Autopilot.ConfigReview') can share one source of truth
for "what changed" — the human diff and the model's diff stay identical, without
creating an import cycle.
-}
module Products.Autopilot.ConfigDiff (
    extractConfigMapDataSection,
    configMapBeforeAfter,
    extractDeploymentEnvSection,
    deploymentBeforeAfter,
    decodeBase64Config,
    maybeDecodeBase64,
) where

import Core.Environment (Flow)
import Data.Aeson (Value (..))
import Data.Aeson qualified as A
import Data.Aeson.Key qualified as K
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString qualified as BS
import Data.ByteString.Base64 qualified as B64
import Data.ByteString.Lazy qualified as LBS
import Data.Foldable (toList)
import Data.Maybe (listToMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Yaml qualified as Yaml
import Products.Autopilot.Queries.ReleaseTracker (listReleaseEventsByCategory)
import Products.Autopilot.Types (ReleaseTracker (..))
import Products.Autopilot.Types.Storage.Schema qualified as S

{- | Reduce a K8s ConfigMap YAML manifest to just its @data@ section (as JSON
text) so before/after are directly comparable; pass non-manifest text through.
-}
extractConfigMapDataSection :: Text -> Text
extractConfigMapDataSection yamlText =
    case Yaml.decodeEither' (TE.encodeUtf8 yamlText) :: Either Yaml.ParseException Value of
        Right (Object obj) ->
            case KM.lookup (K.fromText "data") obj of
                Just dataVal -> TE.decodeUtf8 (LBS.toStrict (A.encode dataVal))
                Nothing -> yamlText
        _ -> yamlText

{- | Resolve the before/after ConfigMap @data@ text for a BackendConfig tracker:
Both sides are normalised to their @data@ sections.
-}
configMapBeforeAfter :: ReleaseTracker -> Flow (Text, Text)
configMapBeforeAfter tracker = do
    let rid = releaseId tracker
    snapshotEvents <- listReleaseEventsByCategory rid "SNAPSHOT"
    let findSnap lbl = listToMaybe [e | e <- snapshotEvents, S.reLabel e == lbl]
        payloadToText (String s) = s
        payloadToText other = TE.decodeUtf8 (LBS.toStrict (A.encode other))
        beforeData =
            maybe "" (extractConfigMapDataSection . payloadToText . S.rePayload) (findSnap "CONFIGMAP_BEFORE")
        proposedFromMeta = case metadata tracker of
            Just (Object o) ->
                case KM.lookup (K.fromText "file") o of
                    Just (String f) -> f
                    _ -> case KM.lookup (K.fromText "config") o of
                        Just (String c) -> c
                        _ -> ""
            _ -> ""
        afterData = case findSnap "CONFIGMAP_AFTER" of
            Just aEvt -> extractConfigMapDataSection (payloadToText (S.rePayload aEvt))
            Nothing -> extractConfigMapDataSection proposedFromMeta
    pure (beforeData, afterData)

-- ─── Deployment env extraction (for BackendService review) ─────────

{- | Look up a key on a JSON object; 'Nothing' for non-objects or missing keys. -}
objLookup :: Text -> Value -> Maybe Value
objLookup k (Object o) = KM.lookup (K.fromText k) o
objLookup _ _ = Nothing

-- | Scalar rendering: strings verbatim, everything else via its JSON encoding.
asText :: Value -> Text
asText (String s) = s
asText v = TE.decodeUtf8 (LBS.toStrict (A.encode v))

extractDeploymentEnvSection :: Text -> Text
extractDeploymentEnvSection yamlText =
    case Yaml.decodeEither' (TE.encodeUtf8 yamlText) :: Either Yaml.ParseException Value of
        Right root
            | Just spec <- objLookup "spec" root ->
                let replicaLines = maybe [] (\r -> ["replicas: " <> asText r]) (objLookup "replicas" spec)
                    containers = case objLookup "template" spec >>= objLookup "spec" >>= objLookup "containers" of
                        Just (Array a) -> toList a
                        _ -> []
                    blocks = replicaLines ++ map renderContainer containers
                 in if null blocks then yamlText else T.intercalate "\n\n" blocks
        _ -> yamlText

renderContainer :: Value -> Text
renderContainer c =
    let name = maybe "container" asText (objLookup "name" c)
        envLines = case objLookup "env" c of
            Just (Array a) -> map renderEnv (toList a)
            _ -> []
        resLines = maybe [] renderResources (objLookup "resources" c)
     in T.intercalate "\n" $
            ("container: " <> name)
                : sect "resources" resLines
                ++ sect "env" envLines
  where
    sect _ [] = []
    sect lbl ls = ("  " <> lbl <> ":") : map ("    " <>) ls

renderEnv :: Value -> Text
renderEnv e =
    let n = maybe "?" asText (objLookup "name" e)
     in case objLookup "value" e of
            -- Base64-decode the value (best-effort) so the model diffs the real
            -- env value, not an opaque blob — same treatment as ConfigMap data.
            Just v -> n <> ": " <> maybeDecodeBase64 (asText v)
            Nothing -> case objLookup "valueFrom" e of
                Just vf -> n <> ": " <> renderValueFrom vf
                Nothing -> n <> ":"

renderValueFrom :: Value -> Text
renderValueFrom vf =
    case objLookup "secretKeyRef" vf of
        Just r -> "secretKeyRef(" <> refDesc r <> ")"
        Nothing -> case objLookup "configMapKeyRef" vf of
            Just r -> "configMapKeyRef(" <> refDesc r <> ")"
            Nothing -> case objLookup "fieldRef" vf of
                Just r -> "fieldRef(" <> maybe "" asText (objLookup "fieldPath" r) <> ")"
                Nothing -> "valueFrom(...)"
  where
    refDesc r = maybe "" asText (objLookup "name" r) <> "/" <> maybe "" asText (objLookup "key" r)

renderResources :: Value -> [Text]
renderResources r = render "requests" ++ render "limits"
  where
    render lbl = case objLookup lbl r of
        Just (Object o) -> [lbl <> ": " <> T.intercalate " " [K.toText k <> "=" <> asText v | (k, v) <- KM.toList o]]
        _ -> []

{- | Resolve the before/after deployment env text for a BackendService tracker:
the workflow-time @DEPLOYMENT_BEFORE@/@_AFTER@ snapshots, falling back to the
create-time @_PREVIEW@ snapshots (same precedence as the human diff endpoint).
Both sides are reduced to their env-relevant section so they compare cleanly.
-}
deploymentBeforeAfter :: ReleaseTracker -> Flow (Text, Text)
deploymentBeforeAfter tracker = do
    let rid = releaseId tracker
    snaps <- listReleaseEventsByCategory rid "SNAPSHOT"
    let findSnap labels = listToMaybe [e | lbl <- labels, e <- snaps, S.reLabel e == lbl]
        payloadToText (String s) = s
        payloadToText other = TE.decodeUtf8 (LBS.toStrict (A.encode other))
        raw labels = maybe "" (payloadToText . S.rePayload) (findSnap labels)
        beforeRaw = raw ["DEPLOYMENT_BEFORE", "DEPLOYMENT_BEFORE_PREVIEW"]
        afterRaw = raw ["DEPLOYMENT_AFTER", "DEPLOYMENT_AFTER_PREVIEW"]
    pure (extractDeploymentEnvSection beforeRaw, extractDeploymentEnvSection afterRaw)

-- ─── Base64 decoding (so the model reviews real config, not blobs) ──

{- | ConfigMap @data@ values (and some deployment env values) are often stored
base64-encoded, which would leave the model diffing opaque blobs. Best-effort
decode: for a JSON object (the usual @data@ section) decode each string VALUE;
otherwise try the whole text. A value is only decoded when it is valid base64
AND the bytes are valid, mostly-printable UTF-8 — so plain-text values (and
coincidental base64-shaped tokens like "true") are left untouched. Output is
readable @key:@-labelled sections, not JSON, so the diff the model sees is clean.
-}
decodeBase64Config :: Text -> Text
decodeBase64Config txt =
    case A.decodeStrict' (TE.encodeUtf8 txt) :: Maybe Value of
        Just (Object o) ->
            T.intercalate "\n\n" [K.toText k <> ":\n" <> valText v | (k, v) <- KM.toList o]
        _ -> maybeDecodeBase64 (T.strip txt)
  where
    valText (String s) = maybeDecodeBase64 (T.strip s)
    valText other = TE.decodeUtf8 (LBS.toStrict (A.encode other))

{- | Decode @s@ from base64 only if it is valid base64 whose bytes are valid,
mostly-printable UTF-8; otherwise return @s@ unchanged. This is the sole
"is it base64?" test — we don't guess from key names, we just try to decode and
keep the result only when it round-trips to readable text.
-}
maybeDecodeBase64 :: Text -> Text
maybeDecodeBase64 s =
    case B64.decode (TE.encodeUtf8 s) of
        Right bs
            | not (BS.null bs)
            , Right decoded <- TE.decodeUtf8' bs
            , isPrintableText decoded ->
                decoded
        _ -> s

-- | Every char is printable or ordinary whitespace (no control/binary bytes).
isPrintableText :: Text -> Bool
isPrintableText t =
    not (T.null t)
        && T.all (\c -> c == '\n' || c == '\t' || c == '\r' || (c >= ' ' && c /= '\DEL')) t
