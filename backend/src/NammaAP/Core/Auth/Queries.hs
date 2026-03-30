{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

module NammaAP.Core.Auth.Queries
  ( findPersonByEmail
  , findPersonById
  , findTokenByValue
  , insertToken
  , deactivateToken
  , deactivateTokensByPerson
  , findProductAccessForPerson
  , findRolePermissions
  , findGrantOverrides
  , findDenyOverrides
  , findAllPermissionsForProduct
  , computeEffectivePermissions
  , findAllProductsForPerson
  , TokenRow (..)
  ) where

import Data.Text (Text)
import Data.Time.Clock (UTCTime)
import Data.UUID (UUID)
import Database.PostgreSQL.Simple
import Database.PostgreSQL.Simple.FromRow (FromRow (..), field)
import NammaAP.Core.Environment (DBEnv (..))
import NammaAP.Core.DB.Connection (withConn)
import NammaAP.Core.Auth.Types

-- ── Person ──────────────────────────────────────────────────────────

instance FromRow PersonAuth where
  fromRow = PersonAuth <$> field <*> field <*> field <*> field <*> field <*> field <*> field <*> field <*> field

findPersonByEmail :: DBEnv -> Text -> IO (Maybe PersonAuth)
findPersonByEmail db email = withConn db $ \conn -> do
  rows <- query conn
    "SELECT id, email, first_name, last_name, password_hash, is_active, is_superadmin, created_at, updated_at \
    \FROM sc_person WHERE email = ? AND is_active = true"
    (Only email)
  pure $ case rows of
    [p] -> Just p
    _   -> Nothing

findPersonById :: DBEnv -> UUID -> IO (Maybe PersonAuth)
findPersonById db pid = withConn db $ \conn -> do
  rows <- query conn
    "SELECT id, email, first_name, last_name, password_hash, is_active, is_superadmin, created_at, updated_at \
    \FROM sc_person WHERE id = ?"
    (Only pid)
  pure $ case rows of
    [p] -> Just p
    _   -> Nothing

-- ── Token ───────────────────────────────────────────────────────────

data TokenRow = TokenRow
  { trId :: UUID
  , trPersonId :: UUID
  , trToken :: Text
  , trIsActive :: Bool
  , trCreatedAt :: UTCTime
  , trExpiresAt :: UTCTime
  } deriving (Show)

instance FromRow TokenRow where
  fromRow = TokenRow <$> field <*> field <*> field <*> field <*> field <*> field

findTokenByValue :: DBEnv -> Text -> IO (Maybe TokenRow)
findTokenByValue db tok = withConn db $ \conn -> do
  rows <- query conn
    "SELECT id, person_id, token, is_active, created_at, expires_at \
    \FROM sc_registration_token WHERE token = ? AND is_active = true"
    (Only tok)
  pure $ case rows of
    [t] -> Just t
    _   -> Nothing

insertToken :: DBEnv -> UUID -> Text -> UTCTime -> IO ()
insertToken db personId tok expiresAt = withConn db $ \conn -> do
  _ <- execute conn
    "INSERT INTO sc_registration_token (person_id, token, expires_at) VALUES (?, ?, ?)"
    (personId, tok, expiresAt)
  pure ()

deactivateToken :: DBEnv -> Text -> IO ()
deactivateToken db tok = withConn db $ \conn -> do
  _ <- execute conn
    "UPDATE sc_registration_token SET is_active = false WHERE token = ?"
    (Only tok)
  pure ()

deactivateTokensByPerson :: DBEnv -> UUID -> IO ()
deactivateTokensByPerson db pid = withConn db $ \conn -> do
  _ <- execute conn
    "UPDATE sc_registration_token SET is_active = false WHERE person_id = ?"
    (Only pid)
  pure ()

-- ── Product Access ──────────────────────────────────────────────────

data ProductAccessRow = ProductAccessRow
  { parProductSlug :: Text
  , parProductName :: Text
  , parRoleId :: UUID
  , parRoleName :: Text
  } deriving (Show)

instance FromRow ProductAccessRow where
  fromRow = ProductAccessRow <$> field <*> field <*> field <*> field

findProductAccessForPerson :: DBEnv -> UUID -> IO [ProductAccess]
findProductAccessForPerson db pid = withConn db $ \conn -> do
  rows <- query conn
    "SELECT p.slug, p.name, r.id, r.name \
    \FROM sc_person_product_access ppa \
    \JOIN sc_product p ON p.id = ppa.product_id \
    \JOIN sc_role r ON r.id = ppa.role_id \
    \WHERE ppa.person_id = ?"
    (Only pid)
  pure $ map (\ProductAccessRow{..} -> ProductAccess parProductSlug parProductName parRoleId parRoleName) rows

-- ── Role Permissions ────────────────────────────────────────────────

findRolePermissions :: DBEnv -> UUID -> IO [Text]
findRolePermissions db roleId = withConn db $ \conn -> do
  rows <- query conn
    "SELECT p.action FROM sc_role_permission rp \
    \JOIN sc_permission p ON p.id = rp.permission_id \
    \WHERE rp.role_id = ?"
    (Only roleId) :: IO [Only Text]
  pure $ map (\(Only a) -> a) rows

-- ── Permission Overrides ────────────────────────────────────────────

findGrantOverrides :: DBEnv -> UUID -> Text -> IO [Text]
findGrantOverrides db pid productSlug = withConn db $ \conn -> do
  rows <- query conn
    "SELECT p.action FROM sc_person_permission_override ppo \
    \JOIN sc_permission p ON p.id = ppo.permission_id \
    \JOIN sc_product pr ON pr.id = ppo.product_id \
    \WHERE ppo.person_id = ? AND pr.slug = ? AND ppo.override_type = 'GRANT'"
    (pid, productSlug) :: IO [Only Text]
  pure $ map (\(Only a) -> a) rows

findDenyOverrides :: DBEnv -> UUID -> Text -> IO [Text]
findDenyOverrides db pid productSlug = withConn db $ \conn -> do
  rows <- query conn
    "SELECT p.action FROM sc_person_permission_override ppo \
    \JOIN sc_permission p ON p.id = ppo.permission_id \
    \JOIN sc_product pr ON pr.id = ppo.product_id \
    \WHERE ppo.person_id = ? AND pr.slug = ? AND ppo.override_type = 'DENY'"
    (pid, productSlug) :: IO [Only Text]
  pure $ map (\(Only a) -> a) rows

-- ── Helpers ─────────────────────────────────────────────────────────

findAllPermissionsForProduct :: DBEnv -> Text -> IO [Text]
findAllPermissionsForProduct db productSlug = withConn db $ \conn -> do
  rows <- query conn
    "SELECT p.action FROM sc_permission p \
    \JOIN sc_product pr ON pr.id = p.product_id \
    \WHERE pr.slug = ?"
    (Only productSlug) :: IO [Only Text]
  pure $ map (\(Only a) -> a) rows

-- | Compute effective permissions for a person on a product.
-- effective = role_perms + GRANTs - DENYs
-- Superadmins get all permissions.
computeEffectivePermissions :: DBEnv -> PersonAuth -> Text -> UUID -> IO [Text]
computeEffectivePermissions db person productSlug roleId = do
  if personIsSuperadmin person
    then findAllPermissionsForProduct db productSlug
    else do
      rolePerms <- findRolePermissions db roleId
      grants <- findGrantOverrides db (personId person) productSlug
      denies <- findDenyOverrides db (personId person) productSlug
      let combined = rolePerms ++ filter (`notElem` rolePerms) grants
          effective = filter (`notElem` denies) combined
      pure effective

-- | Get all product access with effective permissions for a person
findAllProductsForPerson :: DBEnv -> PersonAuth -> IO [PersonProductPerms]
findAllProductsForPerson db person = do
  accesses <- findProductAccessForPerson db (personId person)
  mapM (\pa -> do
    perms <- computeEffectivePermissions db person (paProductSlug pa) (paRoleId pa)
    pure $ PersonProductPerms (paProductSlug pa) (paRoleName pa) perms
    ) accesses
