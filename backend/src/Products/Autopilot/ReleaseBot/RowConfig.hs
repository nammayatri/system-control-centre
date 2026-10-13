{-# LANGUAGE OverloadedStrings #-}

{- | Release-bot rules stored ON the deployment config rows themselves
(@deployment_config.release_bot_config@, migration 0054), so each rule sits next to
the app group / service it is about instead of in one far-away JSON blob.

  * __product-level row__ (app group, @service IS NULL@): the env (@PROD@/@MASTER@),
    allowed branches, the Xyne channel ids, the Jenkins job, secret-file patterns,
    and which configmap keys are tracked from which repo file. The repo itself is
    the row's existing @repo_name@ column.
  * __service-level row__: aliases, dhall files, the @DHALL_CONFIG@-style env var
    rule, default rollout.

'buildFromRows' folds those rows into the same 'ProdReleaseConfig' the rest of the
bot already consumes, so nothing downstream knows or cares where it came from. It
is pure and strict: a conflict (two app groups naming different Jenkins jobs for the
same repo, one channel mapped to two envs, a service whose app group has no repo
config) is an error, never a silent pick.
-}
module Products.Autopilot.ReleaseBot.RowConfig (
    ProductBot (..),
    ServiceBot (..),
    CmRow (..),
    checkBotField,
    validateProductBot,
    validateServiceBot,
    buildFromRows,
) where

import Control.Monad (forM, when)
import Data.Aeson (FromJSON (..), eitherDecodeStrict, withObject, (.!=), (.:), (.:?))
import Data.List (nub, sort)
import qualified Data.Map.Strict as M
import Data.Maybe (fromMaybe, isNothing)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Products.Autopilot.DiffLink (normalizeRepo)
import Products.Autopilot.ProdRelease.Config
import Products.Autopilot.Types.Storage.Schema (DeploymentConfig, DeploymentConfigT (..))

data CmRow = CmRow
    { crName :: Text
    , crFiles :: M.Map Text Text
    -- ^ configmap data key -> repo path
    , crMerge :: Bool
    -- ^ @"mode": "merge"@ (see 'cmMerge')
    }
    deriving (Show, Eq)

instance FromJSON CmRow where
    parseJSON = withObject "configMap" $ \o -> CmRow <$> o .: "name" <*> o .: "files" <*> (maybe False (== ("merge" :: Text)) <$> o .:? "mode")

data ProductBot = ProductBot
    { pbEnv :: Text
    , pbBranches :: [Text]
    , pbChannels :: [Text]
    , pbJenkins :: Maybe JenkinsCfg
    , pbSecretFiles :: [Text]
    , pbConfigMaps :: [CmRow]
    , pbIgnore :: [Text]
    }
    deriving (Show)

instance FromJSON ProductBot where
    parseJSON = withObject "release_bot_config (app group)" $ \o ->
        ProductBot
            <$> o .: "env"
            <*> (o .:? "branches" .!= [])
            <*> (o .:? "channels" .!= [])
            <*> o .:? "jenkins"
            <*> (o .:? "secretFiles" .!= [])
            <*> (o .:? "configMaps" .!= [])
            <*> (o .:? "ignoreConfigMaps" .!= [])

data ServiceBot = ServiceBot
    { sbAliases :: [Text]
    , sbDhallFiles :: [Text]
    , sbEnvVar :: Maybe EnvVarTarget
    , sbRollout :: [RolloutStepCfg]
    , sbEnv :: Maybe Text
    , sbSqlSchemas :: [Text]
    }
    deriving (Show)

instance FromJSON ServiceBot where
    parseJSON = withObject "release_bot_config (service)" $ \o ->
        ServiceBot
            <$> (o .:? "aliases" .!= [])
            <*> (o .:? "dhallFiles" .!= [])
            <*> o .:? "envVar"
            <*> (o .:? "defaultRollout" .!= [])
            <*> o .:? "env"
            <*> (o .:? "sqlSchemas" .!= [])

blank :: Text -> Bool
blank = T.null . T.strip

decodeText :: (FromJSON a) => Text -> Either Text a
decodeText t = either (Left . T.pack) Right (eitherDecodeStrict (TE.encodeUtf8 t))

validateProductBot :: Text -> Either Text ProductBot
validateProductBot t = do
    pb <- decodeText t
    when (blank (pbEnv pb)) (Left "\"env\" is required (PROD or MASTER)")
    when (any blank (pbBranches pb)) (Left "\"branches\" contains an empty name")
    when (any blank (pbChannels pb)) (Left "\"channels\" contains an empty id")
    when (any (\c -> blank (crName c) || M.null (crFiles c) || any blank (M.elems (crFiles c))) (pbConfigMaps pb)) (Left "every configMaps entry needs a name and files {key: repoPath}")
    pure pb

validateServiceBot :: Text -> Either Text ServiceBot
validateServiceBot t = do
    sb <- decodeText t
    case sbEnvVar sb of
        Just e | blank (evEnvVar e) || blank (evRepoPath e) -> Left "envVar needs both \"envVar\" and \"repoPath\""
        _ -> Right ()
    pure sb

{- | Interpret the optional @releaseBotConfig@ field of a save request.
@Nothing@ = leave the stored rules untouched; blank = clear them; otherwise it is validated
and stored. @Right (Just v)@ means "write @v@" (@Nothing@ clears).
-}
checkBotField :: Bool -> Maybe Text -> Either Text (Maybe (Maybe Text))
checkBotField _ Nothing = Right Nothing
checkBotField _ (Just t) | blank t = Right (Just Nothing)
checkBotField isProduct (Just t) =
    (if isProduct then () <$ validateProductBot t else () <$ validateServiceBot t) >> Right (Just (Just t))

hasCfg :: DeploymentConfig -> Bool
hasCfg r = maybe False (not . blank) (dcReleaseBotConfig r)

{- | Fold every configured row into one 'ProdReleaseConfig'. @Left@ names the offending
app group / repo so the operator knows which row to fix.
-}
buildFromRows :: [DeploymentConfig] -> Either Text ProdReleaseConfig
buildFromRows rows = do
    prods <- forM [r | r <- rows, isNothing (dcService r), hasCfg r] $ \r -> do
        pb <- wrap (dcAppGroup r) (validateProductBot (fromMaybe "" (dcReleaseBotConfig r)))
        slug <- case dcRepoName r of
            Just rn | not (blank (normalizeRepo rn)) -> Right (normalizeRepo rn)
            _ -> Left (dcAppGroup r <> ": has release-bot rules but no repo_name (set the GitHub repo on the app group)")
        pure (slug, r, pb)
    svcRows <- forM [r | r <- rows, Just _ <- [dcService r], hasCfg r] $ \r -> do
        sb <- wrap (dcAppGroup r <> "/" <> fromMaybe "" (dcService r)) (validateServiceBot (fromMaybe "" (dcReleaseBotConfig r)))
        pure (r, sb)
    channels <- mergeChannels [ChannelCfg c slug (pbEnv pb) | (slug, _, pb) <- prods, c <- pbChannels pb]
    repos <- forM (nub (sort (map lowerKey' [s | (s, _, _) <- prods]))) $ \key -> do
        let grp = [(slug, r, pb) | (slug, r, pb) <- prods, T.toLower slug == key]
            slug0 = case grp of ((s, _, _) : _) -> s; [] -> key
            groups = map (\(_, r, _) -> dcAppGroup r) grp
        -- Jenkins is per ENV: a PROD and a MASTER release of one repo push to different clouds.
        byEnv <- forM (nub (sort [T.toUpper (pbEnv pb) | (_, _, pb) <- grp])) $ \env ->
            case nub [j | (_, _, pb) <- grp, T.toUpper (pbEnv pb) == env, Just j <- [pbJenkins pb]] of
                [j] -> Right (env, j)
                [] -> Left (slug0 <> " (" <> env <> "): no \"jenkins\" job configured on any of its " <> env <> " app groups (" <> T.intercalate ", " groups <> ")")
                _ -> Left (slug0 <> " (" <> env <> "): app groups " <> T.intercalate ", " groups <> " define different Jenkins jobs/params for the same repo and env")
        let jenkins = snd (head byEnv)
        let branches = nub (concat [pbBranches pb | (_, _, pb) <- grp])
        when (null branches) (Left (slug0 <> ": no \"branches\" configured"))
        services <- forM [(r, sb) | (r, sb) <- svcRows, (_, pr, _) <- grp, dcAppGroup pr == dcAppGroup r] $ \(r, sb) -> do
            let env = fromMaybe (envOf (dcAppGroup r) grp) (sbEnv sb)
            pure
                ServiceCfg
                    { scService = fromMaybe "" (dcService r)
                    , scAppGroup = dcAppGroup r
                    , scAliases = sbAliases sb
                    , scDhallFiles = sbDhallFiles sb
                    , scEnvVar = sbEnvVar sb
                    , scDefaultRollout = sbRollout sb
                    , scEnv = Just env
                    , scSqlSchemas = sbSqlSchemas sb
                    }
        pure
            RepoCfg
                { rcName = slug0
                , rcUrl = "https://github.com/" <> slug0
                , rcBranches = branches
                , rcJenkins = jenkins
                , rcServices = services
                , rcSecretFiles = nub (concat [pbSecretFiles pb | (_, _, pb) <- grp])
                , rcConfigMaps = [ConfigMapTarget (crName c) (dcAppGroup r) (crFiles c) (Just (pbEnv pb)) (crMerge c) | (_, r, pb) <- grp, c <- pbConfigMaps pb]
                , rcIgnoreConfigMaps = nub (concat [pbIgnore pb | (_, _, pb) <- grp])
                , rcJenkinsByEnv = M.fromList byEnv
                }
    -- A service row configured under an app group that has no repo-level rules can never run: say so.
    let configuredGroups = [dcAppGroup r | (_, r, _) <- prods]
    case [r | (r, _) <- svcRows, dcAppGroup r `notElem` configuredGroups] of
        (r : _) -> Left (dcAppGroup r <> "/" <> fromMaybe "" (dcService r) <> ": service has release-bot rules but its app group has none (env/repo/jenkins live on the app group row)")
        [] -> Right ProdReleaseConfig{prcRepos = repos, prcChannels = channels}
  where
    wrap who = either (\e -> Left (who <> ": " <> e)) Right
    lowerKey' = T.toLower
    envOf ag grp = case [pbEnv pb | (_, r, pb) <- grp, dcAppGroup r == ag] of (e : _) -> e; [] -> ""

mergeChannels :: [ChannelCfg] -> Either Text [ChannelCfg]
mergeChannels cs = go [] cs
  where
    go acc [] = Right (reverse acc)
    go acc (c : rest) = case [x | x <- acc, chId x == chId c] of
        [] -> go (c : acc) rest
        (x : _)
            | x == c -> go acc rest
            | otherwise -> Left ("channel " <> chId c <> " is mapped to two different repo/env pairs (" <> chRepo x <> "/" <> chEnv x <> " and " <> chRepo c <> "/" <> chEnv c <> ")")
