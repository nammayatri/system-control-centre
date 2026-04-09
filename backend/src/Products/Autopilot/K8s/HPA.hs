{-# LANGUAGE OverloadedStrings #-}

-- | Kubernetes HPA (Horizontal Pod Autoscaler) operations.
module Products.Autopilot.K8s.HPA (
    hpaExists,
    getHpaMinMax,
    buildPatchHpaReplicasCommand,
    buildDeleteHpaCommand,
    buildCreateHpaFromTemplateCommand,
    buildCloneHpaCommand,
)
where

import Core.Config (Config (..))
import Data.Text (Text)
import qualified Data.Text as T
import Products.Autopilot.K8s.Execute
import Text.Read (readMaybe)

hpaExists :: Config -> Text -> Text -> IO Bool
hpaExists cfg ns hpaName = do
    res <- runCmd (unwords [kubectlBin cfg, "-n", shellQuote ns, "get hpa", shellQuote hpaName, "-o name"])
    pure $ case res of Right _ -> True; Left _ -> False

{- | Read the live HPA's @spec.minReplicas@ and @spec.maxReplicas@.
Used by:
  * 'scaleNewDeploymentForStage' — to cap 'safeTarget' at 'maxReplicas'
    so progressive rollout never tries to scale past the operator's
    configured HPA ceiling.
  * 'Runner.scaleDownOldDeployment' — to shrink the old HPA's floor
    before deleting it, closing the reconciler race.
Returns @(0, 0)@ on any failure (get-hpa error, parse error). Callers
treat @maxReplicas == 0@ as "no live cap, use raw safeTarget".
-}
getHpaMinMax :: Config -> Text -> Text -> IO (Int, Int)
getHpaMinMax cfg ns hpaName = do
    let cmd =
            unwords
                [ kubectlBin cfg
                , "-n"
                , shellQuote ns
                , "get hpa"
                , shellQuote hpaName
                , "-o"
                , "jsonpath='{.spec.minReplicas}|{.spec.maxReplicas}'"
                ]
    res <- runCmd cmd
    case res of
        Right (K8sResult raw) ->
            let stripped = T.strip (T.dropAround (== '\'') (T.strip raw))
             in case T.splitOn "|" stripped of
                    [mn, mx] ->
                        pure
                            ( fromMaybe 0 (readMaybe (T.unpack (T.strip mn)))
                            , fromMaybe 0 (readMaybe (T.unpack (T.strip mx)))
                            )
                    _ -> pure (0, 0)
        Left _ -> pure (0, 0)
  where
    fromMaybe d m = case m of Just v -> v; Nothing -> d

buildPatchHpaReplicasCommand :: Config -> Text -> Text -> Int -> Int -> String
buildPatchHpaReplicasCommand cfg ns hpaName minR maxR =
    unwords ["echo '{\"spec\":{\"minReplicas\":" <> show minR <> ",\"maxReplicas\":" <> show maxR <> "}}' |", kubectlBin cfg, "-n", shellQuote ns, "patch hpa", shellQuote hpaName, "--type merge -p \"$(cat)\""]

buildDeleteHpaCommand :: Config -> Text -> Text -> String
buildDeleteHpaCommand cfg ns hpaName =
    unwords [kubectlBin cfg, "-n", shellQuote ns, "delete hpa", shellQuote hpaName, "--ignore-not-found=true"]

buildCreateHpaFromTemplateCommand :: Config -> Text -> Text -> Text -> Text -> Int -> Int -> String
buildCreateHpaFromTemplateCommand cfg ns serviceHost version hpaTemplate minR maxR =
    -- Julia parity (kubernetes.jl:3125 createHPAFromTemplate): substitute
    -- placeholders, then JSON-set spec.minReplicas / spec.maxReplicas via jq
    -- so ANY initial value (not just the literal `1`) in the template gets
    -- overwritten. The previous string-replace approach silently no-oped if
    -- the template shipped with minReplicas/maxReplicas != 1, producing
    -- wrong-sized HPAs on first release.
    let depName = T.unpack serviceHost <> "-" <> T.unpack version
        withDep = T.replace "{{DEPLOYMENT-NAME}}" (T.pack depName) hpaTemplate
        withNs = T.replace "{{NAMESPACE}}" ns withDep
        jqFilter = ".spec.minReplicas = " <> show minR <> " | .spec.maxReplicas = " <> show maxR
     in unwords ["echo", shellQuote withNs, "| jq", "'" <> jqFilter <> "'", "|", kubectlBin cfg, "-n", shellQuote ns, "apply -f -"]

buildCloneHpaCommand :: Config -> Text -> Text -> Text -> Text -> Text -> String
buildCloneHpaCommand cfg ns serviceHost _oldVersion newVersion' oldHpaName =
    -- Clone the old HPA onto the new deployment while preserving operator
    -- intent verbatim: min/max/metrics/behavior all carry over from the old
    -- HPA. Only identity + target pointers are rewritten:
    --
    --   1. metadata.name → new HPA name
    --   2. spec.scaleTargetRef.name → new deployment name
    --   3. Strip stale annotations: last-applied-configuration,
    --      autoscaling.alpha.kubernetes.io/current-metrics,
    --      autoscaling.alpha.kubernetes.io/conditions
    --   4. For autoscaling/v2 with object metrics, rewrite
    --      spec.metrics[*].object.describedObject.name → new deployment name
    --      (so object metrics scale against the NEW deployment, not the old).
    --
    -- Rationale (deliberate divergence from Julia's kubernetes.jl:1199-1247):
    -- Julia recomputed spec.minReplicas/spec.maxReplicas here from a formula
    -- based on the old deployment's replica count, then ratcheted upward every
    -- rollout stage. That cascaded into min=max=N pinned HPAs whenever a prior
    -- stage inflated the replica count (revert/restart). We stop the cascade
    -- by letting the clone preserve whatever min/max the operator has on the
    -- old HPA; the progressive-rollout path scales the deployment directly
    -- and no longer touches HPA bounds. See scaleNewDeploymentForStage.
    let newDepName = T.unpack serviceHost <> "-" <> T.unpack newVersion'
        newHpaName = newDepName <> "-hpa"
        jqFilter =
            ".metadata.name = $newHpaName"
                <> " | .spec.scaleTargetRef.name = $newDepName"
                <> " | del(.metadata.uid,.metadata.resourceVersion,.metadata.generation,.metadata.creationTimestamp,.metadata.managedFields,.status)"
                -- Strip stale annotations that would otherwise collide with apply
                <> " | if .metadata.annotations then .metadata.annotations |= (del(.\"kubectl.kubernetes.io/last-applied-configuration\", .\"autoscaling.alpha.kubernetes.io/current-metrics\", .\"autoscaling.alpha.kubernetes.io/conditions\")) else . end"
                -- v2 HPA: rewrite describedObject.name on each object-type metric.
                -- No-op for CPU/memory metrics.
                <> " | if .spec.metrics then .spec.metrics |= map(if .object then .object.describedObject.name = $newDepName else . end) else . end"
     in unwords [kubectlBin cfg, "-n", shellQuote ns, "get hpa", shellQuote oldHpaName, "-o json | jq", "--arg newHpaName", shellQuote (T.pack newHpaName), "--arg newDepName", shellQuote (T.pack newDepName), "'" <> jqFilter <> "'", "|", kubectlBin cfg, "-n", shellQuote ns, "apply -f -"]
