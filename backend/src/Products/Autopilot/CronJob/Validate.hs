{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}

{- | Pre-flight validation for CronJob manifests and env edits.

Three families of check, all reported as 'Issue's so the UI can show them next
to the offending field:

* structure -- kind/apiVersion, name, a schedule Kubernetes will accept, a
  runnable pod template;
* inline credentials -- passwords, tokens, keys and URLs with an embedded
  password that sit in plain text instead of behind a @secretKeyRef@;
* references -- every Secret / ConfigMap the pod mentions must exist in the
  namespace, and every key it asks for must be in it.

The cluster is reached only through the lookup function handed to 'checkRefs',
so everything here is pure or injectable. Lookups return key /names/ only, never
values.
-}
module Products.Autopilot.CronJob.Validate (
    Issue (..),
    Severity (..),
    RefKind (..),
    Ref (..),
    LookupErr (..),
    hasErrors,
    issueText,
    validateCron,
    isDnsName,
    isEnvName,
    isSensitiveName,
    looksLikeSecretValue,
    validateStructure,
    scanManifestSecrets,
    scanEnvEntries,
    collectManifestRefs,
    refsOfEnvEntries,
    checkRefs,
    -- * JSON helpers shared with the routes
    getK,
    getPath,
    setPath,
    arr,
    str,
    podSpecPath,
    containersPath,
) where

import Control.Monad (foldM, forM, unless, when)
import Data.Aeson (ToJSON (..), Value (..), object, (.=))
import Data.Aeson.Key (Key)
import Data.Aeson.Key qualified as K
import Data.Aeson.KeyMap qualified as KM
import Data.Char (isAlphaNum, isAscii, isAsciiLower, isAsciiUpper, isDigit)
import Data.List (nub)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, mapMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Read qualified as TR
import Data.Vector qualified as V

-- ---------------------------------------------------------------------------
-- Issues

data Severity = SevError | SevWarning
    deriving (Eq, Show)

data Issue = Issue
    { issueSeverity :: Severity
    , issueCode :: Text
    , issuePath :: Text
    , issueMessage :: Text
    }
    deriving (Eq, Show)

instance ToJSON Issue where
    toJSON (Issue s c p m) =
        object
            [ "severity" .= (case s of SevError -> "error"; SevWarning -> "warning" :: Text)
            , "code" .= c
            , "path" .= p
            , "message" .= m
            ]

hasErrors :: [Issue] -> Bool
hasErrors = any ((== SevError) . issueSeverity)

issueText :: Issue -> Text
issueText i = (if T.null (issuePath i) then "" else issuePath i <> ": ") <> issueMessage i

err, warn :: Text -> Text -> Text -> Issue
err = Issue SevError
warn = Issue SevWarning

-- ---------------------------------------------------------------------------
-- JSON helpers

getK :: Key -> Value -> Maybe Value
getK k (Object o) = KM.lookup k o
getK _ _ = Nothing

getPath :: [Key] -> Value -> Maybe Value
getPath ks v = foldM (flip getK) v ks

-- | Set the value at a path, creating intermediate objects as needed.
setPath :: [Key] -> Value -> Value -> Value
setPath [] new _ = new
setPath (k : ks) new (Object o) =
    Object (KM.insert k (setPath ks new (fromMaybe (Object mempty) (KM.lookup k o))) o)
setPath (k : ks) new _ = Object (KM.singleton k (setPath ks new (Object mempty)))

arr :: Maybe Value -> [Value]
arr (Just (Array a)) = V.toList a
arr _ = []

str :: Maybe Value -> Maybe Text
str (Just (String t)) = Just t
str _ = Nothing

podSpecPath :: [Key]
podSpecPath = ["spec", "jobTemplate", "spec", "template", "spec"]

containersPath :: [Key]
containersPath = podSpecPath ++ ["containers"]

-- | Containers and init containers with the path (relative to the pod spec) that names them.
containerList :: Value -> [(Text, Value)]
containerList manifest =
    [ (T.pack (kind ++ "[" ++ show i ++ "]"), c)
    | kind <- ["containers", "initContainers"]
    , Just ps <- [getPath podSpecPath manifest]
    , (i, c) <- zip [0 :: Int ..] (arr (getK (K.fromString kind) ps))
    ]

podPrefix :: Text
podPrefix = "spec.jobTemplate.spec.template.spec."

-- ---------------------------------------------------------------------------
-- Names

