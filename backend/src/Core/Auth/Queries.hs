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
    computeEffectivePermissions,
    findAllProductsForPerson,
    TokenRow (..),
  )
where

import Core.Auth.Types
import Core.DB.Connection (withConn)
import Core.Environment (DBEnv (..))
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Clock (UTCTime)
import Data.UUID (UUID)
import Database.PostgreSQL.Simple
import Database.PostgreSQL.Simple.FromField (FromField (..))
import Database.PostgreSQL.Simple.FromRow (FromRow (..), field)
import Database.PostgreSQL.Simple.Types (PGArray (..))
import Products.Types (ProductSlug, allPermissionsText, defaultPermissionsText, textToProductSlug)

-- ── Person ──────────────────────────────────────────────────────────

instance FromRow PersonAuth where
  fromRow = PersonAuth <$> field <*> field <*> field <*> field <*> field <*> field <*> field <*> field <*> field

findPersonByEmail :: DBEnv -> Text -> IO (Maybe PersonAuth)
findPersonByEmail db email = withConn db $ \conn -> do
  rows <-
    query
      conn
      "SELECT id, email, first_name, last_name, password_hash, is_active, is_superadmin, created_at, updated_at \
      \FROM sc_person WHERE email = ? AND is_active = true"
      (Only email)
  pure $ case rows of
    [p] -> Just p
    _ -> Nothing

findPersonById :: DBEnv -> UUID -> IO (Maybe PersonAuth)
findPersonById db pid = withConn db $ \conn -> do
  rows <-
    query
      conn
      "SELECT id, email, first_name, last_name, password_hash, is_active, is_superadmin, created_at, updated_at \
      \FROM sc_person WHERE id = ?"
      (Only pid)
  pure $ case rows of
    [p] -> Just p
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

instance FromRow TokenRow where
  fromRow = TokenRow <$> field <*> field <*> field <*> field <*> field <*> field

findTokenByValue :: DBEnv -> Text -> IO (Maybe TokenRow)
findTokenByValue db tok = withConn db $ \conn -> do
  rows <-
    query
      conn
      "SELECT id, person_id, token, is_active, created_at, expires_at \
      \FROM sc_registration_token WHERE token = ? AND is_active = true"
      (Only tok)
  pure $ case rows of
    [t] -> Just t
    _ -> Nothing

insertToken :: DBEnv -> UUID -> Text -> UTCTime -> IO ()
insertToken db personId tok expiresAt = withConn db $ \conn -> do
  _ <-
    execute
      conn
      "INSERT INTO sc_registration_token (person_id, token, expires_at) VALUES (?, ?, ?)"
      (personId, tok, expiresAt)
  pure ()

deactivateToken :: DBEnv -> Text -> IO ()
deactivateToken db tok = withConn db $ \conn -> do
  _ <-
    execute
      conn
      "UPDATE sc_registration_token SET is_active = false WHERE token = ?"
      (Only tok)
  pure ()

deactivateTokensByPerson :: DBEnv -> UUID -> IO ()
deactivateTokensByPerson db pid = withConn db $ \conn -> do
  _ <-
    execute
      conn
      "UPDATE sc_registration_token SET is_active = false WHERE person_id = ?"
      (Only pid)
  pure ()

-- ── Product Access (simplified — no sc_product table) ──────────────

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

-- Custom instance needed for TEXT[] → Maybe [Text]
-- postgresql-simple handles this via PGArray

findProductAccessForPerson :: DBEnv -> UUID -> IO [ProductAccess]
findProductAccessForPerson db pid = withConn db $ \conn -> do
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

-- ── Permission Computation (uses code-derived defaults) ─────────────

-- | Get effective permissions for a person on a product.
-- System roles: permissions derived from Haskell ADTs via defaultPermissionsText
-- Custom roles: permissions from sc_role.permissions TEXT[] column
-- Then apply GRANT/DENY overrides from sc_person_permission_override
computeEffectivePermissions :: DBEnv -> PersonAuth -> Text -> UUID -> IO [Text]
computeEffectivePermissions db person productSlug roleId = do
  if personIsSuperadmin person
    then pure $ allPermissionsText productSlug -- superadmin gets all (from code)
    else do
      -- Get role info
      basePerms <- getRolePermissions db productSlug roleId
      -- Get overrides
      grants <- findGrantOverrides db (personId person) productSlug
      denies <- findDenyOverrides db (personId person) productSlug
      -- Compute: base + GRANTs - DENYs
      let combined = basePerms ++ filter (`notElem` basePerms) grants
          effective = filter (`notElem` denies) combined
      pure effective

-- | Get permissions for a role.
-- System roles (Admin/Manager/Viewer): derived from code
-- Custom roles: from DB permissions TEXT[] column
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
      -- System role: derive from code
      pure $ defaultPermissionsText productSlug roleName
    [(_, False, Just (PGArray perms))] ->
      -- Custom role: from DB
      pure perms
    [(_, False, Nothing)] ->
      pure []
    _ -> pure []

-- ── Overrides (simplified — no sc_permission table) ─────────────────

findGrantOverrides :: DBEnv -> UUID -> Text -> IO [Text]
findGrantOverrides db pid productSlug = withConn db $ \conn -> do
  rows <-
    query
      conn
      "SELECT permission_action FROM sc_person_permission_override \
      \WHERE person_id = ? AND product_slug = ? AND override_type = 'GRANT'"
      (pid, productSlug) ::
      IO [Only Text]
  pure $ map (\(Only a) -> a) rows

findDenyOverrides :: DBEnv -> UUID -> Text -> IO [Text]
findDenyOverrides db pid productSlug = withConn db $ \conn -> do
  rows <-
    query
      conn
      "SELECT permission_action FROM sc_person_permission_override \
      \WHERE person_id = ? AND product_slug = ? AND override_type = 'DENY'"
      (pid, productSlug) ::
      IO [Only Text]
  pure $ map (\(Only a) -> a) rows

-- ── All products for person ────────────────────────────────────────

findAllProductsForPerson :: DBEnv -> PersonAuth -> IO [PersonProductPerms]
findAllProductsForPerson db person = do
  accesses <- findProductAccessForPerson db (personId person)
  mapM
    ( \pa -> do
        perms <- computeEffectivePermissions db person (paProductSlug pa) (paRoleId pa)
        pure $ PersonProductPerms (paProductSlug pa) (paRoleName pa) perms
    )
    accesses
