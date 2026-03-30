{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

module Core.Admin.Queries
  ( -- Person CRUD
    listPersons
  , createPerson
  , findPersonDetailById
  , updatePerson
  , deactivatePerson
  -- Role assignment
  , assignRole
  , revokeProductAccess
  -- Permission overrides
  , addPermissionOverride
  , removePermissionOverride
  , listOverridesForPerson
  -- Roles
  , listRolesForProduct
  , createRole
  , updateRolePermissions
  -- Audit
  , writeAuditLog
  ) where

import qualified Data.Aeson as A
import Data.Text (Text)
import Data.Time.Clock (UTCTime)
import Data.UUID (UUID)
import Database.PostgreSQL.Simple
import Database.PostgreSQL.Simple.FromRow (FromRow (..), field)
import Database.PostgreSQL.Simple.Types (PGArray(..))
import Core.Environment (DBEnv (..))
import Core.DB.Connection (withConn)
import Core.Admin.Types
import Products.Types (defaultPermissionsText)

-- ── Person CRUD ─────────────────────────────────────────────────────

instance FromRow PersonDetail where
  fromRow = PersonDetail <$> field <*> field <*> field <*> field <*> field <*> field <*> field

listPersons :: DBEnv -> IO [PersonDetail]
listPersons db = withConn db $ \conn ->
  query_ conn
    "SELECT id, email, first_name, last_name, is_active, is_superadmin, created_at \
    \FROM sc_person ORDER BY created_at DESC"

createPerson :: DBEnv -> Text -> Text -> Text -> Text -> Bool -> IO UUID
createPerson db email firstName lastName passwordHash isSuperadmin = withConn db $ \conn -> do
  [Only pid] <- query conn
    "INSERT INTO sc_person (email, first_name, last_name, password_hash, is_superadmin) \
    \VALUES (?, ?, ?, ?, ?) RETURNING id"
    (email, firstName, lastName, passwordHash, isSuperadmin)
  pure pid

findPersonDetailById :: DBEnv -> UUID -> IO (Maybe PersonDetail)
findPersonDetailById db pid = withConn db $ \conn -> do
  rows <- query conn
    "SELECT id, email, first_name, last_name, is_active, is_superadmin, created_at \
    \FROM sc_person WHERE id = ?"
    (Only pid)
  pure $ case rows of
    [p] -> Just p
    _   -> Nothing

updatePerson :: DBEnv -> UUID -> Maybe Text -> Maybe Text -> Maybe Bool -> Maybe Bool -> IO ()
updatePerson db pid mFirstName mLastName mIsActive mIsSuperadmin = withConn db $ \conn -> do
  case (mFirstName, mLastName, mIsActive, mIsSuperadmin) of
    (Nothing, Nothing, Nothing, Nothing) -> pure ()
    _ -> do
      _ <- execute conn
        "UPDATE sc_person SET \
        \first_name = COALESCE(?, first_name), \
        \last_name = COALESCE(?, last_name), \
        \is_active = COALESCE(?, is_active), \
        \is_superadmin = COALESCE(?, is_superadmin), \
        \updated_at = now() \
        \WHERE id = ?"
        (mFirstName, mLastName, mIsActive, mIsSuperadmin, pid)
      pure ()

deactivatePerson :: DBEnv -> UUID -> IO ()
deactivatePerson db pid = withConn db $ \conn -> do
  _ <- execute conn
    "UPDATE sc_person SET is_active = false, updated_at = now() WHERE id = ?"
    (Only pid)
  pure ()

-- ── Role Assignment (new schema: product_slug is TEXT, no FK to sc_product) ──

assignRole :: DBEnv -> UUID -> Text -> UUID -> Maybe UUID -> IO ()
assignRole db personId productSlug roleId grantedBy = withConn db $ \conn -> do
  _ <- execute conn
    "INSERT INTO sc_person_product_access (person_id, product_slug, role_id, granted_by) \
    \VALUES (?, ?, ?, ?) \
    \ON CONFLICT (person_id, product_slug) DO UPDATE SET role_id = ?, granted_by = ?"
    (personId, productSlug, roleId, grantedBy, roleId, grantedBy)
  pure ()

revokeProductAccess :: DBEnv -> UUID -> Text -> IO ()
revokeProductAccess db personId productSlug = withConn db $ \conn -> do
  _ <- execute conn
    "DELETE FROM sc_person_product_access WHERE person_id = ? AND product_slug = ?"
    (personId, productSlug)
  pure ()

-- ── Permission Overrides (new schema: permission_action TEXT, no FK to sc_permission) ──

addPermissionOverride :: DBEnv -> UUID -> Text -> Text -> Text -> Maybe UUID -> IO UUID
addPermissionOverride db personId productSlug permAction overrideType grantedBy = withConn db $ \conn -> do
  [Only oid] <- query conn
    "INSERT INTO sc_person_permission_override (person_id, product_slug, permission_action, override_type, granted_by) \
    \VALUES (?, ?, ?, ?, ?) \
    \ON CONFLICT (person_id, product_slug, permission_action) DO UPDATE SET override_type = ?, granted_by = ? \
    \RETURNING id"
    (personId, productSlug, permAction, overrideType, grantedBy, overrideType, grantedBy)
  pure oid

removePermissionOverride :: DBEnv -> UUID -> IO ()
removePermissionOverride db oid = withConn db $ \conn -> do
  _ <- execute conn
    "DELETE FROM sc_person_permission_override WHERE id = ?"
    (Only oid)
  pure ()

instance FromRow OverrideDetail where
  fromRow = OverrideDetail <$> field <*> field <*> field <*> field

listOverridesForPerson :: DBEnv -> UUID -> IO [OverrideDetail]
listOverridesForPerson db personId = withConn db $ \conn ->
  query conn
    "SELECT id, permission_action, override_type, product_slug \
    \FROM sc_person_permission_override \
    \WHERE person_id = ?"
    (Only personId)

-- ── Roles (new schema: product_slug TEXT, permissions TEXT[]) ────────

data RoleRow = RoleRow
  { rrId :: UUID
  , rrName :: Text
  , rrDescription :: Maybe Text
  , rrIsSystemRole :: Bool
  , rrPermissions :: Maybe (PGArray Text)
  } deriving (Show)

instance FromRow RoleRow where
  fromRow = RoleRow <$> field <*> field <*> field <*> field <*> field

listRolesForProduct :: DBEnv -> Text -> IO [RoleDetail]
listRolesForProduct db productSlug = withConn db $ \conn -> do
  roleRows <- query conn
    "SELECT id, name, description, is_system_role, permissions \
    \FROM sc_role WHERE product_slug = ? ORDER BY name"
    (Only productSlug) :: IO [RoleRow]
  pure $ map (\RoleRow{..} ->
    let perms = case (rrIsSystemRole, rrPermissions) of
          (True, _)                    -> defaultPermissionsText productSlug rrName
          (False, Just (PGArray ps))   -> ps
          (False, Nothing)             -> []
    in RoleDetail rrId rrName rrDescription rrIsSystemRole perms
    ) roleRows

createRole :: DBEnv -> Text -> Text -> Maybe Text -> [Text] -> IO UUID
createRole db productSlug name desc permActions = withConn db $ \conn -> do
  [Only roleId] <- query conn
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
writeAuditLog db personId action entityType entityId details = withConn db $ \conn -> do
  _ <- execute conn
    "INSERT INTO sc_audit_log (person_id, action, entity_type, entity_id, details) \
    \VALUES (?, ?, ?, ?, ?)"
    (personId, action, entityType, entityId, A.encode <$> details)
  pure ()