-- | DNS-1123 subdomain: what Kubernetes requires of Secret, ConfigMap and CronJob names.
isDnsName :: Text -> Bool
isDnsName t =
    not (T.null t)
        && T.length t <= 253
        && T.all (\c -> isAsciiLower c || isDigit c || c == '-' || c == '.') t
        && edge (T.head t)
        && edge (T.last t)
  where
    edge c = isAsciiLower c || isDigit c

-- | Env var names: letters, digits, @_@, @-@, @.@, not starting with a digit.
isEnvName :: Text -> Bool
isEnvName t = case T.uncons t of
    Nothing -> False
    Just (c, rest) -> (isAscii c && (isAsciiLower c || isAsciiUpper c || c `elem` ("_.-" :: String))) && T.all ok rest
  where
    ok c = isAscii c && (isAlphaNum c || c `elem` ("_.-" :: String))

-- ---------------------------------------------------------------------------
-- Schedule

cronMacros :: [Text]
cronMacros = ["@yearly", "@annually", "@monthly", "@weekly", "@daily", "@midnight", "@hourly"]

-- | Accepts what the Kubernetes CronJob controller accepts: five fields (or a macro), no TZ prefix.
validateCron :: Text -> Either Text ()
validateCron raw
    | T.null s = Left "schedule is empty"
    | any (`T.isPrefixOf` s) ["TZ=", "CRON_TZ="] = Left "TZ=/CRON_TZ= prefixes are not allowed; set spec.timeZone instead"
    | "@" `T.isPrefixOf` s = if s `elem` cronMacros then Right () else Left ("unknown schedule macro " <> s)
    | length fs /= 5 = Left "schedule needs 5 fields: minute hour day-of-month month day-of-week"
    | otherwise = sequence_ (zipWith checkField specs fs)
  where
    s = T.strip raw
    fs = T.words s
    specs =
        [ ("minute", 0, 59, [])
        , ("hour", 0, 23, [])
        , ("day-of-month", 1, 31, [])
        , ("month", 1, 12, zip ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"] [1 ..])
        , ("day-of-week", 0, 6, zip ["sun", "mon", "tue", "wed", "thu", "fri", "sat"] [0 ..])
        ]

checkField :: (Text, Int, Int, [(Text, Int)]) -> Text -> Either Text ()
checkField (label, lo, hi, names) field = mapM_ part (T.splitOn "," field)
  where
    bad why = Left (label <> " field \"" <> field <> "\": " <> why)
    part p = do
        let (rng, stepT) = T.breakOn "/" p
        unless (T.null stepT) $ case TR.decimal (T.drop 1 stepT) of
            Right (n, "") | (n :: Int) > 0 -> Right ()
            _ -> bad "step must be a positive number"
        case rng of
            "*" -> Right ()
            "?" -> Right ()
            _ -> case T.splitOn "-" rng of
                [a] -> () <$ bound a
                [a, b] -> do
                    x <- bound a
                    y <- bound b
                    when (x > y) (bad "range start is after its end")
                _ -> bad "malformed range"
    bound t = case TR.decimal t of
        Right (n, "") ->
            if n >= lo && n <= hi then Right n else bad ("value " <> t <> " is outside " <> tshow lo <> "-" <> tshow hi)
        _ -> case lookup (T.toLower t) names of
            Just n -> Right n
            Nothing -> bad ("unrecognised value \"" <> t <> "\"")
    tshow = T.pack . show

-- ---------------------------------------------------------------------------
-- Structure

validateStructure :: Text -> Value -> [Issue]
validateStructure ns m =
    concat
        [ apiVersion
        , kind
        , name
        , namespace
        , schedule
        , policy
        , template
        ]
  where
    apiVersion = case str (getK "apiVersion" m) of
        Just v | v `elem` ["batch/v1", "batch/v1beta1"] -> []
        other -> [err "bad-api-version" "apiVersion" ("must be batch/v1 (got " <> fromMaybe "nothing" other <> ")")]
    kind = case str (getK "kind" m) of
        Just "CronJob" -> []
        other -> [err "bad-kind" "kind" ("must be CronJob (got " <> fromMaybe "nothing" other <> ")")]
    name = case str (getPath ["metadata", "name"] m) of
        Nothing -> [err "missing-name" "metadata.name" "name is required"]
        Just n
            | not (isDnsName n) -> [err "bad-name" "metadata.name" "must be lowercase letters, digits, '-' or '.', starting and ending with a letter or digit"]
            | T.length n > 52 -> [err "name-too-long" "metadata.name" "CronJob names are limited to 52 characters"]
            | otherwise -> []
    namespace = case str (getPath ["metadata", "namespace"] m) of
        Just n | n /= ns -> [err "namespace-mismatch" "metadata.namespace" ("is \"" <> n <> "\" but the selected namespace is \"" <> ns <> "\"")]
        _ -> []
    schedule = case str (getPath ["spec", "schedule"] m) of
        Nothing -> [err "missing-schedule" "spec.schedule" "schedule is required"]
        Just s -> either (\e -> [err "bad-schedule" "spec.schedule" e]) (const []) (validateCron s)
    policy = case str (getPath ["spec", "concurrencyPolicy"] m) of
        Just p | p `notElem` ["Allow", "Forbid", "Replace"] -> [err "bad-concurrency-policy" "spec.concurrencyPolicy" "must be Allow, Forbid or Replace"]
        _ -> []
    template = case getPath podSpecPath m of
        Nothing -> [err "missing-pod-spec" "spec.jobTemplate.spec.template.spec" "pod spec is required"]
        Just ps -> restart ps ++ containers ps
    restart ps = case str (getK "restartPolicy" ps) of
        Just r | r `elem` ["Never", "OnFailure"] -> []
        _ -> [err "bad-restart-policy" (podPrefix <> "restartPolicy") "must be Never or OnFailure for a Job's pods"]
    containers ps = case arr (getK "containers" ps) of
        [] -> [err "no-containers" (podPrefix <> "containers") "at least one container is required"]
        cs -> concat (zipWith container [0 :: Int ..] cs)
    container i c =
        let p = podPrefix <> "containers[" <> T.pack (show i) <> "]"
         in [err "missing-container-name" (p <> ".name") "container name is required" | str (getK "name" c) == Nothing]
                ++ [err "missing-image" (p <> ".image") "image is required" | maybe True T.null (str (getK "image" c))]

-- ---------------------------------------------------------------------------
-- Inline credentials

-- | True for names that read like a credential (@DB_PASSWORD@, @API_TOKEN@, @PRIVATE_KEY@ ...).
isSensitiveName :: Text -> Bool
isSensitiveName n = not benign && (any (`T.isInfixOf` up) keywords || any (`elem` toks) ["PASS", "PWD", "PASSWD"])
  where
    up = T.toUpper n
    toks = T.split (`elem` ("_-." :: String)) up
    -- "TOKEN_URL" or "PASSWORD_FILE" name a place, not the credential itself.
    benign = case reverse toks of
        (l : _) -> l `elem` ["FILE", "PATH", "NAME", "URL", "URI", "HOST", "PORT", "ENDPOINT", "TTL", "EXPIRY", "SECONDS", "ENABLED", "LENGTH", "POLICY"]
        [] -> False
    keywords = ["PASSWORD", "PASSWD", "SECRET", "TOKEN", "PRIVATE_KEY", "PRIVATEKEY", "API_KEY", "APIKEY", "ACCESS_KEY", "CREDENTIAL", "AUTH_KEY", "SIGNING_KEY", "ENCRYPTION_KEY"]

-- | Why a literal value looks like a credential, if it does.
looksLikeSecretValue :: Text -> Maybe Text
looksLikeSecretValue v
    | isRefExpr v = Nothing
    | "-----BEGIN " `T.isInfixOf` v && "PRIVATE KEY" `T.isInfixOf` v = Just "contains a private key"
    | Just _ <- urlPassword v = Just "has a password embedded in a URL"
    | any (`T.isPrefixOf` v) ["xoxb-", "xoxp-", "xoxa-", "ghp_", "gho_", "ghs_", "github_pat_", "AIza"] = Just "looks like an API token"
    | "AKIA" `T.isPrefixOf` v && T.length v == 20 && T.all (\c -> isAsciiUpper c || isDigit c) v = Just "looks like an AWS access key"
    | "sk-" `T.isPrefixOf` v && T.length v >= 20 = Just "looks like an API key"
    | "eyJ" `T.isPrefixOf` v && T.length v >= 100 = Just "looks like an encoded credential blob"
    | otherwise = Nothing

-- | @$(OTHER_VAR)@ is Kubernetes variable expansion, not a literal.
isRefExpr :: Text -> Bool
isRefExpr v = "$(" `T.isPrefixOf` v && ")" `T.isSuffixOf` v && not (T.any (== ' ') v)

-- | The password in @scheme://user:password\@host/...@, if there is a literal one.
urlPassword :: Text -> Maybe Text
urlPassword v = case T.breakOn "://" v of
    (_, rest) | T.null rest -> Nothing
    (_, rest) ->
        let authority = T.takeWhile (`notElem` ("/?#" :: String)) (T.drop 3 rest)
            (userinfo, host) = T.breakOnEnd "@" authority
         in if T.null userinfo || T.null host
                then Nothing
                else case T.breakOn ":" (T.dropEnd 1 userinfo) of
                    (_, pw) | T.length pw > 1 && not (isRefExpr (T.drop 1 pw)) -> Just (T.drop 1 pw)
                    _ -> Nothing

scanManifestSecrets :: Value -> [Issue]
scanManifestSecrets m = concat [scanEnvEntries (podPrefix <> p) (arr (getK "env" c)) ++ scanCommand (podPrefix <> p) c | (p, c) <- containerList m]

-- | Env entries (@{name, value}@ or @{name, valueFrom}@) carrying an inline credential. @pfx@ names the container.
scanEnvEntries :: Text -> [Value] -> [Issue]
scanEnvEntries pfx entries =
    [ err code (pfx <> ".env[" <> n <> "]") msg
    | e <- entries
    , Just n <- [str (getK "name" e)]
    , Just v <- [str (getK "value" e)]
    , not (T.null v)
    , not (isRefExpr v)
    , Just (code, msg) <- [reason n v]
    ]
  where
    fix = " Put it in a Secret and reference it with valueFrom.secretKeyRef."
    reason n v
        | isSensitiveName n = Just ("plaintext-secret", n <> " looks like a credential but has an inline value." <> fix)
        | Just why <- looksLikeSecretValue v = Just ("secret-like-value", "The value of " <> n <> " " <> why <> "." <> fix)
        | otherwise = Nothing

-- | Credentials passed on the command line (@--password=...@, a URL with a password).
scanCommand :: Text -> Value -> [Issue]
scanCommand pfx c =
    [ err "secret-in-args" (pfx <> "." <> field) ("an argument " <> why <> ". Pass it through an env var sourced from a Secret instead.")
    | field <- ["command", "args"]
    , a <- mapMaybe (str . Just) (arr (getK (K.fromText field) c))
    , Just why <- [argProblem a]
    ]
  where
    argProblem a
        | Just w <- looksLikeSecretValue a = Just w
        | (k, val) <- T.breakOn "=" a
        , not (T.null val)
        , T.length val > 1
        , not (isRefExpr (T.drop 1 val))
        , isSensitiveName (T.dropWhile (== '-') k) =
            Just ("sets " <> T.dropWhile (== '-') k <> " inline")
        | otherwise = Nothing

-- ---------------------------------------------------------------------------
-- References

data RefKind = RkSecret | RkConfigMap
    deriving (Eq, Ord, Show)

data Ref = Ref
    { refKind :: RefKind
    , refName :: Text
    , -- | Keys that must exist in the object; empty means existence is enough.
      refKeys :: [Text]
    , refOptional :: Bool
    , refPath :: Text
    }
    deriving (Eq, Show)

data LookupErr
    = RefNotFound
    | RefBadName
    | -- | Exists as far as we know but could not be read (forbidden, timeout ...).
      RefUnreadable Text
    deriving (Eq, Show)

kindLabel :: RefKind -> Text
kindLabel RkSecret = "Secret"
kindLabel RkConfigMap = "ConfigMap"

kindCode :: RefKind -> Text
kindCode RkSecret = "secret"
kindCode RkConfigMap = "configmap"

collectManifestRefs :: Value -> [Ref]
collectManifestRefs m =
    concat [refsOfEnvEntries (podPrefix <> p) (arr (getK "env" c)) ++ envFromRefs (podPrefix <> p) c | (p, c) <- containerList m]
        ++ maybe [] volumeRefs (getPath podSpecPath m)
        ++ maybe [] pullSecretRefs (getPath podSpecPath m)

-- | References made by env entries (@valueFrom.secretKeyRef@ / @configMapKeyRef@).
refsOfEnvEntries :: Text -> [Value] -> [Ref]
refsOfEnvEntries pfx entries =
    [ Ref kind nm [k | Just k <- [str (getK "key" r)]] (opt r) (pfx <> ".env[" <> n <> "]")
    | e <- entries
    , Just n <- [str (getK "name" e)]
    , (field, kind) <- [("secretKeyRef", RkSecret), ("configMapKeyRef", RkConfigMap)]
    , Just r <- [getPath ["valueFrom", field] e]
    , Just nm <- [str (getK "name" r)]
    ]

envFromRefs :: Text -> Value -> [Ref]
envFromRefs pfx c =
    [ Ref kind nm [] (opt r) (pfx <> ".envFrom[" <> T.pack (show i) <> "]")
    | (i, e) <- zip [0 :: Int ..] (arr (getK "envFrom" c))
    , (field, kind) <- [("secretRef", RkSecret), ("configMapRef", RkConfigMap)]
    , Just r <- [getK field e]
    , Just nm <- [str (getK "name" r)]
    ]

volumeRefs :: Value -> [Ref]
volumeRefs ps = concat [volume (T.pack ("volumes[" <> show i <> "]")) v | (i, v) <- zip [0 :: Int ..] (arr (getK "volumes" ps))]
  where
    volume p v =
        [r | Just s <- [getK "secret" v], r <- source p RkSecret "secretName" s]
            ++ [r | Just s <- [getK "configMap" v], r <- source p RkConfigMap "name" s]
            ++ [ r
               | (j, s0) <- zip [0 :: Int ..] (arr (getPath ["projected", "sources"] v))
               , let sp = p <> ".projected.sources[" <> T.pack (show j) <> "]"
               , (field, kind) <- [("secret", RkSecret), ("configMap", RkConfigMap)]
               , Just s <- [getK field s0]
               , r <- source sp kind "name" s
               ]
    source p kind nameField s = case str (getK nameField s) of
        Nothing -> []
        Just nm -> [Ref kind nm [k | it <- arr (getK "items" s), Just k <- [str (getK "key" it)]] (opt s) (podPrefix <> p)]

pullSecretRefs :: Value -> [Ref]
pullSecretRefs ps =
    [ Ref RkSecret nm [] False (podPrefix <> "imagePullSecrets[" <> T.pack (show i) <> "]")
    | (i, s) <- zip [0 :: Int ..] (arr (getK "imagePullSecrets" ps))
    , Just nm <- [str (getK "name" s)]
    ]

opt :: Value -> Bool
opt r = case getK "optional" r of
    Just (Bool b) -> b
    _ -> False

{- | Look every referenced object up once, then report the ones that are missing
and the keys that are not in them. An optional reference that is missing is
only a warning; Kubernetes starts the pod without it.
-}
checkRefs :: (RefKind -> Text -> IO (Either LookupErr [Text])) -> [Ref] -> IO [Issue]
checkRefs look refs = do
    results <- forM (nub [(refKind r, refName r) | r <- refs]) $ \(k, n) ->
        if isDnsName n then (,) (k, n) <$> look k n else pure ((k, n), Left RefBadName)
    let table = Map.fromList results
    pure (concatMap (issuesFor table) refs)
  where
    issuesFor table r = case Map.lookup (refKind r, refName r) table of
        Nothing -> []
        Just (Left RefNotFound) ->
            [sev r (kindCode (refKind r) <> "-missing") (r `path` (kindLabel (refKind r) <> " \"" <> refName r <> "\" does not exist in this namespace."))]
        Just (Left RefBadName) ->
            [err "invalid-name" (refPath r) (kindLabel (refKind r) <> " name \"" <> refName r <> "\" is not a valid Kubernetes name.")]
        Just (Left (RefUnreadable why)) ->
            [err (kindCode (refKind r) <> "-unverifiable") (refPath r) ("Could not read " <> kindLabel (refKind r) <> " \"" <> refName r <> "\" to check it: " <> T.strip why)]
        Just (Right have) ->
            [ sev r (kindCode (refKind r) <> "-key-missing") (r `path` (kindLabel (refKind r) <> " \"" <> refName r <> "\" has no key \"" <> k <> "\" (it has: " <> available have <> ")."))
            | k <- nub (refKeys r)
            , k `notElem` have
            ]
    sev r code (p, msg) = (if refOptional r then warn else err) code p msg
    path r msg = (refPath r, msg)
    available have = if null have then "no keys" else T.intercalate ", " have
