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

{- | Julia parity (@getHpaMinMax@ in kubernetes.jl): read the live HPA's
@spec.minReplicas@ and @spec.maxReplicas@. Used by the ratchet-upward
logic in 'scaleNewDeploymentForStage' so we never shrink an operator's
manual bump-up of the floor. Returns @(0, 0)@ on any failure so the
caller falls through to "just use the computed values".
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

buildCloneHpaCommand :: Config -> Text -> Text -> Text -> Text -> Text -> Int -> Int -> String
buildCloneHpaCommand cfg ns serviceHost _oldVersion newVersion' oldHpaName minR maxR =
    let newDepName = T.unpack serviceHost <> "-" <> T.unpack newVersion'
        newHpaName = newDepName <> "-hpa"
        jqFilter = ".metadata.name = $newHpaName | .spec.scaleTargetRef.name = $newDepName | .spec.minReplicas = " <> show minR <> " | .spec.maxReplicas = " <> show maxR <> " | del(.metadata.uid,.metadata.resourceVersion,.metadata.generation,.metadata.creationTimestamp,.metadata.managedFields,.status)"
     in unwords [kubectlBin cfg, "-n", shellQuote ns, "get hpa", shellQuote oldHpaName, "-o json | jq", "--arg newHpaName", shellQuote (T.pack newHpaName), "--arg newDepName", shellQuote (T.pack newDepName), "'" <> jqFilter <> "'", "|", kubectlBin cfg, "-n", shellQuote ns, "apply -f -"]
