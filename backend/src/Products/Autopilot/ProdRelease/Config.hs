{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}

{- | Prod-release assistant config: which repos can be released, their release
branches, the Jenkins job that builds them, and — per service — the dhall
file(s) whose change blocks release-tracker creation.

Lives in a JSON file (path from @SC_PROD_RELEASE_CONFIG@, default
@./dhall-configs/prod-release-config.json@) so it can be edited without a
rebuild. It is re-read per request: the file is tiny and this keeps edits live.
-}
module Products.Autopilot.ProdRelease.Config (
    ProdReleaseConfig (..),
    RepoCfg (..),
    JenkinsCfg (..),
    ServiceCfg (..),
    EnvVarTarget (..),
    ConfigMapTarget (..),
    ChannelCfg (..),
    RolloutStepCfg (..),
    loadProdReleaseConfig,
    parseProdReleaseConfig,
    findChannel,
    channelsFor,
    findChannelRepo,
    jenkinsFor,
    jenkinsForSvc,
    JenkinsPatch (..),
    noPatch,
    forEnv,
    isSecretFile,
    pathMatches,
    matchesAny,
    defaultIgnoredConfigMaps,
    findRepo,
    repoSlug,
) where

import Control.Exception (SomeException, try)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Data.Aeson (FromJSON (..), ToJSON (..), eitherDecodeFileStrict, eitherDecodeStrict, genericParseJSON, genericToJSON, object, withObject, (.!=), (.:), (.:?), (.=))
import Data.Aeson.Types (Options (..), defaultOptions)
import Data.Char (toLower)
import qualified Data.Map.Strict as M
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import GHC.Generics (Generic)
import System.Environment (lookupEnv)

data EnvVarTarget = EnvVarTarget
    { evEnvVar :: Text
    -- ^ Env var on the deployment that carries the base64 dhall (e.g. @DHALL_CONFIG@)
    , evRepoPath :: Text
    -- ^ Repo path of the dhall whose raw content is base64'd into that env var
    , evWatch :: Maybe [Text]
    -- ^ Changed-file patterns that TRIGGER the check of this env var (default: just 'evRepoPath')
    , evMode :: Maybe Text
    -- ^ @"merge"@: the live value is an env-specific variant of the repo file, so apply only the repo
    -- change (deployed commit -> target commit) onto it (3-way) instead of replacing it
    }
    deriving (Show, Generic)

instance FromJSON EnvVarTarget where
    parseJSON = genericParseJSON (jsonOpts 2)
instance ToJSON EnvVarTarget where
    toJSON = genericToJSON (jsonOpts 2)

data RolloutStepCfg = RolloutStepCfg
    { rsRolloutPercent :: Int
    , rsCooloffMinutes :: Int
    , rsPodCount :: Int
    }
    deriving (Show, Generic)

instance FromJSON RolloutStepCfg where
    parseJSON = genericParseJSON (jsonOpts 2)
instance ToJSON RolloutStepCfg where
    toJSON = genericToJSON (jsonOpts 2)

