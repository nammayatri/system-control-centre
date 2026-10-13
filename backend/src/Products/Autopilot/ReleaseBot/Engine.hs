{-# LANGUAGE OverloadedStrings #-}

{- | Analysis for a release request: what changes between what is deployed and the
requested commit, and what has to be reviewed before it is applied.

Everything here is deterministic and fails closed — anything it cannot verify
(deployed commit unknown, GitHub/K8s read failed, env var not base64/UTF-8,
diff truncated at GitHub's 300-file cap) becomes a /blocker/ that prevents
auto-apply; it never degrades to "looks fine".

Two fingerprints make the approval binding:

  * 'anLiveFingerprint' — hash of the /current/ values that will be replaced;
    re-checked at apply time so a change made after approval aborts the apply.
  * 'anContentHash'     — hash of the /new/ values that will be written; fixed at
    approval time, so what runs is exactly what was reviewed.
-}
module Products.Autopilot.ReleaseBot.Engine (
    Analysis (..),
    SvcResult (..),
    EnvChange (..),
    CmChange (..),
    Coverage (..),
    SvcCoverage (..),
    analyze,
    analyzeEnv,
    needsApproval,
    publicView,
    secretFilesHit,
    hashTexts,
) where

import Core.Auth.Protected (AuthedPerson)
import Core.Environment (Flow)
import Crypto.Hash (SHA256 (..), hashWith)
import Data.Aeson (ToJSON (..), Value (..), object, (.=))
import qualified Data.Aeson.Key as K
import qualified Data.Aeson.KeyMap as KM
import Data.ByteArray.Encoding (Base (Base16), convertToBase)
import qualified Data.ByteString as BS
import Data.List (nub, sort)
import qualified Data.Map.Strict as M
import Data.Maybe (fromMaybe, listToMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Data.Vector as V
import Products.Autopilot.Actions.K8sResource (resolveRunningVersionH)
import Products.Autopilot.DiffLink (buildDiffLink, toCommitId)
import Products.Autopilot.ProdRelease.Config
import Products.Autopilot.ProdRelease.Github
import Products.Autopilot.ReleaseBot.Diff
import Products.Autopilot.ReleaseBot.Live

data SvcResult = SvcResult
    { srService :: Text
    , srAppGroup :: Text
    , srOldVersion :: Maybe Text
    , srBaseCommit :: Maybe Text
    , srDiffUrl :: Maybe Text
    , srDhallHits :: [Text]
    , srChangedFiles :: [Text]
    , srVerified :: Bool
    , srReason :: Maybe Text
    }

data EnvChange = EnvChange
    { ecService :: Text
    , ecAppGroup :: Text
    , ecEnvVar :: Text
    , ecState :: Text
    -- ^ @changed@ | @unchanged@ | @undecodable@ | @live_absent@ | @error@
    , ecDiff :: Maybe FileDiff
    , ecNewB64 :: Maybe Text
    , ecLiveB64 :: Maybe Text
    , ecError :: Maybe Text
    }

data CmChange = CmChange
    { ccName :: Text
    , ccAppGroup :: Text
    , ccNamespace :: Text
    , ccDiffs :: [FileDiff]
    , ccLiveData :: M.Map Text Text
    , ccNewData :: M.Map Text Text
    }

-- | What the running deployment references, and whether each reference was reviewed.
data SvcCoverage = SvcCoverage
    { covService :: Text
    , covDeployment :: Maybe Text
    , covConfigMaps :: [(Text, Text)]
    -- ^ (name, status): @changed@ | @unchanged@ | @not_triggered@ | @not_tracked@ | @ignored@
    , covSecrets :: [Text]
    -- ^ Secret NAMES only — values are never read
    , covEnvVar :: Maybe (Text, Text)
    -- ^ (env var, state) for the dhall env var rule, if the service has one
    , covError :: Maybe Text
    }

data Coverage = Coverage
    { cvServices :: [SvcCoverage]
    , cvUnmapped :: [Text]
    -- ^ Changed dhall files that no rule watches
    , cvComplete :: Bool
    -- ^ Every referenced configmap was reviewed (or is ignored), the deployment could be read, nothing unmapped
    }

data Analysis = Analysis
    { anRepo :: Text
    , anEnv :: Text
    , anBranch :: Maybe Text
    , anCommit :: Text
    , anServices :: [SvcResult]
    , anEnvChanges :: [EnvChange]
    , anConfigMaps :: [CmChange]
    , anSecretFiles :: [Text]
    , anSecretUnverifiable :: Bool
    , anBlockers :: [Text]
    , anCoverage :: Coverage
    , anLiveFingerprint :: Text
    , anContentHash :: Text
    }

-- | Does anything need a human to review it before apply?
needsApproval :: Analysis -> Bool
needsApproval a =
    any ((== "changed") . ecState) (anEnvChanges a)
        || not (null (anConfigMaps a))
        || any (not . null . srDhallHits) (anServices a)

instance ToJSON SvcResult where
    toJSON s =
        object
            [ "service" .= srService s
            , "appGroup" .= srAppGroup s
            , "oldVersion" .= srOldVersion s
            , "baseCommit" .= srBaseCommit s
            , "diffUrl" .= srDiffUrl s
            , "dhallHits" .= srDhallHits s
            , "changedFileCount" .= length (srChangedFiles s)
            , "verified" .= srVerified s
            , "reason" .= srReason s
            ]

instance ToJSON EnvChange where
    toJSON e =
        object
            [ "service" .= ecService e
            , "appGroup" .= ecAppGroup e
            , "envVar" .= ecEnvVar e
            , "state" .= ecState e
            , "diff" .= ecDiff e
            , "newB64" .= ecNewB64 e
            , "liveB64" .= ecLiveB64 e
            , "error" .= ecError e
            ]

instance ToJSON CmChange where
    toJSON c =
        object
            [ "name" .= ccName c
            , "appGroup" .= ccAppGroup c
            , "namespace" .= ccNamespace c
            , "diffs" .= ccDiffs c
            , "liveData" .= ccLiveData c
            , "newData" .= ccNewData c
            ]

instance ToJSON SvcCoverage where
    toJSON c =
        object
            [ "service" .= covService c
            , "deployment" .= covDeployment c
            , "configMaps" .= [object ["name" .= n, "status" .= st] | (n, st) <- covConfigMaps c]
            , "secrets" .= covSecrets c
            , "envVar" .= fmap (\(v, st) -> object ["name" .= v, "state" .= st]) (covEnvVar c)
            , "error" .= covError c
            ]

instance ToJSON Coverage where
    toJSON c = object ["services" .= cvServices c, "unmappedDhall" .= cvUnmapped c, "complete" .= cvComplete c]

instance ToJSON Analysis where
    toJSON a =
        object
            [ "repo" .= anRepo a
            , "env" .= anEnv a
            , "branch" .= anBranch a
            , "commit" .= anCommit a
            , "shortCommit" .= T.take 6 (anCommit a)
            , "services" .= anServices a
            , "envChanges" .= anEnvChanges a
            , "configMaps" .= anConfigMaps a
            , "secretFiles" .= anSecretFiles a
            , "secretUnverifiable" .= anSecretUnverifiable a
            , "blockers" .= anBlockers a
            , "coverage" .= anCoverage a
            , "needsApproval" .= needsApproval a
            , "liveFingerprint" .= anLiveFingerprint a
            , "contentHash" .= anContentHash a
            ]

{- | The version of an analysis safe to serve on the public (no-VPN) page: diffs and
flags only. Raw maps/blobs used to APPLY (full configmap data, base64 env values)
are removed, so the public surface shows exactly the reviewed diff and nothing else.
-}
publicView :: Value -> Value
publicView = go
  where
    hidden = ["newData", "liveData", "newB64", "liveB64", "liveFingerprint", "contentHash"]
    go (Object o) = Object (KM.fromList [(k, go v) | (k, v) <- KM.toList o, K.toText k `notElem` hidden])
    go (Array xs) = Array (V.map go xs)
    go v = v

hashTexts :: [Text] -> Text
hashTexts ts =
    let digest = hashWith SHA256 (TE.encodeUtf8 (T.intercalate "\US" ts))
     in TE.decodeUtf8 (convertToBase Base16 digest :: BS.ByteString)

secretFilesHit :: RepoCfg -> [Text] -> [Text]
secretFilesHit repo files = nub (sort (filter (isSecretFile repo) files))

-- ─── The analysis ──────────────────────────────────────────────────

analyze :: AuthedPerson -> Text -> RepoCfg -> Text -> Maybe Text -> Text -> [Text] -> Flow Analysis
analyze ap token repo env mBranch fullSha svcNames = do
    let slug = repoSlug repo
        selected = [s | n <- svcNames, s <- take 1 [x | x <- rcServices repo, scService x == n]]
        unknown = [n | n <- svcNames, n `notElem` map scService (rcServices repo)]
    svcResults <- mapM (analyzeService ap token repo fullSha) selected
    let allFiles = concatMap srChangedFiles svcResults
        secretHits = secretFilesHit repo allFiles
        unverified = any (not . srVerified) svcResults
        resultFor s = take 1 [r | r <- svcResults, srService r == scService s]
    -- A changed file TRIGGERS its rule; an unverifiable diff triggers everything (fail safe).
    envChanges <- mapM (\s -> analyzeEnv token slug fullSha (listToMaybe (resultFor s) >>= srBaseCommit) (triggeredFor s resultFor) s) selected
    cmChanges <- analyzeConfigMaps token repo env fullSha (nub [b | r <- svcResults, Just b <- [srBaseCommit r]]) allFiles unverified
    refs <- mapM (\s -> (,) s <$> readServiceRefs (scAppGroup s) (scService s)) selected
    let envs = [e | (e, _) <- envChanges, not (T.null (ecEnvVar e))]
        cms = [c | (Just c, _) <- cmChanges]
        envErrs = concat [e | (_, e) <- envChanges]
        cmErrs = concat [e | (_, e) <- cmChanges]
        applicable = [t | t <- rcConfigMaps repo, maybe True (\e -> T.toLower e == T.toLower env) (cmEnv t)]
        ignored = defaultIgnoredConfigMaps ++ rcIgnoreConfigMaps repo
        svcBlockers = [srService s <> ": " <> r | s <- svcResults, Just r <- [srReason s]]
        watchersFor s = maybe [] (\t -> fromMaybe [evRepoPath t] (evWatch t)) (scEnvVar s) ++ [p | t <- applicable, p <- M.elems (cmFiles t)]
        unmapped =
            nub
                [ f
                | s <- selected
                , r <- resultFor s
                , f <- srDhallHits r
                , not (matchesAny (watchersFor s) f)
                ]
        unmappedBlockers = ["dhall file " <> f <> " changed but no env-var or configmap rule watches it, so it cannot be applied automatically" | f <- unmapped]
        changedCmNames = map ccName cms
        coverage =
            let one (s, ref) =
                    let envState = [(evEnvVar t, ecState e) | Just t <- [scEnvVar s], e <- take 1 [x | x <- envs, ecService x == scService s]]
                     in case ref of
                            Left why -> SvcCoverage (scService s) Nothing [] [] (listToMaybe envState) (Just why)
                            Right d ->
                                SvcCoverage
                                    { covService = scService s
                                    , covDeployment = Just (drDeployment d)
                                    , covConfigMaps =
                                        [ (n, cmStatus n)
                                        | n <- drConfigMaps d
                                        ]
                                    , covSecrets = drSecrets d
                                    , covEnvVar = listToMaybe envState
                                    , covError = Nothing
                                    }
                cmStatus n
                    | n `elem` ignored = "ignored"
                    | n `elem` changedCmNames = "changed"
                    | Just t <- listToMaybe [t' | t' <- applicable, cmName t' == n] =
                        if any (\p -> unverified || any (pathMatches p) allFiles) (M.elems (cmFiles t)) then "unchanged" else "not_triggered"
                    | otherwise = "not_tracked"
                svcCov = map one refs
                complete =
                    null unmapped
                        && all (\c -> covError c == Nothing && all ((`elem` ["changed", "unchanged", "not_triggered", "ignored"]) . snd) (covConfigMaps c)) svcCov
             in Coverage svcCov unmapped complete
        blockers =
            ["unknown service: " <> u | u <- unknown]
                ++ svcBlockers
                ++ envErrs
                ++ cmErrs
                ++ unmappedBlockers
        liveFp =
            hashTexts $
                concat [["cm", ccName c] ++ concat [[k, M.findWithDefault "" k (ccLiveData c)] | k <- changedKeys c] | c <- cms]
                    ++ concat [["env", ecService e, fromMaybe "" (ecLiveB64 e)] | e <- envs, ecState e == "changed"]
        contentH =
            hashTexts $
                concat [["cm", ccName c] ++ concat [[k, M.findWithDefault "" k (ccNewData c)] | k <- changedKeys c] | c <- cms]
                    ++ concat [["env", ecService e, fromMaybe "" (ecNewB64 e)] | e <- envs, ecState e == "changed"]
    pure
        Analysis
            { anRepo = rcName repo
            , anEnv = env
            , anBranch = mBranch
            , anCommit = fullSha
            , anServices = svcResults
            , anEnvChanges = envs
            , anConfigMaps = cms
            , anSecretFiles = secretHits
            , anSecretUnverifiable = unverified
            , anBlockers = blockers
            , anCoverage = coverage
            , anLiveFingerprint = liveFp
            , anContentHash = contentH
            }
  where
    triggeredFor s resultFor = case (scEnvVar s, resultFor s) of
        (Just t, r : _) -> not (srVerified r) || any (matchesAny (fromMaybe [evRepoPath t] (evWatch t))) (srChangedFiles r)
        _ -> True
    changedKeys c = [k | k <- M.keys (ccNewData c), M.lookup k (ccNewData c) /= M.lookup k (ccLiveData c)]

analyzeService :: AuthedPerson -> Text -> RepoCfg -> Text -> ServiceCfg -> Flow SvcResult
analyzeService ap token repo fullSha svc = do
    running <- resolveRunningVersionH ap (Just (scAppGroup svc)) (Just (scService svc))
    let oldV = case running of
            Object o -> case KM.lookup "oldVersion" o of
                Just (String v) -> Just v
                _ -> Nothing
            _ -> Nothing
        base = oldV >>= toCommitId
        slug = repoSlug repo
        mk files verified reason diffUrl =
            SvcResult
                { srService = scService svc
                , srAppGroup = scAppGroup svc
                , srOldVersion = oldV
                , srBaseCommit = base
                , srDiffUrl = diffUrl
                , srDhallHits = [f | f <- files, any (matches f) (scDhallFiles svc)]
                , srChangedFiles = files
                , srVerified = verified
                , srReason = reason
                }
        matches f d = f == d || ("/" <> d) `T.isSuffixOf` f
    case base of
        Nothing -> pure (mk [] False (Just "could not determine the currently deployed commit") Nothing)
        Just b -> do
            cmp <- compareFiles token slug b fullSha
            let diffUrl = buildDiffLink (Just slug) b (T.take 6 fullSha)
            pure $ case cmp of
                Left e -> mk [] False (Just ("GitHub compare failed: " <> e)) diffUrl
                Right c
                    | crTruncated c -> mk (crFiles c) False (Just "diff too large to verify (GitHub caps compare at 300 files)") diffUrl
                    | otherwise -> mk (crFiles c) True Nothing diffUrl

-- | (change, blockers). Services with no envVar target contribute nothing.
analyzeEnv :: Text -> Text -> Text -> Maybe Text -> Bool -> ServiceCfg -> Flow (EnvChange, [Text])
analyzeEnv token slug fullSha baseSha triggered svc = case scEnvVar svc of
    Nothing -> pure (EnvChange (scService svc) (scAppGroup svc) "" "unchanged" Nothing Nothing Nothing Nothing, [])
    Just tgt | not triggered -> pure (EnvChange (scService svc) (scAppGroup svc) (evEnvVar tgt) "not_triggered" Nothing Nothing Nothing Nothing, [])
    Just tgt -> do
        let var = evEnvVar tgt
            mkErr st e = (EnvChange (scService svc) (scAppGroup svc) var st Nothing Nothing Nothing (Just e), [scService svc <> ": " <> e])
        live <- readServiceEnv (scAppGroup svc) (scService svc)
        newContent <- getFileAt token slug (evRepoPath tgt) fullSha
        baseContent <- case (evMode tgt, baseSha) of
            (Just "merge", Just b) -> Just <$> getFileAt token slug (evRepoPath tgt) b
            (Just "merge", Nothing) -> pure (Just (Left "the deployed commit is unknown, so there is no merge base"))
            _ -> pure Nothing
        pure $ case (live, newContent) of
            (Left e, _) -> mkErr "error" e
            (_, Left e) -> mkErr "error" e
            (Right le, Right repoNew) -> case envVarValue var (leEnv le) of
                Nothing -> mkErr "live_absent" ("env var " <> var <> " is not present on the running deployment")
                Just liveB64 -> case decodeB64Text liveB64 of
                    Left why -> (EnvChange (scService svc) (scAppGroup svc) var "undecodable" Nothing Nothing (Just liveB64) (Just why), [scService svc <> ": live " <> var <> " " <> why])
                    Right liveTxt -> case mergedNew liveTxt repoNew baseContent of
                      Left why -> mkErr "error" ("cannot merge the repo change onto the live " <> var <> ": " <> why)
                      Right new
                        | T.stripEnd liveTxt == T.stripEnd new -> (EnvChange (scService svc) (scAppGroup svc) var "unchanged" Nothing Nothing (Just liveB64) Nothing, [])
                        | otherwise ->
                            ( EnvChange (scService svc) (scAppGroup svc) var "changed"
                                (Just (diffText (scService svc <> " · " <> var <> " (base64-decoded)") liveTxt new))
                                (Just (encodeB64Text new))
                                (Just liveB64)
                                Nothing
                            , []
                            )
  where
    mergedNew _ repoNew Nothing = Right repoNew
    mergedNew liveTxt repoNew (Just (Right b)) = merge3 b liveTxt repoNew
    mergedNew _ _ (Just (Left e)) = Left ("cannot read the base file: " <> e)

analyzeConfigMaps :: Text -> RepoCfg -> Text -> Text -> [Text] -> [Text] -> Bool -> Flow [(Maybe CmChange, [Text])]
analyzeConfigMaps token repo env fullSha bases changedFiles unverified = mapM one applicable
  where
    slug = repoSlug repo
    applicable = [t | t <- rcConfigMaps repo, maybe True (\e -> T.toLower e == T.toLower env) (cmEnv t)]
    triggeredFiles t = [(k, p) | (k, p) <- M.toList (cmFiles t), unverified || any (pathMatches p) changedFiles]
    one t
        | null (triggeredFiles t) = pure (Nothing, [])
        | otherwise = do
        live <- readConfigMap (cmAppGroup t) (cmName t)
        case live of
            Left e -> pure (Nothing, [e])
            Right (ns, liveData) -> do
                fetched <- mapM (\(k, p) -> (,) k <$> getFileAt token slug p fullSha) (triggeredFiles t)
                -- merge mode: the live content is an env-specific variant of the repo file, so only the
                -- repo change (deployed commit -> target commit) is applied onto it.
                bases' <-
                    if cmMerge t
                        then case bases of
                            [b] -> mapM (\(k, p) -> (,) k <$> getFileAt token slug p b) (triggeredFiles t)
                            _ -> pure [(k, Left "services were deployed from different commits (or the deployed commit is unknown), so there is no single merge base") | (k, _) <- triggeredFiles t]
                        else pure []
                let baseOf k = lookup k bases'
                    resolve k v
                        | not (cmMerge t) = Right v
                        | otherwise = case (baseOf k, M.lookup k liveData) of
                            (Just (Right b), Just l) -> merge3 b l v
                            (Just (Left e), _) -> Left ("cannot read the base file: " <> e)
                            (_, Nothing) -> Left "key is absent from the live configmap"
                            _ -> Left "no merge base"
                    resolved = [(k, r) | (k, Right v) <- fetched, r <- [resolve k v]]
                    errs = [cmName t <> "/" <> k <> ": " <> e | (k, Left e) <- fetched] ++ [cmName t <> "/" <> k <> ": " <> e | (k, Left e) <- resolved]
                    news = M.fromList [(k, v) | (k, Right v) <- resolved]
                    changed = M.filterWithKey (\k v -> fmap T.stripEnd (M.lookup k liveData) /= Just (T.stripEnd v)) news
                    diffs = [diffText (cmName t <> " · " <> k) (M.findWithDefault "" k liveData) v | (k, v) <- M.toList changed]
                if M.null changed
                    then pure (Nothing, errs)
                    else
                        pure
                            ( Just
                                CmChange
                                    { ccName = cmName t
                                    , ccAppGroup = cmAppGroup t
                                    , ccNamespace = ns
                                    , ccDiffs = diffs
                                    , ccLiveData = liveData
                                    , ccNewData = M.union changed liveData
                                    }
                            , errs
                            )

