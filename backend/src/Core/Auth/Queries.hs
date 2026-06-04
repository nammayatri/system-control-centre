{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

module Core.Auth.Queries (
    findPersonByEmail,
    findPersonById,
    findTokenByValue,
    insertToken,
    deactivateToken,
    deactivateTokensByPerson,
    findProductAccessForPerson,
    computeEffectivePermissions,
    findAllProductsForPerson,
    resetPasswordByEmail,
    TokenRow (..),
)
where

import Core.Auth.Schema
import Core.Auth.Types
import Core.DB.Connection (runDB, withConn)
import Core.Environment (DBEnv (..), MonadFlow, withDb)
import Data.Text (Text)
import Data.Time.Clock (UTCTime)
import Data.Int (Int64)
import Data.UUID (UUID)
import Database.Beam
import Database.Beam.Postgres ()
import Database.PostgreSQL.Simple (Only (..), execute, query)
import Database.PostgreSQL.Simple.FromRow (FromRow (..), field)
import Database.PostgreSQL.Simple.Types (PGArray (..))
import Products.Types (allPermissionsText, defaultPermissionsText)

-- ── Beam-row → domain-type converters ──────────────────────────────

toPersonAuth :: ScPerson -> PersonAuth
toPersonAuth ScPersonT{..} =
    PersonAuth
        { personId = spId
        , personEmail = spEmail
        , personFirstName = spFirstName
        , personLastName = spLastName
        , personPasswordHash = spPasswordHash
        , personIsActive = spIsActive
        , personIsSuperadmin = spIsSuperadmin
        , personCreatedAt = spCreatedAt
        , personUpdatedAt = spUpdatedAt
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
    { trId :: UUID
    , trPersonId :: UUID
    , trToken :: Text
    , trIsActive :: Bool
    , trCreatedAt :: UTCTime
    , trExpiresAt :: UTCTime
    }
    deriving (Show)

toTokenRow :: ScRegistrationToken -> TokenRow
toTokenRow ScRegistrationTokenT{..} =
    TokenRow
        { trId = srtId
        , trPersonId = srtPersonId
        , trToken = srtToken
        , trIsActive = srtIsActive
        , trCreatedAt = srtCreatedAt
        , trExpiresAt = srtExpiresAt
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
                        { srtId = default_
                        , srtPersonId = val_ personId
                        , srtToken = val_ tok
                        , srtIsActive = val_ True
                        , srtCreatedAt = default_
                        , srtExpiresAt = val_ expiresAt
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
    { parProductSlug :: Text
    , parRoleId :: UUID
    , parRoleName :: Text
    , parIsSystemRole :: Bool
    , parPermissions :: Maybe (PGArray Text)
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
            ( \ProductAccessRow{..} ->
                ProductAccess parProductSlug parProductSlug parRoleId parRoleName
            )
            rows

findProductAccessForPerson :: (MonadFlow m) => UUID -> m [ProductAccess]
findProductAccessForPerson pid = withDb $ \db -> findProductAccessForPersonIO db pid

-- ── Permission Computation (uses code-derived defaults) ─────────────

{- | Get effective permissions for a person on a product.
System roles: permissions derived from Haskell ADTs via defaultPermissionsText
Custom roles: permissions from sc_role.permissions TEXT[] column
Then apply GRANT/DENY overrides from sc_person_permission_override
-}
computeEffectivePermissionsIO :: DBEnv -> PersonAuth -> Text -> UUID -> IO [Text]
computeEffectivePermissionsIO db person productSlug roleId = do
    if personIsSuperadmin person
        then pure $ allPermissionsText productSlug
        else do
            basePerms <- getRolePermissions db productSlug roleId
            grants <- findGrantOverrides db (personId person) productSlug
            denies <- findDenyOverrides db (personId person) productSlug
            let combined = basePerms ++ filter (`notElem` basePerms) grants
                effective = filter (`notElem` denies) combined
            pure effective

computeEffectivePermissions :: (MonadFlow m) => PersonAuth -> Text -> UUID -> m [Text]
computeEffectivePermissions person productSlug roleId =
    withDb $ \db -> computeEffectivePermissionsIO db person productSlug roleId

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
                        ( sppoPersonId o ==. val_ pid
                            &&. sppoProductSlug o ==. val_ productSlug
                            &&. sppoOverrideType o ==. val_ "GRANT"
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
                        ( sppoPersonId o ==. val_ pid
                            &&. sppoProductSlug o ==. val_ productSlug
                            &&. sppoOverrideType o ==. val_ "DENY"
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

-- ── Password Reset ─────────────────────────────────────────────────

resetPasswordByEmail :: (MonadFlow m) => Text -> Text -> m Bool
resetPasswordByEmail email newPassword = withDb $ \db -> withConn db $ \conn -> do
    n <-
        execute
            conn
            "UPDATE sc_person SET password_hash = ?, updated_at = now() WHERE email = ? AND is_active = true"
            (newPassword, email)
    pure (n > 0)
