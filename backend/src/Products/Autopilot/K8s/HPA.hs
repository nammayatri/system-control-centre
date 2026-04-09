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

{- | Read live HPA @spec.minReplicas/maxReplicas@. Returns @(0, 0)@ on any
failure; callers treat @maxReplicas == 0@ as "no live cap".
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
    -- Substitute template placeholders, then JSON-set
    -- spec.minReplicas/maxReplicas via jq so ANY initial value gets
    -- overwritten (string-replace silently no-oped if the template's
    -- values differed from the literal `1`, producing wrong-sized HPAs).
    let depName = T.unpack serviceHost <> "-" <> T.unpack version
        withDep = T.replace "{{DEPLOYMENT-NAME}}" (T.pack depName) hpaTemplate
        withNs = T.replace "{{NAMESPACE}}" ns withDep
        jqFilter = ".spec.minReplicas = " <> show minR <> " | .spec.maxReplicas = " <> show maxR
     in unwords ["echo", shellQuote withNs, "| jq", "'" <> jqFilter <> "'", "|", kubectlBin cfg, "-n", shellQuote ns, "apply -f -"]

buildCloneHpaCommand :: Config -> Text -> Text -> Text -> Text -> Text -> String
buildCloneHpaCommand cfg ns serviceHost _oldVersion newVersion' oldHpaName =
    -- Clone the old HPA: preserve min/max/metrics/behavior verbatim,
    -- rewrite identity + target pointers only:
    --   1. metadata.name → new HPA name
    --   2. spec.scaleTargetRef.name → new deployment name
    --   3. strip stale annotations (last-applied-configuration and the
    --      autoscaling.alpha.kubernetes.io/current-metrics | conditions)
    --   4. rewrite spec.metrics[*].object.describedObject.name for v2
    --      object metrics so they track the NEW deployment.
    --
    -- Deliberately does NOT recompute min/max from replica count: that
    -- caused min=max=N pinned HPAs after revert/restart. The progressive
    -- rollout path scales the deployment directly instead.
    let newDepName = T.unpack serviceHost <> "-" <> T.unpack newVersion'
        newHpaName = newDepName <> "-hpa"
        jqFilter =
            ".metadata.name = $newHpaName"
                <> " | .spec.scaleTargetRef.name = $newDepName"
                <> " | del(.metadata.uid,.metadata.resourceVersion,.metadata.generation,.metadata.creationTimestamp,.metadata.managedFields,.status)"
                <> " | if .metadata.annotations then .metadata.annotations |= (del(.\"kubectl.kubernetes.io/last-applied-configuration\", .\"autoscaling.alpha.kubernetes.io/current-metrics\", .\"autoscaling.alpha.kubernetes.io/conditions\")) else . end"
                <> " | if .spec.metrics then .spec.metrics |= map(if .object then .object.describedObject.name = $newDepName else . end) else . end"
     in unwords [kubectlBin cfg, "-n", shellQuote ns, "get hpa", shellQuote oldHpaName, "-o json | jq", "--arg newHpaName", shellQuote (T.pack newHpaName), "--arg newDepName", shellQuote (T.pack newDepName), "'" <> jqFilter <> "'", "|", kubectlBin cfg, "-n", shellQuote ns, "apply -f -"]
