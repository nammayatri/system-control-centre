{-# LANGUAGE OverloadedStrings #-}

-- | Kubernetes HPA (Horizontal Pod Autoscaler) operations.
module Products.Autopilot.K8s.HPA (
    hpaExists,
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

hpaExists :: Config -> Text -> Text -> IO Bool
hpaExists cfg ns hpaName = do
    res <- runCmd (unwords [kubectlBin cfg, "-n", T.unpack ns, "get hpa", T.unpack hpaName, "-o name"])
    pure $ case res of Right _ -> True; Left _ -> False

buildPatchHpaReplicasCommand :: Config -> Text -> Text -> Int -> Int -> String
buildPatchHpaReplicasCommand cfg ns hpaName minR maxR =
    unwords ["echo '{\"spec\":{\"minReplicas\":" <> show minR <> ",\"maxReplicas\":" <> show maxR <> "}}' |", kubectlBin cfg, "-n", T.unpack ns, "patch hpa", T.unpack hpaName, "--type merge -p \"$(cat)\""]

buildDeleteHpaCommand :: Config -> Text -> Text -> String
buildDeleteHpaCommand cfg ns hpaName =
    unwords [kubectlBin cfg, "-n", T.unpack ns, "delete hpa", T.unpack hpaName, "--ignore-not-found=true"]

buildCreateHpaFromTemplateCommand :: Config -> Text -> Text -> Text -> Text -> Int -> Int -> String
buildCreateHpaFromTemplateCommand cfg ns serviceHost version hpaTemplate minR maxR =
    let depName = T.unpack serviceHost <> "-" <> T.unpack version
        withDep = T.replace "{{DEPLOYMENT-NAME}}" (T.pack depName) hpaTemplate
        withNs = T.replace "{{NAMESPACE}}" ns withDep
        patchMin = T.replace "\"minReplicas\": 1" ("\"minReplicas\": " <> T.pack (show minR)) withNs
        patchMax = T.replace "\"maxReplicas\": 1" ("\"maxReplicas\": " <> T.pack (show maxR)) patchMin
     in unwords ["echo", shellQuote patchMax, "|", kubectlBin cfg, "-n", T.unpack ns, "apply -f -"]

buildCloneHpaCommand :: Config -> Text -> Text -> Text -> Text -> Text -> Int -> Int -> String
buildCloneHpaCommand cfg ns serviceHost _oldVersion newVersion' oldHpaName minR maxR =
    let newDepName = T.unpack serviceHost <> "-" <> T.unpack newVersion'
        newHpaName = newDepName <> "-hpa"
        jqFilter = ".metadata.name = \"" <> newHpaName <> "\" | .spec.scaleTargetRef.name = \"" <> newDepName <> "\" | .spec.minReplicas = " <> show minR <> " | .spec.maxReplicas = " <> show maxR <> " | del(.metadata.uid,.metadata.resourceVersion,.metadata.generation,.metadata.creationTimestamp,.metadata.managedFields,.status)"
     in unwords [kubectlBin cfg, "-n", T.unpack ns, "get hpa", T.unpack oldHpaName, "-o json | jq", "'" <> jqFilter <> "'", "|", kubectlBin cfg, "-n", T.unpack ns, "apply -f -"]
