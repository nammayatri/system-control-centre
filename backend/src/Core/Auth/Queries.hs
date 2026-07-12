{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

module Core.Auth.Queries
  ( findPersonByEmail,
    findPersonById,
    findTokenByValue,
    insertToken,
    deactivateToken,
    deactivateTokensByPerson,
    findProductAccessForPerson,
    findDeploymentAccessForPerson,
    computeEffectivePermissions,
    computeEffectivePermissionsForAppGroup,
    findAllProductsForPerson,
    findAllDeploymentPermsForPerson,
    hasAnyDeploymentPermission,
    resetPasswordByEmail,
    TokenRow (..),
    createPatKey,
    listPatKeysForPerson,
    revokePatKey,
    findPatKeyByHash,
    touchPatKeyLastUsed,
    patMaxValiditySeconds,
    hashPatToken,
  )
where

import Control.Monad.IO.Class (liftIO)
import Core.Auth.Schema
import Core.Auth.Types
import Core.DB.Connection (runDB, withConn)
import Core.Environment (DBEnv (..), MonadFlow, withDb)
import Crypto.Hash (Digest, SHA256, hash)
import Crypto.Random (getRandomBytes)
import qualified Data.ByteString.Base64.URL as B64U
import Data.List (find)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Data.Time.Clock (NominalDiffTime, UTCTime, getCurrentTime)
import Data.UUID (UUID)
import qualified Data.UUID.V4 as UUIDV4
import Database.Beam
import Database.Beam.Postgres ()
import Database.PostgreSQL.Simple (Only (..), execute, query)
import Database.PostgreSQL.Simple.FromRow (FromRow (..), field)
import Database.PostgreSQL.Simple.Types (PGArray (..))
import Products.Types (allPermissionsText, defaultPermissionsText)

-- ── Beam-row → domain-type converters ──────────────────────────────

toPersonAuth :: ScPerson -> PersonAuth
toPersonAuth ScPersonT {..} =
  PersonAuth
    { personId = spId,
      personEmail = spEmail,
      personFirstName = spFirstName,
      personLastName = spLastName,
      personPasswordHash = spPasswordHash,
      personIsActive = spIsActive,
      personIsSuperadmin = spIsSuperadmin,
      personCreatedAt = spCreatedAt,
      personUpdatedAt = spUpdatedAt
    }

-- ── Person ──────────────────────────────────────────────────────────

findPersonByEmail :: (MonadFlow m) => Text -> m (Maybe PersonAuth)
findPersonByEmail email = withDb $ \db -> do
  rows <-
    runDB db $
      runSelectReturningList $
        select $ do
          p <- all_ (scPerson coreDb)
          guard_ (spEmail p ==. val_ email &&. spIsActive p ==. val_ True)
          pure p
  pure $ case rows of
    [p] -> Just (toPersonAuth p)
    _ -> Nothing

findPersonById :: (MonadFlow m) => UUID -> m (Maybe PersonAuth)
findPersonById pid = withDb $ \db -> do
  rows <-
    runDB db $
      runSelectReturningList $
        select $ do
          p <- all_ (scPerson coreDb)
          guard_ (spId p ==. val_ pid)
          pure p
  pure $ case rows of
    [p] -> Just (toPersonAuth p)
    _ -> Nothing

-- ── Token ───────────────────────────────────────────────────────────

data TokenRow = TokenRow
  { trId :: UUID,
    trPersonId :: UUID,
    trToken :: Text,
    trIsActive :: Bool,
    trCreatedAt :: UTCTime,
    trExpiresAt :: UTCTime
  }
  deriving (Show)

toTokenRow :: ScRegistrationToken -> TokenRow
toTokenRow ScRegistrationTokenT {..} =
  TokenRow
    { trId = srtId,
      trPersonId = srtPersonId,
      trToken = srtToken,
      trIsActive = srtIsActive,
      trCreatedAt = srtCreatedAt,
      trExpiresAt = srtExpiresAt
    }

findTokenByValue :: (MonadFlow m) => Text -> m (Maybe TokenRow)
findTokenByValue tok = withDb $ \db -> do
  rows <-
    runDB db $
      runSelectReturningList $
        select $ do
          t <- all_ (scRegistrationToken coreDb)
          guard_ (srtToken t ==. val_ tok &&. srtIsActive t ==. val_ True)
          pure t
  pure $ case rows of
    [t] -> Just (toTokenRow t)
    _ -> Nothing

insertToken :: (MonadFlow m) => UUID -> Text -> UTCTime -> m ()
insertToken personId tok expiresAt = withDb $ \db ->
  runDB db $
    runInsert $
      insert (scRegistrationToken coreDb) $
        insertExpressions
          [ ScRegistrationTokenT
              { srtId = default_,
                srtPersonId = val_ personId,
                srtToken = val_ tok,
                srtIsActive = val_ True,
                srtCreatedAt = default_,
                srtExpiresAt = val_ expiresAt
              }
          ]

deactivateToken :: (MonadFlow m) => Text -> m ()
deactivateToken tok = withDb $ \db ->
  runDB db $
    runUpdate $
      update
        (scRegistrationToken coreDb)
        (\t -> srtIsActive t <-. val_ False)
        (\t -> srtToken t ==. val_ tok)

deactivateTokensByPerson :: (MonadFlow m) => UUID -> m ()
deactivateTokensByPerson pid = withDb $ \db ->
  runDB db $
    runUpdate $
      update
        (scRegistrationToken coreDb)
        (\t -> srtIsActive t <-. val_ False)
        (\t -> srtPersonId t ==. val_ pid)

-- ── Product Access (JOIN query — kept as raw SQL) ──────────────────

data ProductAccessRow = ProductAccessRow
  { parProductSlug :: Text,
    parRoleId :: UUID,
    parRoleName :: Text,
    parIsSystemRole :: Bool,
    parPermissions :: Maybe (PGArray Text)
  }
  deriving (Show)

instance FromRow ProductAccessRow where
  fromRow = ProductAccessRow <$> field <*> field <*> field <*> field <*> field

-- | Internal IO helper used by computeEffectivePermissions / findAllProductsForPerson.
findProductAccessForPersonIO :: DBEnv -> UUID -> IO [ProductAccess]
findProductAccessForPersonIO db pid = withConn db $ \conn -> do
  rows <-
    query
      conn
      "SELECT ppa.product_slug, r.id, r.name, r.is_system_role, r.permissions \
      \FROM sc_person_product_access ppa \
      \JOIN sc_role r ON r.id = ppa.role_id \
      \WHERE ppa.person_id = ?"
      (Only pid)
  pure $
    map
      ( \ProductAccessRow {..} ->
          ProductAccess parProductSlug parProductSlug parRoleId parRoleName
      )
      rows

findProductAccessForPerson :: (MonadFlow m) => UUID -> m [ProductAccess]
findProductAccessForPerson pid = withDb $ \db -> findProductAccessForPersonIO db pid

-- ── Deployment Access (JOIN query — kept as raw SQL) ────────────────

data DeploymentAccessRow = DeploymentAccessRow
  { darProductSlug :: Text,
    darAppGroup :: Text,
    darRoleId :: UUID,
    darRoleName :: Text
  }
  deriving (Show)

instance FromRow DeploymentAccessRow where
  fromRow = DeploymentAccessRow <$> field <*> field <*> field <*> field

-- | Internal IO helper used by computeEffectivePermissionsForAppGroup.
-- Deployment-level (app_group) role overrides for a person, across all
-- products/app_groups they've been granted one for.
findDeploymentAccessForPersonIO :: DBEnv -> UUID -> IO [DeploymentAccess]
findDeploymentAccessForPersonIO db pid = withConn db $ \conn -> do
  rows <-
    query
      conn
      "SELECT pda.product_slug, pda.app_group, r.id, r.name \
      \FROM sc_person_deployment_access pda \
      \JOIN sc_role r ON r.id = pda.role_id \
      \WHERE pda.person_id = ?"
      (Only pid)
  pure $
    map
      ( \DeploymentAccessRow {..} ->
          DeploymentAccess darProductSlug darAppGroup darRoleId darRoleName
      )
      rows

findDeploymentAccessForPerson :: (MonadFlow m) => UUID -> m [DeploymentAccess]
findDeploymentAccessForPerson pid = withDb $ \db -> findDeploymentAccessForPersonIO db pid

hasAnyDeploymentPermissionIO :: DBEnv -> UUID -> Text -> Text -> IO Bool
hasAnyDeploymentPermissionIO db pid productSlug permText = do
  accesses <- findDeploymentAccessForPersonIO db pid
  let relevant = filter (\da -> daProductSlug da == productSlug) accesses
  results <-
    mapM
      (\da -> elem permText <$> computeEffectivePermissionsForAppGroupIO db pid productSlug (daAppGroup da))
      relevant
  pure (or results)

hasAnyDeploymentPermission :: (MonadFlow m) => UUID -> Text -> Text -> m Bool
hasAnyDeploymentPermission pid productSlug permText =
  withDb $ \db -> hasAnyDeploymentPermissionIO db pid productSlug permText

-- ── Permission Computation (uses code-derived defaults) ─────────────

-- | Apply GRANT/DENY overrides (product-scoped, not app_group-scoped) on top of a base permission set.
applyOverridesIO :: DBEnv -> UUID -> Text -> [Text] -> IO [Text]
applyOverridesIO db pid productSlug basePerms = do
  grants <- findGrantOverrides db pid productSlug
  denies <- findDenyOverrides db pid productSlug
  let combined = basePerms ++ filter (`notElem` basePerms) grants
  pure $ filter (`notElem` denies) combined

-- | Get effective permissions for a person on a product.
-- System roles: permissions derived from Haskell ADTs via defaultPermissionsText
-- Custom roles: permissions from sc_role.permissions TEXT[] column
-- Then apply GRANT/DENY overrides from sc_person_permission_override
computeEffectivePermissionsIO :: DBEnv -> PersonAuth -> Text -> UUID -> IO [Text]
computeEffectivePermissionsIO db person productSlug roleId = do
  if personIsSuperadmin person
    then pure $ allPermissionsText productSlug
    else do
      basePerms <- getRolePermissions db productSlug roleId
      applyOverridesIO db (personId person) productSlug basePerms

computeEffectivePermissions :: (MonadFlow m) => PersonAuth -> Text -> UUID -> m [Text]
computeEffectivePermissions person productSlug roleId =
  withDb $ \db -> computeEffectivePermissionsIO db person productSlug roleId

computeEffectivePermissionsForAppGroupIO :: DBEnv -> UUID -> Text -> Text -> IO [Text]
computeEffectivePermissionsForAppGroupIO db pid productSlug appGroup = do
  deploymentAccesses <- findDeploymentAccessForPersonIO db pid
  case find (\da -> daProductSlug da == productSlug && daAppGroup da == appGroup) deploymentAccesses of
    Just da -> do
      basePerms <- getRolePermissions db productSlug (daRoleId da)
      applyOverridesIO db pid productSlug basePerms
    Nothing -> do
      productAccesses <- findProductAccessForPersonIO db pid
      case find (\pa -> paProductSlug pa == productSlug) productAccesses of
        Just pa -> do
          basePerms <- getRolePermissions db productSlug (paRoleId pa)
          applyOverridesIO db pid productSlug basePerms
        Nothing -> pure []

computeEffectivePermissionsForAppGroup :: (MonadFlow m) => UUID -> Text -> Text -> m [Text]
computeEffectivePermissionsForAppGroup pid productSlug appGroup =
  withDb $ \db -> computeEffectivePermissionsForAppGroupIO db pid productSlug appGroup

-- | Get permissions for a role (PGArray — kept as raw SQL).
getRolePermissions :: DBEnv -> Text -> UUID -> IO [Text]
getRolePermissions db productSlug roleId = withConn db $ \conn -> do
  rows <-
    query
      conn
      "SELECT name, is_system_role, permissions FROM sc_role WHERE id = ?"
      (Only roleId) ::
      IO [(Text, Bool, Maybe (PGArray Text))]
  case rows of
    [(roleName, True, _)] ->
      pure $ defaultPermissionsText productSlug roleName
    [(_, False, Just (PGArray perms))] ->
      pure perms
    [(_, False, Nothing)] ->
      pure []
    _ -> pure []

-- ── Overrides (Beam queries) ───────────────────────────────────────

findGrantOverrides :: DBEnv -> UUID -> Text -> IO [Text]
findGrantOverrides db pid productSlug = do
  rows <-
    runDB db $
      runSelectReturningList $
        select $ do
          o <- all_ (scPersonPermissionOverride coreDb)
          guard_
            ( sppoPersonId o
                ==. val_ pid
                &&. sppoProductSlug o
                ==. val_ productSlug
                &&. sppoOverrideType o
                ==. val_ "GRANT"
            )
          pure (sppoPermissionAction o)
  pure rows

findDenyOverrides :: DBEnv -> UUID -> Text -> IO [Text]
findDenyOverrides db pid productSlug = do
  rows <-
    runDB db $
      runSelectReturningList $
        select $ do
          o <- all_ (scPersonPermissionOverride coreDb)
          guard_
            ( sppoPersonId o
                ==. val_ pid
                &&. sppoProductSlug o
                ==. val_ productSlug
                &&. sppoOverrideType o
                ==. val_ "DENY"
            )
          pure (sppoPermissionAction o)
  pure rows

-- ── All products for person ────────────────────────────────────────

findAllProductsForPerson :: (MonadFlow m) => PersonAuth -> m [PersonProductPerms]
findAllProductsForPerson person = withDb $ \db -> do
  accesses <- findProductAccessForPersonIO db (personId person)
  mapM
    ( \pa -> do
        perms <- computeEffectivePermissionsIO db person (paProductSlug pa) (paRoleId pa)
        pure $ PersonProductPerms (paProductSlug pa) (paRoleName pa) perms
    )
    accesses

findAllDeploymentPermsForPerson :: (MonadFlow m) => PersonAuth -> m [PersonDeploymentPerms]
findAllDeploymentPermsForPerson person = withDb $ \db -> do
  accesses <- findDeploymentAccessForPersonIO db (personId person)
  mapM
    ( \da -> do
        perms <- computeEffectivePermissionsForAppGroupIO db (personId person) (daProductSlug da) (daAppGroup da)
        pure $ PersonDeploymentPerms (daProductSlug da) (daAppGroup da) (daRoleName da) perms
    )
    accesses

-- ── Password Reset ─────────────────────────────────────────────────

resetPasswordByEmail :: (MonadFlow m) => Text -> Text -> m Bool
resetPasswordByEmail email newPassword = withDb $ \db -> withConn db $ \conn -> do
  n <-
    execute
      conn
      "UPDATE sc_person SET password_hash = ?, updated_at = now() WHERE email = ? AND is_active = true"
      (newPassword, email)
  pure (n > 0)

patMaxValiditySeconds :: NominalDiffTime
patMaxValiditySeconds = 60 * 24 * 60 * 60

hashPatToken :: Text -> Text
hashPatToken t = T.pack (show (hash (TE.encodeUtf8 t) :: Digest SHA256))

generatePatToken :: IO Text
generatePatToken = do
  raw <- getRandomBytes 32
  let encoded = TE.decodeUtf8 (B64U.encode raw)
  pure ("scc_pat_" <> T.dropWhileEnd (== '=') encoded)

patTokenPrefix :: Text -> Text
patTokenPrefix = T.take 16

createPatKey :: (MonadFlow m) => UUID -> Text -> UTCTime -> m (Text, McpPatKey)
createPatKey personId label expiresAt = withDb $ \db -> do
  token <- liftIO generatePatToken
  keyId <- liftIO UUIDV4.nextRandom
  createdAt <- liftIO getCurrentTime
  let row =
        McpPatKeyT
          { mpkId = keyId,
            mpkPersonId = personId,
            mpkLabel = label,
            mpkTokenPrefix = patTokenPrefix token,
            mpkTokenHash = hashPatToken token,
            mpkCreatedAt = createdAt,
            mpkExpiresAt = expiresAt,
            mpkLastUsedAt = Nothing,
            mpkRevokedAt = Nothing
          }
  runDB db $
    runInsert $
      insert (mcpPatKeys coreDb) $
        insertValues [row]
  pure (token, row)

listPatKeysForPerson :: (MonadFlow m) => UUID -> m [McpPatKey]
listPatKeysForPerson pid = withDb $ \db ->
  runDB db $
    runSelectReturningList $
      select $
        orderBy_ (desc_ . mpkCreatedAt) $ do
          k <- all_ (mcpPatKeys coreDb)
          guard_ (mpkPersonId k ==. val_ pid)
          pure k

revokePatKey :: (MonadFlow m) => UUID -> UUID -> m Bool
revokePatKey pid keyId = withDb $ \db -> withConn db $ \conn -> do
  n <-
    execute
      conn
      "UPDATE mcp_pat_keys SET revoked_at = now() \
      \WHERE id = ? AND person_id = ? AND revoked_at IS NULL"
      (keyId, pid)
  pure (n > 0)

findPatKeyByHash :: (MonadFlow m) => Text -> m (Maybe McpPatKey)
findPatKeyByHash tokenHash = withDb $ \db -> do
  rows <-
    runDB db $
      runSelectReturningList $
        select $ do
          k <- all_ (mcpPatKeys coreDb)
          guard_ (mpkTokenHash k ==. val_ tokenHash)
          pure k
  pure $ case rows of
    [k] -> Just k
    _ -> Nothing

touchPatKeyLastUsed :: (MonadFlow m) => UUID -> m ()
touchPatKeyLastUsed keyId = withDb $ \db -> do
  now <- liftIO getCurrentTime
  runDB db $
    runUpdate $
      update
        (mcpPatKeys coreDb)
        (\k -> mpkLastUsedAt k <-. val_ (Just now))
        (\k -> mpkId k ==. val_ keyId)
