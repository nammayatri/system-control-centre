{-# LANGUAGE OverloadedStrings #-}

{- | Dry-run of a change against the live HPAs of a service: what it would turn
each serving HPA into, and every reason it would be refused. Used by the preview
endpoint and, so that nothing can be saved that could never apply, by schedule
creation and manual apply.
-}
module Products.Autopilot.Hpa.Preview (
    TargetPreview (..),
    previewChange,
    blockingProblems,
)
where

import Data.Aeson (ToJSON (..), (.=))
import Data.Aeson qualified as A
import Data.Text (Text)
import Data.Text qualified as T
import Products.Autopilot.Hpa.Change
import Products.Autopilot.Hpa.Kube (Kube)
import Products.Autopilot.Hpa.Resolver
import Products.Autopilot.Hpa.Service (ServiceCtx (..))
import Products.Autopilot.Hpa.Spec
import Products.Autopilot.Hpa.Types

data TargetPreview = TargetPreview
    { tpHpa :: Text
    , tpVersion :: Text
    , tpRole :: HpaRole
    , tpNotEditable :: Maybe Text
    , tpBefore :: HpaSpec
    , tpAfter :: Maybe HpaSpec
    , tpErrors :: [Text]
    , tpGuardrail :: [Text]
    , tpNoop :: Bool
    , tpDiff :: [DiffEntry]
    }

instance ToJSON TargetPreview where
    toJSON t =
        A.object
            [ "hpa" .= tpHpa t
            , "version" .= tpVersion t
            , "role" .= tpRole t
            , "notEditableReason" .= tpNotEditable t
            , "before" .= tpBefore t
            , "after" .= tpAfter t
            , "errors" .= tpErrors t
            , "guardrailIssues" .= tpGuardrail t
            , "noop" .= tpNoop t
            , "diff" .= tpDiff t
            ]

{- | Preview @change@ on the serving HPAs, or on the one named by @only@. @Left@ when the
cluster cannot be read, the named HPA does not exist, or nothing is serving.
-}
previewChange :: Kube -> ServiceCtx -> Guardrail -> HpaChange -> Maybe Text -> IO (Either Text (Resolution, [TargetPreview]))
previewChange kube ctx g change only = do
    res <- resolveServiceHpasWith kube (scNamespace ctx) (scVsName ctx) (scHost ctx) (scOtherHosts ctx)
    pure $ do
        r <- res
        targets <- case only of
            Just name -> case [h | h <- resHpas r, hoName (rhHpa h) == name] of
                [h] -> Right [h]
                _ -> Left ("no HPA named " <> name <> " belongs to this service")
            Nothing -> case servingTargets r of
                [] -> Left ("no HPA is serving this service right now (" <> resReason r <> ")")
                hs -> Right hs
        Right (r, map (one g change) targets)

one :: Guardrail -> HpaChange -> ResolvedHpa -> TargetPreview
one g change t =
    TargetPreview
        { tpHpa = hoName h
        , tpVersion = rhVersion t
        , tpRole = rhRole t
        , tpNotEditable = rhEditableReason t
        , tpBefore = before
        , tpAfter = either (const Nothing) Just applied
        , tpErrors = either id (const []) applied
        , tpGuardrail = either (const []) (checkGuardrail g before) applied
        , tpNoop = either (const False) (== before) applied
        , tpDiff = either (const []) (jsonDiff (A.toJSON before) . A.toJSON) applied
        }
  where
    h = rhHpa t
    before = hoSpec h
    applied = applyChangeTyped before change

-- | Everything that must stop a change from being saved or applied. A no-op is not blocking here.
blockingProblems :: [TargetPreview] -> [Text]
blockingProblems = concatMap f
  where
    f t =
        [tpHpa t <> ": " <> why | Just why <- [tpNotEditable t]]
            <> [tpHpa t <> ": " <> e | e <- tpErrors t]
            <> [tpHpa t <> ": " <> T.strip e | e <- tpGuardrail t]
