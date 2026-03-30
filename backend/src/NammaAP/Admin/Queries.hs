{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

module NammaAP.Admin.Queries
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
  -- Products
  , listScProducts
  , createScProduct
  -- Roles
  , listRolesForProduct
  , createRole
  , updateRolePermissions
  -- Permissions
  , listPermissionsForProduct
  , findProductBySlug
  , findPermissionByAction
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
import NammaAP.Environment (DBEnv (..))
import NammaAP.DB.Connection (withConn)
import NammaAP.Admin.Types

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
  -- Build dynamic update
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

-- ── Role Assignment ─────────────────────────────────────────────────

assignRole :: DBEnv -> UUID -> UUID -> UUID -> Maybe UUID -> IO ()
assignRole db personId productId roleId grantedBy = withConn db $ \conn -> do
  _ <- execute conn
    "INSERT INTO sc_person_product_access (person_id, product_id, role_id, granted_by) \
    \VALUES (?, ?, ?, ?) \
    \ON CONFLICT (person_id, product_id) DO UPDATE SET role_id = ?, granted_by = ?"
    (personId, productId, roleId, grantedBy, roleId, grantedBy)
  pure ()

revokeProductAccess :: DBEnv -> UUID -> Text -> IO ()
revokeProductAccess db personId productSlug = withConn db $ \conn -> do
  _ <- execute conn
    "DELETE FROM sc_person_product_access WHERE person_id = ? AND product_id = \
    \(SELECT id FROM sc_product WHERE slug = ?)"
    (personId, productSlug)
  pure ()

-- ── Permission Overrides ────────────────────────────────────────────

addPermissionOverride :: DBEnv -> UUID -> UUID -> UUID -> Text -> Maybe UUID -> IO UUID
addPermissionOverride db personId productId permissionId overrideType grantedBy = withConn db $ \conn -> do
  [Only oid] <- query conn
    "INSERT INTO sc_person_permission_override (person_id, product_id, permission_id, override_type, granted_by) \
    \VALUES (?, ?, ?, ?, ?) \
    \ON CONFLICT (person_id, permission_id) DO UPDATE SET override_type = ?, granted_by = ? \
    \RETURNING id"
    (personId, productId, permissionId, overrideType, grantedBy, overrideType, grantedBy)
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
    "SELECT ppo.id, p.action, ppo.override_type, pr.slug \
    \FROM sc_person_permission_override ppo \
    \JOIN sc_permission p ON p.id = ppo.permission_id \
    \JOIN sc_product pr ON pr.id = ppo.product_id \
    \WHERE ppo.person_id = ?"
    (Only personId)

-- ── Products ────────────────────────────────────────────────────────

instance FromRow ProductDetail where
  fromRow = ProductDetail <$> field <*> field <*> field <*> field <*> field

listScProducts :: DBEnv -> IO [ProductDetail]
listScProducts db = withConn db $ \conn ->
  query_ conn
    "SELECT id, slug, name, description, is_active FROM sc_product ORDER BY name"

createScProduct :: DBEnv -> Text -> Text -> Maybe Text -> IO UUID
createScProduct db slug name desc = withConn db $ \conn -> do
  [Only pid] <- query conn
    "INSERT INTO sc_product (slug, name, description) VALUES (?, ?, ?) RETURNING id"
    (slug, name, desc)
  pure pid

findProductBySlug :: DBEnv -> Text -> IO (Maybe (UUID, Text))
findProductBySlug db slug = withConn db $ \conn -> do
  rows <- query conn
    "SELECT id, name FROM sc_product WHERE slug = ?"
    (Only slug) :: IO [(UUID, Text)]
  pure $ case rows of
    [(pid, name)] -> Just (pid, name)
    _ -> Nothing

-- ── Roles ───────────────────────────────────────────────────────────

data RoleRow = RoleRow
  { rrId :: UUID
  , rrName :: Text
  , rrDescription :: Maybe Text
  , rrIsSystemRole :: Bool
  } deriving (Show)

instance FromRow RoleRow where
  fromRow = RoleRow <$> field <*> field <*> field <*> field

listRolesForProduct :: DBEnv -> Text -> IO [RoleDetail]
listRolesForProduct db productSlug = withConn db $ \conn -> do
  roleRows <- query conn
    "SELECT r.id, r.name, r.description, r.is_system_role \
    \FROM sc_role r JOIN sc_product p ON p.id = r.product_id \
    \WHERE p.slug = ? ORDER BY r.name"
    (Only productSlug) :: IO [RoleRow]
  mapM (\RoleRow{..} -> do
    permRows <- query conn
      "SELECT p.action FROM sc_role_permission rp \
      \JOIN sc_permission p ON p.id = rp.permission_id \
      \WHERE rp.role_id = ?"
      (Only rrId) :: IO [Only Text]
    pure $ RoleDetail rrId rrName rrDescription rrIsSystemRole (map (\(Only a) -> a) permRows)
    ) roleRows

createRole :: DBEnv -> UUID -> Text -> Maybe Text -> [UUID] -> IO UUID
createRole db productId name desc permIds = withConn db $ \conn -> do
  [Only roleId] <- query conn
    "INSERT INTO sc_role (product_id, name, description) VALUES (?, ?, ?) RETURNING id"
    (productId, name, desc)
  mapM_ (\pid -> execute conn
    "INSERT INTO sc_role_permission (role_id, permission_id) VALUES (?, ?) ON CONFLICT DO NOTHING"
    (roleId, pid)) permIds
  pure roleId

updateRolePermissions :: DBEnv -> UUID -> Maybe Text -> [UUID] -> IO ()
updateRolePermissions db roleId mDesc permIds = withConn db $ \conn -> do
  case mDesc of
    Just d -> do
      _ <- execute conn "UPDATE sc_role SET description = ? WHERE id = ?" (d, roleId)
      pure ()
    Nothing -> pure ()
  -- Replace all permissions
  _ <- execute conn "DELETE FROM sc_role_permission WHERE role_id = ?" (Only roleId)
  mapM_ (\pid -> execute conn
    "INSERT INTO sc_role_permission (role_id, permission_id) VALUES (?, ?) ON CONFLICT DO NOTHING"
    (roleId, pid)) permIds
  pure ()

-- ── Permissions ─────────────────────────────────────────────────────

instance FromRow PermissionDetail where
  fromRow = PermissionDetail <$> field <*> field <*> field

listPermissionsForProduct :: DBEnv -> Text -> IO [PermissionDetail]
listPermissionsForProduct db productSlug = withConn db $ \conn ->
  query conn
    "SELECT p.id, p.action, p.description FROM sc_permission p \
    \JOIN sc_product pr ON pr.id = p.product_id \
    \WHERE pr.slug = ? ORDER BY p.action"
    (Only productSlug)

findPermissionByAction :: DBEnv -> Text -> Text -> IO (Maybe (UUID, UUID))
findPermissionByAction db productSlug action = withConn db $ \conn -> do
  rows <- query conn
    "SELECT p.id, p.product_id FROM sc_permission p \
    \JOIN sc_product pr ON pr.id = p.product_id \
    \WHERE pr.slug = ? AND p.action = ?"
    (productSlug, action) :: IO [(UUID, UUID)]
  pure $ case rows of
    [(pid, prodId)] -> Just (pid, prodId)
    _ -> Nothing

-- ── Audit Log ──────────────────────────────────────────────────────

writeAuditLog :: DBEnv -> UUID -> Text -> Maybe Text -> Maybe Text -> Maybe A.Value -> IO ()
writeAuditLog db personId action entityType entityId details = withConn db $ \conn -> do
  _ <- execute conn
    "INSERT INTO sc_audit_log (person_id, action, entity_type, entity_id, details) \
    \VALUES (?, ?, ?, ?, ?)"
    (personId, action, entityType, entityId, A.encode <$> details)
  pure ()