data ServiceCfg = ServiceCfg
    { scService :: Text
    -- ^ SCC service name, e.g. @backend-production-pilot@
    , scAppGroup :: Text
    -- ^ SCC app group the service belongs to (release tracker's appGroup)
    , scAliases :: [Text]
    -- ^ Plain-English names the intent parser may map to this service ("rider app")
    , scDhallFiles :: [Text]
    -- ^ Repo-relative dhall paths (or bare file names) that block tracker creation
    , scEnvVar :: Maybe EnvVarTarget
    -- ^ Where this service's dhall lives in the deployment env (diffed base64-decoded)
    , scDefaultRollout :: [RolloutStepCfg]
    -- ^ Rollout used when the bot creates the tracker (empty = single 100% step)
    , scEnv :: Maybe Text
    -- ^ Only releasable from channels of this env (@PROD@ / @MASTER@); absent = any
    , scJenkinsParams :: M.Map Text Text
    -- ^ Extra Jenkins parameters for THIS service's build (e.g. @app@), merged over the repo's fixed
    -- ones. Services with different params are built by separate Jenkins builds.
    , scSqlSchemas :: [Text]
    -- ^ Database schemas this service uses (e.g. @atlas_app@). SQL statements in the release that
    -- touch one of them are collected for this service before its tracker is created.
    , scJenkins :: Maybe JenkinsPatch
    -- ^ This service's own Jenkins settings, laid over the app group's (job, commit param/prefix/length,
    -- fixed params). A service with no group-level Jenkins must set at least the job here.
    , scSyncSecondary :: Bool
    -- ^ Also sync the release to the secondary cloud (the create form's "Sync to ..." toggle): the
    -- tracker is created with @isReleaseSync@ and a secondary stagger sized off the secondary cluster.
    , scBranches :: [Text]
    -- ^ Branches this service releases from (e.g. @prodHotPush-Frontend@); empty = the repo's branches.
    -- The first one is the default when the message names no branch.
    }
    deriving (Show, Generic)

instance FromJSON ServiceCfg where
    parseJSON = withObject "ServiceCfg" $ \o ->
        ServiceCfg
            <$> o .: "service"
            <*> o .: "appGroup"
            <*> (o .:? "aliases" .!= [])
            <*> (o .:? "dhallFiles" .!= [])
            <*> o .:? "envVar"
            <*> (o .:? "defaultRollout" .!= [])
            <*> o .:? "env"
            <*> (o .:? "jenkinsParams" .!= M.empty)
            <*> (o .:? "sqlSchemas" .!= [])
            <*> o .:? "jenkins"
            <*> (o .:? "syncToSecondary" .!= False)
            <*> (o .:? "branches" .!= [])
instance ToJSON ServiceCfg where
    toJSON s =
        object
            [ "service" .= scService s
            , "appGroup" .= scAppGroup s
            , "aliases" .= scAliases s
            , "dhallFiles" .= scDhallFiles s
            , "envVar" .= scEnvVar s
            , "defaultRollout" .= scDefaultRollout s
            , "env" .= scEnv s
            , "jenkinsParams" .= scJenkinsParams s
            , "sqlSchemas" .= scSqlSchemas s
            , "jenkins" .= scJenkins s
            , "syncToSecondary" .= scSyncSecondary s
            , "branches" .= scBranches s
            ]

-- | A configmap whose files are tracked from the repo (e.g. @beckn-production-pilot@).
data ConfigMapTarget = ConfigMapTarget
    { cmName :: Text
    , cmAppGroup :: Text
    -- ^ SCC app group whose namespace holds the configmap
    , cmFiles :: M.Map Text Text
    -- ^ configmap data key -> repo path (e.g. @common.dhall@ -> @dhall-configs/prod/common.dhall@)
    , cmEnv :: Maybe Text
    -- ^ Only for requests from channels of this env (@PROD@ / @MASTER@); absent = all
    , cmMerge :: Bool
    -- ^ @mode: "merge"@ — the live content is an env-specific variant of the repo file, so apply only
    -- the repo change (deployed commit -> target commit) onto it (3-way) instead of replacing it
    }
    deriving (Show, Generic)

instance FromJSON ConfigMapTarget where
    parseJSON = withObject "ConfigMapTarget" $ \o ->
        ConfigMapTarget <$> o .: "name" <*> o .: "appGroup" <*> o .: "files" <*> o .:? "env" <*> (maybe False (== ("merge" :: Text)) <$> o .:? "mode")
instance ToJSON ConfigMapTarget where
    toJSON c = object ["name" .= cmName c, "appGroup" .= cmAppGroup c, "files" .= cmFiles c, "env" .= cmEnv c, "mode" .= (if cmMerge c then "merge" else "replace" :: Text)]

-- | An Xyne channel the bot accepts release requests from.
data ChannelCfg = ChannelCfg
    { chId :: Text
    , chRepo :: Text
    , chEnv :: Text
    -- ^ @PROD@ or @MASTER@ — decides which configmaps/env targets apply
    }
    deriving (Show, Eq, Generic)

instance FromJSON ChannelCfg where
    parseJSON = genericParseJSON (jsonOpts 2)
instance ToJSON ChannelCfg where
    toJSON = genericToJSON (jsonOpts 2)

data JenkinsCfg = JenkinsCfg
    { jcJob :: Text
    -- ^ Full job name, e.g. @nammayatri/cloud-jenkins/main@
    , jcCommitParam :: Maybe Text
    -- ^ Build parameter that carries the commit sha. Absent = the job takes no commit and always
    -- builds the branch head: the bot then only releases the branch's CURRENT head commit.
    , jcCommitLength :: Maybe Int
    -- ^ Send only the first N chars of the sha. The cloud-jenkins job takes the FIRST 6
    -- ("Enter first 6 digit of commit id") and uses it verbatim as the image tag, so it
    -- must match the 6-char version SCC records. Default 6.
    , jcCommitPrefix :: Maybe Text
    -- ^ Prepended to the sent sha, e.g. @"master-"@ gives @master-840d27@ (sandbox image tags)
    , jcFixedParams :: M.Map Text Text
    -- ^ Always-sent params; use these to select the prod envs only
    }
    deriving (Show, Eq, Generic)

instance FromJSON JenkinsCfg where
    parseJSON = genericParseJSON (jsonOpts 2)
instance ToJSON JenkinsCfg where
    toJSON = genericToJSON (jsonOpts 2)

-- | Service-level Jenkins overrides: every field optional, laid over the app group's 'JenkinsCfg'.
data JenkinsPatch = JenkinsPatch
    { jpJob :: Maybe Text
    , jpCommitParam :: Maybe Text
    , jpCommitLength :: Maybe Int
    , jpCommitPrefix :: Maybe Text
    , jpFixedParams :: M.Map Text Text
    }
    deriving (Show, Eq, Generic)

noPatch :: JenkinsPatch
noPatch = JenkinsPatch Nothing Nothing Nothing Nothing M.empty

instance FromJSON JenkinsPatch where
    parseJSON = withObject "jenkins" $ \o ->
        JenkinsPatch <$> o .:? "job" <*> o .:? "commitParam" <*> o .:? "commitLength" <*> o .:? "commitPrefix" <*> (o .:? "fixedParams" .!= M.empty)
instance ToJSON JenkinsPatch where
    toJSON p = object ["job" .= jpJob p, "commitParam" .= jpCommitParam p, "commitLength" .= jpCommitLength p, "commitPrefix" .= jpCommitPrefix p, "fixedParams" .= jpFixedParams p]

data RepoCfg = RepoCfg
    { rcName :: Text
    , rcUrl :: Text
    , rcBranches :: [Text]
    , rcJenkins :: JenkinsCfg
    , rcServices :: [ServiceCfg]
    , rcSecretFiles :: [Text]
    -- ^ Path patterns (@*@ wildcard) of secret files; a change in the diff is flagged
    , rcConfigMaps :: [ConfigMapTarget]
    , rcIgnoreConfigMaps :: [Text]
    -- ^ Configmaps a deployment may reference that need no review (added to the built-ins)
    , rcJenkinsByEnv :: M.Map Text JenkinsCfg
    -- ^ Env (upper-case, @PROD@/@MASTER@) -> Jenkins settings. A PROD and a MASTER release of the
    -- same repo send different build parameters (which clouds to push to), so Jenkins is per env.
    -- Falls back to 'rcJenkins' for an env not listed.
    , rcRequireChecks :: Bool
    -- ^ Only start the Jenkins build once every GitHub check / status on the commit has passed
    -- (waits while they are pending, stops if one fails).
    , rcIgnoreChecks :: [Text]
    -- ^ Check names (case-insensitive substring) that never gate the build
    }
    deriving (Show, Generic)

instance FromJSON RepoCfg where
    parseJSON = withObject "RepoCfg" $ \o ->
        RepoCfg
            <$> o .: "name"
            <*> o .: "url"
            <*> o .: "branches"
            <*> o .: "jenkins"
            <*> o .: "services"
            <*> (o .:? "secretFiles" .!= [])
            <*> (o .:? "configMaps" .!= [])
            <*> (o .:? "ignoreConfigMaps" .!= [])
            <*> (o .:? "jenkinsByEnv" .!= M.empty)
            <*> (o .:? "requireChecks" .!= False)
            <*> (o .:? "ignoreChecks" .!= [])
instance ToJSON RepoCfg where
    toJSON r =
        object
            [ "name" .= rcName r
            , "url" .= rcUrl r
            , "branches" .= rcBranches r
            , "jenkins" .= rcJenkins r
            , "services" .= rcServices r
            , "secretFiles" .= rcSecretFiles r
            , "configMaps" .= rcConfigMaps r
            , "ignoreConfigMaps" .= rcIgnoreConfigMaps r
            , "jenkinsByEnv" .= rcJenkinsByEnv r
            , "requireChecks" .= rcRequireChecks r
            , "ignoreChecks" .= rcIgnoreChecks r
            ]

data ProdReleaseConfig = ProdReleaseConfig
    { prcRepos :: [RepoCfg]
    , prcChannels :: [ChannelCfg]
    }
    deriving (Show, Generic)

instance FromJSON ProdReleaseConfig where
    parseJSON = withObject "ProdReleaseConfig" $ \o ->
        ProdReleaseConfig <$> o .: "repos" <*> (o .:? "channels" .!= [])
instance ToJSON ProdReleaseConfig where
    toJSON c = object ["repos" .= prcRepos c, "channels" .= prcChannels c]

-- | Drop the @n@-char field prefix and lower-case the first remaining char.
jsonOpts :: Int -> Options
jsonOpts n = defaultOptions{fieldLabelModifier = lowerFirst . drop n}
  where
    lowerFirst (c : cs) = toLower c : cs
    lowerFirst [] = []

loadProdReleaseConfig :: (MonadIO m) => m (Either Text ProdReleaseConfig)
loadProdReleaseConfig = liftIO $ do
    path <- maybe "./dhall-configs/prod-release-config.json" id <$> lookupEnv "SC_PROD_RELEASE_CONFIG"
    r <- try (eitherDecodeFileStrict path) :: IO (Either SomeException (Either String ProdReleaseConfig))
    pure $ case r of
        Left e -> Left ("cannot read " <> T.pack path <> ": " <> T.pack (show e))
        Right (Left e) -> Left ("invalid " <> T.pack path <> ": " <> T.pack e)
        Right (Right c) -> Right c

findRepo :: ProdReleaseConfig -> Text -> Maybe RepoCfg
findRepo cfg name = case filter ((== T.toLower name) . T.toLower . rcName) (prcRepos cfg) of
    (r : _) -> Just r
    [] -> Nothing

-- | @owner/repo@ slug from the configured URL (tolerates @.git@ / trailing slash).
repoSlug :: RepoCfg -> Text
repoSlug r =
    let u = T.dropWhileEnd (== '/') (T.strip (rcUrl r))
        noGit = if ".git" `T.isSuffixOf` u then T.dropEnd 4 u else u
        parts = filter (not . T.null) (T.splitOn "/" noGit)
     in T.intercalate "/" (drop (length parts - 2) parts)

findChannel :: ProdReleaseConfig -> Text -> Maybe ChannelCfg
findChannel cfg cid = case filter ((== cid) . chId) (prcChannels cfg) of
    (c : _) -> Just c
    [] -> Nothing

-- | Every repo/env a channel is enabled for (a channel may serve several repos).
channelsFor :: ProdReleaseConfig -> Text -> [ChannelCfg]
channelsFor cfg cid = filter ((== cid) . chId) (prcChannels cfg)

-- | The channel entry for one specific repo (used once a request already belongs to a repo).
findChannelRepo :: ProdReleaseConfig -> Text -> Text -> Maybe ChannelCfg
findChannelRepo cfg cid repo = case [c | c <- channelsFor cfg cid, T.toLower (chRepo c) == T.toLower repo] of
    (c : _) -> Just c
    [] -> Nothing

-- | Does a changed repo path match one of the configured secret-file patterns?
isSecretFile :: RepoCfg -> Text -> Bool
isSecretFile r path = matchesAny (rcSecretFiles r) path

{- | Path pattern match. A pattern matches the full path or, if it has no @/@, the
bare file name; @*@ is a wildcard (also matches across @/@). A pattern is also
accepted as a path suffix (@rider-app.dhall@ matches @a/b/rider-app.dhall@).
-}
pathMatches :: Text -> Text -> Bool
pathMatches pat path = wildcard (T.unpack pat) (T.unpack target)
  where
    target = if T.any (== '/') pat then path else last (T.splitOn "/" path)
    wildcard [] [] = True
    wildcard ('*' : ps) str = any (wildcard ps) (suffixes str)
    wildcard (c : ps) (x : xs) = c == x && wildcard ps xs
    wildcard _ _ = False
    suffixes xs = xs : case xs of [] -> []; (_ : t) -> suffixes t

matchesAny :: [Text] -> Text -> Bool
matchesAny pats path = any (`pathMatches` path) pats

-- | Auto-mounted by Kubernetes / Istio into most pods; never a review target.
defaultIgnoredConfigMaps :: [Text]
defaultIgnoredConfigMaps = ["kube-root-ca.crt", "istio-ca-root-cert"]

{- | The repo as seen from a channel of @env@: only the services meant for that env
(services with no @env@ apply everywhere). Done BEFORE intent parsing so a
plain-English alias can never resolve to another env's service.
-}
forEnv :: Text -> RepoCfg -> RepoCfg
forEnv env r = r{rcServices = filter ok (rcServices r)}
  where
    ok s = maybe True (\e -> T.toLower e == T.toLower env) (scEnv s)

-- | Parse the config from JSON text (the DB-stored copy).
parseProdReleaseConfig :: Text -> Either Text ProdReleaseConfig
parseProdReleaseConfig t = either (Left . ("invalid release_bot_config_json: " <>) . T.pack) Right (eitherDecodeStrict (TE.encodeUtf8 t))

-- | The Jenkins settings for a release into @env@ (case-insensitive), else the repo default.
jenkinsFor :: RepoCfg -> Text -> JenkinsCfg
jenkinsFor r env = M.findWithDefault (rcJenkins r) (T.toUpper env) (rcJenkinsByEnv r)

-- | The Jenkins settings for ONE service: the app group's, with the service's own settings laid over.
jenkinsForSvc :: RepoCfg -> Text -> ServiceCfg -> JenkinsCfg
jenkinsForSvc r env svc = case scJenkins svc of
    Nothing -> base
    Just p ->
        base
            { jcJob = fromMaybe (jcJob base) (jpJob p)
            , jcCommitParam = maybe (jcCommitParam base) Just (jpCommitParam p)
            , jcCommitLength = maybe (jcCommitLength base) Just (jpCommitLength p)
            , jcCommitPrefix = maybe (jcCommitPrefix base) Just (jpCommitPrefix p)
            , jcFixedParams = M.union (jpFixedParams p) (jcFixedParams base)
            }
  where
    base = jenkinsFor r env
