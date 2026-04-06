{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

module Core.Admin.Queries
  ( -- Person CRUD
    listPersons,
    createPerson,
    findPersonDetailById,
    updatePerson,
    deactivatePerson,
    -- Role assignment
    assignRole,
    revokeProductAccess,
    -- Permission overrides
    addPermissionOverride,
    removePermissionOverride,
    listOverridesForPerson,
    -- Roles
    listRolesForProduct,
    createRole,
    updateRolePermissions,
    -- Audit
    writeAuditLog,
  )
where

import Core.Admin.Types
import Core.Auth.Schema
import Core.DB.Connection (runDB, withConn)
import Core.Environment (DBEnv (..))
import qualified Data.Aeson as A
import Data.Text (Text)
import Data.UUID (UUID)
import Database.Beam
import Database.Beam.Postgres ()
import Database.PostgreSQL.Simple (Only (..), execute, query)
import Database.PostgreSQL.Simple.FromRow (FromRow (..), field)
import Database.PostgreSQL.Simple.Types (PGArray (..))
import Products.Types (defaultPermissionsText)

-- ── Beam-row → domain-type converters ──────────────────────────────

toPersonDetail :: ScPerson -> PersonDetail
toPersonDetail ScPersonT {..} =
  PersonDetail
    { pdId = spId,
      pdEmail = spEmail,
      pdFirstName = spFirstName,
      pdLastName = spLastName,
      pdIsActive = spIsActive,
      pdIsSuperadmin = spIsSuperadmin,
      pdCreatedAt = spCreatedAt
    }

toOverrideDetail :: ScPersonPermissionOverride -> OverrideDetail
toOverrideDetail ScPersonPermissionOverrideT {..} =
  OverrideDetail
    { odId = sppoId,
      odPermissionAction = sppoPermissionAction,
      odOverrideType = sppoOverrideType,
      odProductSlug = sppoProductSlug
    }

-- ── Person CRUD ─────────────────────────────────────────────────────

listPersons :: DBEnv -> IO [PersonDetail]
listPersons db = do
  rows <-
    runDB db $
      runSelectReturningList $
        select $
          orderBy_ (\p -> desc_ (spCreatedAt p)) $
            all_ (scPerson coreDb)
  pure $ map toPersonDetail rows

-- | INSERT RETURNING — kept as raw SQL (Beam RETURNING is Postgres-specific
-- and verbose for a single-value return).
createPerson :: DBEnv -> Text -> Text -> Text -> Text -> Bool -> IO UUID
createPerson db email firstName lastName passwordHash isSuperadmin = withConn db $ \conn -> do
  [Only pid] <-
    query
      conn
      "INSERT INTO sc_person (email, first_name, last_name, password_hash, is_superadmin) \
      \VALUES (?, ?, ?, ?, ?) RETURNING id"
      (email, firstName, lastName, passwordHash, isSuperadmin)
  pure pid

findPersonDetailById :: DBEnv -> UUID -> IO (Maybe PersonDetail)
findPersonDetailById db pid = do
  rows <-
    runDB db $
      runSelectReturningList $
        select $ do
          p <- all_ (scPerson coreDb)
          guard_ (spId p ==. val_ pid)
          pure p
  pure $ case rows of
    [p] -> Just (toPersonDetail p)
    _ -> Nothing

-- | Dynamic COALESCE update — kept as raw SQL (Beam doesn't support
-- COALESCE(?, column) in SET clauses cleanly).
updatePerson :: DBEnv -> UUID -> Maybe Text -> Maybe Text -> Maybe Bool -> Maybe Bool -> IO ()
updatePerson db pid mFirstName mLastName mIsActive mIsSuperadmin = withConn db $ \conn -> do
  case (mFirstName, mLastName, mIsActive, mIsSuperadmin) of
    (Nothing, Nothing, Nothing, Nothing) -> pure ()
    _ -> do
      _ <-
        execute
          conn
          "UPDATE sc_person SET \
          \first_name = COALESCE(?, first_name), \
          \last_name = COALESCE(?, last_name), \
          \is_active = COALESCE(?, is_active), \
          \is_superadmin = COALESCE(?, is_superadmin), \
          \updated_at = now() \
          \WHERE id = ?"
          (mFirstName, mLastName, mIsActive, mIsSuperadmin, pid)
      pure ()

-- | Deactivate a person — kept as raw SQL because Beam's currentTimestamp_
-- returns LocalTime (not UTCTime), so the UPDATE SET updated_at = now()
-- is simpler in raw SQL.
deactivatePerson :: DBEnv -> UUID -> IO ()
deactivatePerson db pid = withConn db $ \conn -> do
  _ <-
    execute
      conn
      "UPDATE sc_person SET is_active = false, updated_at = now() WHERE id = ?"
      (Only pid)
  pure ()

-- ── Role Assignment (ON CONFLICT — kept as raw SQL) ─────────────────

assignRole :: DBEnv -> UUID -> Text -> UUID -> Maybe UUID -> IO ()
assignRole db personId productSlug roleId grantedBy = withConn db $ \conn -> do
  _ <-
    execute
      conn
      "INSERT INTO sc_person_product_access (person_id, product_slug, role_id, granted_by) \
      \VALUES (?, ?, ?, ?) \
      \ON CONFLICT (person_id, product_slug) DO UPDATE SET role_id = ?, granted_by = ?"
      (personId, productSlug, roleId, grantedBy, roleId, grantedBy)
  pure ()

revokeProductAccess :: DBEnv -> UUID -> Text -> IO ()
revokeProductAccess db personId productSlug =
  runDB db $
    runDelete $
      delete
        (scPersonProductAccess coreDb)
        (\a -> sppaPersonId a ==. val_ personId &&. sppaProductSlug a ==. val_ productSlug)

-- ── Permission Overrides ────────────────────────────────────────────

-- | INSERT ON CONFLICT RETURNING — kept as raw SQL.
addPermissionOverride :: DBEnv -> UUID -> Text -> Text -> Text -> Maybe UUID -> IO UUID
addPermissionOverride db personId productSlug permAction overrideType grantedBy = withConn db $ \conn -> do
  [Only oid] <-
    query
      conn
      "INSERT INTO sc_person_permission_override (person_id, product_slug, permission_action, override_type, granted_by) \
      \VALUES (?, ?, ?, ?, ?) \
      \ON CONFLICT (person_id, product_slug, permission_action) DO UPDATE SET override_type = ?, granted_by = ? \
      \RETURNING id"
      (personId, productSlug, permAction, overrideType, grantedBy, overrideType, grantedBy)
  pure oid

removePermissionOverride :: DBEnv -> UUID -> IO ()
removePermissionOverride db oid =
  runDB db $
    runDelete $
      delete
        (scPersonPermissionOverride coreDb)
        (\o -> sppoId o ==. val_ oid)

listOverridesForPerson :: DBEnv -> UUID -> IO [OverrideDetail]
listOverridesForPerson db personId = do
  rows <-
    runDB db $
      runSelectReturningList $
        select $ do
          o <- all_ (scPersonPermissionOverride coreDb)
          guard_ (sppoPersonId o ==. val_ personId)
          pure o
  pure $ map toOverrideDetail rows

-- ── Roles (PGArray queries — kept as raw SQL) ────────────────────────

data RoleRow = RoleRow
  { rrId :: UUID,
    rrName :: Text,
    rrDescription :: Maybe Text,
    rrIsSystemRole :: Bool,
    rrPermissions :: Maybe (PGArray Text)
  }
  deriving (Show)

instance FromRow RoleRow where
  fromRow = RoleRow <$> field <*> field <*> field <*> field <*> field

listRolesForProduct :: DBEnv -> Text -> IO [RoleDetail]
listRolesForProduct db productSlug = withConn db $ \conn -> do
  roleRows <-
    query
      conn
      "SELECT id, name, description, is_system_role, permissions \
      \FROM sc_role WHERE product_slug = ? ORDER BY name"
      (Only productSlug) ::
      IO [RoleRow]
  pure $
    map
      ( \RoleRow {..} ->
          let perms = case (rrIsSystemRole, rrPermissions) of
                (True, _) -> defaultPermissionsText productSlug rrName
                (False, Just (PGArray ps)) -> ps
                (False, Nothing) -> []
           in RoleDetail rrId rrName rrDescription rrIsSystemRole perms
      )
      roleRows

createRole :: DBEnv -> Text -> Text -> Maybe Text -> [Text] -> IO UUID
createRole db productSlug name desc permActions = withConn db $ \conn -> do
  [Only roleId] <-
    query
      conn
      "INSERT INTO sc_role (product_slug, name, description, permissions) VALUES (?, ?, ?, ?) RETURNING id"
      (productSlug, name, desc, PGArray permActions)
  pure roleId

updateRolePermissions :: DBEnv -> UUID -> Maybe Text -> [Text] -> IO ()
updateRolePermissions db roleId mDesc permActions = withConn db $ \conn -> do
  case mDesc of
    Just d -> do
      _ <- execute conn "UPDATE sc_role SET description = ? WHERE id = ?" (d, roleId)
      pure ()
    Nothing -> pure ()
  _ <- execute conn "UPDATE sc_role SET permissions = ? WHERE id = ?" (PGArray permActions, roleId)
  pure ()

-- ── Audit Log ──────────────────────────────────────────────────────

writeAuditLog :: DBEnv -> UUID -> Text -> Maybe Text -> Maybe Text -> Maybe A.Value -> IO ()
writeAuditLog db personId action entityType entityId details =
  runDB db $
    runInsert $
      insert (scAuditLog coreDb) $
        insertExpressions
          [ ScAuditLogT
              { salId = default_,
                salPersonId = val_ (Just personId),
                salAction = val_ action,
                salEntityType = val_ entityType,
                salEntityId = val_ entityId,
                salDetails = val_ details,
                salCreatedAt = default_
              }
          ]
