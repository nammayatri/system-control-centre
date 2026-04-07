{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

module Core.Admin.Queries (
    -- Person CRUD (polymorphic wrappers — preferred)
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
    -- IO versions (kept for IO callers)
    listPersons_io,
    createPerson_io,
    findPersonDetailById_io,
    updatePerson_io,
    deactivatePerson_io,
    assignRole_io,
    revokeProductAccess_io,
    addPermissionOverride_io,
    removePermissionOverride_io,
    listOverridesForPerson_io,
    listRolesForProduct_io,
    createRole_io,
    updateRolePermissions_io,
    writeAuditLog_io,
)
where

import Core.Admin.Types
import Core.Auth.Schema
import Core.DB.Connection (runDB, withConn)
import Core.Environment (DBEnv (..), MonadFlow, withDb)
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

listPersons_io :: DBEnv -> IO [PersonDetail]
listPersons_io db = do
    rows <-
        runDB db $
            runSelectReturningList $
                select $
                    orderBy_ (\p -> desc_ (spCreatedAt p)) $
                        all_ (scPerson coreDb)
    pure $ map toPersonDetail rows

listPersons :: (MonadFlow m) => m [PersonDetail]
listPersons = withDb $ \db -> listPersons_io db

{- | INSERT RETURNING — kept as raw SQL (Beam RETURNING is Postgres-specific
and verbose for a single-value return).
-}
createPerson_io :: DBEnv -> Text -> Text -> Text -> Text -> Bool -> IO UUID
createPerson_io db email firstName lastName passwordHash isSuperadmin = withConn db $ \conn -> do
    [Only pid] <-
        query
            conn
            "INSERT INTO sc_person (email, first_name, last_name, password_hash, is_superadmin) \
            \VALUES (?, ?, ?, ?, ?) RETURNING id"
            (email, firstName, lastName, passwordHash, isSuperadmin)
    pure pid

createPerson :: (MonadFlow m) => Text -> Text -> Text -> Text -> Bool -> m UUID
createPerson email firstName lastName passwordHash isSuperadmin =
    withDb $ \db -> createPerson_io db email firstName lastName passwordHash isSuperadmin

findPersonDetailById_io :: DBEnv -> UUID -> IO (Maybe PersonDetail)
findPersonDetailById_io db pid = do
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

findPersonDetailById :: (MonadFlow m) => UUID -> m (Maybe PersonDetail)
findPersonDetailById pid = withDb $ \db -> findPersonDetailById_io db pid

{- | Dynamic COALESCE update — kept as raw SQL (Beam doesn't support
COALESCE(?, column) in SET clauses cleanly).
-}
updatePerson_io :: DBEnv -> UUID -> Maybe Text -> Maybe Text -> Maybe Bool -> Maybe Bool -> IO ()
updatePerson_io db pid mFirstName mLastName mIsActive mIsSuperadmin = withConn db $ \conn -> do
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

updatePerson :: (MonadFlow m) => UUID -> Maybe Text -> Maybe Text -> Maybe Bool -> Maybe Bool -> m ()
updatePerson pid mFirstName mLastName mIsActive mIsSuperadmin =
    withDb $ \db -> updatePerson_io db pid mFirstName mLastName mIsActive mIsSuperadmin

{- | Deactivate a person — kept as raw SQL because Beam's currentTimestamp_
returns LocalTime (not UTCTime), so the UPDATE SET updated_at = now()
is simpler in raw SQL.
-}
deactivatePerson_io :: DBEnv -> UUID -> IO ()
deactivatePerson_io db pid = withConn db $ \conn -> do
    _ <-
        execute
            conn
            "UPDATE sc_person SET is_active = false, updated_at = now() WHERE id = ?"
            (Only pid)
    pure ()

deactivatePerson :: (MonadFlow m) => UUID -> m ()
deactivatePerson pid = withDb $ \db -> deactivatePerson_io db pid

-- ── Role Assignment (ON CONFLICT — kept as raw SQL) ─────────────────

assignRole_io :: DBEnv -> UUID -> Text -> UUID -> Maybe UUID -> IO ()
assignRole_io db personId productSlug roleId grantedBy = withConn db $ \conn -> do
    _ <-
        execute
            conn
            "INSERT INTO sc_person_product_access (person_id, product_slug, role_id, granted_by) \
            \VALUES (?, ?, ?, ?) \
            \ON CONFLICT (person_id, product_slug) DO UPDATE SET role_id = ?, granted_by = ?"
            (personId, productSlug, roleId, grantedBy, roleId, grantedBy)
    pure ()

assignRole :: (MonadFlow m) => UUID -> Text -> UUID -> Maybe UUID -> m ()
assignRole personId productSlug roleId grantedBy =
    withDb $ \db -> assignRole_io db personId productSlug roleId grantedBy

revokeProductAccess_io :: DBEnv -> UUID -> Text -> IO ()
revokeProductAccess_io db personId productSlug =
    runDB db $
        runDelete $
            delete
                (scPersonProductAccess coreDb)
                (\a -> sppaPersonId a ==. val_ personId &&. sppaProductSlug a ==. val_ productSlug)

revokeProductAccess :: (MonadFlow m) => UUID -> Text -> m ()
revokeProductAccess personId productSlug = withDb $ \db -> revokeProductAccess_io db personId productSlug

-- ── Permission Overrides ────────────────────────────────────────────

-- | INSERT ON CONFLICT RETURNING — kept as raw SQL.
addPermissionOverride_io :: DBEnv -> UUID -> Text -> Text -> Text -> Maybe UUID -> IO UUID
addPermissionOverride_io db personId productSlug permAction overrideType grantedBy = withConn db $ \conn -> do
    [Only oid] <-
        query
            conn
            "INSERT INTO sc_person_permission_override (person_id, product_slug, permission_action, override_type, granted_by) \
            \VALUES (?, ?, ?, ?, ?) \
            \ON CONFLICT (person_id, product_slug, permission_action) DO UPDATE SET override_type = ?, granted_by = ? \
            \RETURNING id"
            (personId, productSlug, permAction, overrideType, grantedBy, overrideType, grantedBy)
    pure oid

addPermissionOverride :: (MonadFlow m) => UUID -> Text -> Text -> Text -> Maybe UUID -> m UUID
addPermissionOverride personId productSlug permAction overrideType grantedBy =
    withDb $ \db -> addPermissionOverride_io db personId productSlug permAction overrideType grantedBy

removePermissionOverride_io :: DBEnv -> UUID -> IO ()
removePermissionOverride_io db oid =
    runDB db $
        runDelete $
            delete
                (scPersonPermissionOverride coreDb)
                (\o -> sppoId o ==. val_ oid)

removePermissionOverride :: (MonadFlow m) => UUID -> m ()
removePermissionOverride oid = withDb $ \db -> removePermissionOverride_io db oid

listOverridesForPerson_io :: DBEnv -> UUID -> IO [OverrideDetail]
listOverridesForPerson_io db personId = do
    rows <-
        runDB db $
            runSelectReturningList $
                select $ do
                    o <- all_ (scPersonPermissionOverride coreDb)
                    guard_ (sppoPersonId o ==. val_ personId)
                    pure o
    pure $ map toOverrideDetail rows

listOverridesForPerson :: (MonadFlow m) => UUID -> m [OverrideDetail]
listOverridesForPerson personId = withDb $ \db -> listOverridesForPerson_io db personId

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

listRolesForProduct_io :: DBEnv -> Text -> IO [RoleDetail]
listRolesForProduct_io db productSlug = withConn db $ \conn -> do
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

listRolesForProduct :: (MonadFlow m) => Text -> m [RoleDetail]
listRolesForProduct productSlug = withDb $ \db -> listRolesForProduct_io db productSlug

createRole_io :: DBEnv -> Text -> Text -> Maybe Text -> [Text] -> IO UUID
createRole_io db productSlug name desc permActions = withConn db $ \conn -> do
    [Only roleId] <-
        query
            conn
            "INSERT INTO sc_role (product_slug, name, description, permissions) VALUES (?, ?, ?, ?) RETURNING id"
            (productSlug, name, desc, PGArray permActions)
    pure roleId

createRole :: (MonadFlow m) => Text -> Text -> Maybe Text -> [Text] -> m UUID
createRole productSlug name desc permActions =
    withDb $ \db -> createRole_io db productSlug name desc permActions

updateRolePermissions_io :: DBEnv -> UUID -> Maybe Text -> [Text] -> IO ()
updateRolePermissions_io db roleId mDesc permActions = withConn db $ \conn -> do
    case mDesc of
        Just d -> do
            _ <- execute conn "UPDATE sc_role SET description = ? WHERE id = ?" (d, roleId)
            pure ()
        Nothing -> pure ()
    _ <- execute conn "UPDATE sc_role SET permissions = ? WHERE id = ?" (PGArray permActions, roleId)
    pure ()

updateRolePermissions :: (MonadFlow m) => UUID -> Maybe Text -> [Text] -> m ()
updateRolePermissions roleId mDesc permActions =
    withDb $ \db -> updateRolePermissions_io db roleId mDesc permActions

-- ── Audit Log ──────────────────────────────────────────────────────

writeAuditLog_io :: DBEnv -> UUID -> Text -> Maybe Text -> Maybe Text -> Maybe A.Value -> IO ()
writeAuditLog_io db personId action entityType entityId details =
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

writeAuditLog :: (MonadFlow m) => UUID -> Text -> Maybe Text -> Maybe Text -> Maybe A.Value -> m ()
writeAuditLog personId action entityType entityId details =
    withDb $ \db -> writeAuditLog_io db personId action entityType entityId details
