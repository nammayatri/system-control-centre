{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

module Core.Admin.Queries (
    -- Person CRUD
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
import Core.Environment (MonadFlow, withDb)
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
toPersonDetail ScPersonT{..} =
    PersonDetail
        { pdId = spId
        , pdEmail = spEmail
        , pdFirstName = spFirstName
        , pdLastName = spLastName
        , pdIsActive = spIsActive
        , pdIsSuperadmin = spIsSuperadmin
        , pdCreatedAt = spCreatedAt
        }

toOverrideDetail :: ScPersonPermissionOverride -> OverrideDetail
toOverrideDetail ScPersonPermissionOverrideT{..} =
    OverrideDetail
        { odId = sppoId
        , odPermissionAction = sppoPermissionAction
        , odOverrideType = sppoOverrideType
        , odProductSlug = sppoProductSlug
        }

-- ── Person CRUD ─────────────────────────────────────────────────────

listPersons :: (MonadFlow m) => m [PersonDetail]
listPersons = withDb $ \db -> do
    rows <-
        runDB db $
            runSelectReturningList $
                select $
                    orderBy_ (\p -> desc_ (spCreatedAt p)) $
                        all_ (scPerson coreDb)
    pure $ map toPersonDetail rows

{- | INSERT RETURNING — kept as raw SQL (Beam RETURNING is Postgres-specific
and verbose for a single-value return).
-}
createPerson :: (MonadFlow m) => Text -> Text -> Text -> Text -> Bool -> m UUID
createPerson email firstName lastName passwordHash isSuperadmin = withDb $ \db -> withConn db $ \conn -> do
    [Only pid] <-
        query
            conn
            "INSERT INTO sc_person (email, first_name, last_name, password_hash, is_superadmin) \
            \VALUES (?, ?, ?, ?, ?) RETURNING id"
            (email, firstName, lastName, passwordHash, isSuperadmin)
    pure pid

findPersonDetailById :: (MonadFlow m) => UUID -> m (Maybe PersonDetail)
findPersonDetailById pid = withDb $ \db -> do
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

{- | Dynamic COALESCE update — kept as raw SQL (Beam doesn't support
COALESCE(?, column) in SET clauses cleanly).
-}
updatePerson :: (MonadFlow m) => UUID -> Maybe Text -> Maybe Text -> Maybe Bool -> Maybe Bool -> m ()
updatePerson pid mFirstName mLastName mIsActive mIsSuperadmin = withDb $ \db -> withConn db $ \conn -> do
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

{- | Deactivate a person — kept as raw SQL because Beam's currentTimestamp_
returns LocalTime (not UTCTime), so the UPDATE SET updated_at = now()
is simpler in raw SQL.
-}
deactivatePerson :: (MonadFlow m) => UUID -> m ()
deactivatePerson pid = withDb $ \db -> withConn db $ \conn -> do
    _ <-
        execute
            conn
            "UPDATE sc_person SET is_active = false, updated_at = now() WHERE id = ?"
            (Only pid)
    pure ()

-- ── Role Assignment (ON CONFLICT — kept as raw SQL) ─────────────────

assignRole :: (MonadFlow m) => UUID -> Text -> UUID -> Maybe UUID -> m ()
assignRole personId productSlug roleId grantedBy = withDb $ \db -> withConn db $ \conn -> do
    _ <-
        execute
            conn
            "INSERT INTO sc_person_product_access (person_id, product_slug, role_id, granted_by) \
            \VALUES (?, ?, ?, ?) \
            \ON CONFLICT (person_id, product_slug) DO UPDATE SET role_id = ?, granted_by = ?"
            (personId, productSlug, roleId, grantedBy, roleId, grantedBy)
    pure ()

revokeProductAccess :: (MonadFlow m) => UUID -> Text -> m ()
revokeProductAccess personId productSlug = withDb $ \db ->
    runDB db $
        runDelete $
            delete
                (scPersonProductAccess coreDb)
                (\a -> sppaPersonId a ==. val_ personId &&. sppaProductSlug a ==. val_ productSlug)

-- ── Permission Overrides ────────────────────────────────────────────

-- | INSERT ON CONFLICT RETURNING — kept as raw SQL.
addPermissionOverride :: (MonadFlow m) => UUID -> Text -> Text -> Text -> Maybe UUID -> m UUID
addPermissionOverride personId productSlug permAction overrideType grantedBy = withDb $ \db -> withConn db $ \conn -> do
    [Only oid] <-
        query
            conn
            "INSERT INTO sc_person_permission_override (person_id, product_slug, permission_action, override_type, granted_by) \
            \VALUES (?, ?, ?, ?, ?) \
            \ON CONFLICT (person_id, product_slug, permission_action) DO UPDATE SET override_type = ?, granted_by = ? \
            \RETURNING id"
            (personId, productSlug, permAction, overrideType, grantedBy, overrideType, grantedBy)
    pure oid

removePermissionOverride :: (MonadFlow m) => UUID -> m ()
removePermissionOverride oid = withDb $ \db ->
    runDB db $
        runDelete $
            delete
                (scPersonPermissionOverride coreDb)
                (\o -> sppoId o ==. val_ oid)

listOverridesForPerson :: (MonadFlow m) => UUID -> m [OverrideDetail]
listOverridesForPerson personId = withDb $ \db -> do
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
    { rrId :: UUID
    , rrName :: Text
    , rrDescription :: Maybe Text
    , rrIsSystemRole :: Bool
    , rrPermissions :: Maybe (PGArray Text)
    }
    deriving (Show)

instance FromRow RoleRow where
    fromRow = RoleRow <$> field <*> field <*> field <*> field <*> field

listRolesForProduct :: (MonadFlow m) => Text -> m [RoleDetail]
listRolesForProduct productSlug = withDb $ \db -> withConn db $ \conn -> do
    roleRows <-
        query
            conn
            "SELECT id, name, description, is_system_role, permissions \
            \FROM sc_role WHERE product_slug = ? ORDER BY name"
            (Only productSlug) ::
            IO [RoleRow]
    pure $
        map
            ( \RoleRow{..} ->
                let perms = case (rrIsSystemRole, rrPermissions) of
                        (True, _) -> defaultPermissionsText productSlug rrName
                        (False, Just (PGArray ps)) -> ps
                        (False, Nothing) -> []
                 in RoleDetail rrId rrName rrDescription rrIsSystemRole perms
            )
            roleRows

createRole :: (MonadFlow m) => Text -> Text -> Maybe Text -> [Text] -> m UUID
createRole productSlug name desc permActions = withDb $ \db -> withConn db $ \conn -> do
    [Only roleId] <-
        query
            conn
            "INSERT INTO sc_role (product_slug, name, description, permissions) VALUES (?, ?, ?, ?) RETURNING id"
            (productSlug, name, desc, PGArray permActions)
    pure roleId

updateRolePermissions :: (MonadFlow m) => UUID -> Maybe Text -> [Text] -> m ()
updateRolePermissions roleId mDesc permActions = withDb $ \db -> withConn db $ \conn -> do
    case mDesc of
        Just d -> do
            _ <- execute conn "UPDATE sc_role SET description = ? WHERE id = ?" (d, roleId)
            pure ()
        Nothing -> pure ()
    _ <- execute conn "UPDATE sc_role SET permissions = ? WHERE id = ?" (PGArray permActions, roleId)
    pure ()

-- ── Audit Log ──────────────────────────────────────────────────────

writeAuditLog :: (MonadFlow m) => UUID -> Text -> Maybe Text -> Maybe Text -> Maybe A.Value -> m ()
writeAuditLog personId action entityType entityId details = withDb $ \db ->
    runDB db $
        runInsert $
            insert (scAuditLog coreDb) $
                insertExpressions
                    [ ScAuditLogT
                        { salId = default_
                        , salPersonId = val_ (Just personId)
                        , salAction = val_ action
                        , salEntityType = val_ entityType
                        , salEntityId = val_ entityId
                        , salDetails = val_ details
                        , salCreatedAt = default_
                        }
                    ]
