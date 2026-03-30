{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TypeOperators #-}

module NammaAP.Core.Admin.Routes
  ( AdminAPI
  , adminServer
  ) where

import Control.Monad.IO.Class (liftIO)
import Data.Aeson (Value (..), object, (.=))
import qualified Data.Aeson.Key as K
import qualified Data.Aeson.KeyMap as KM
import Data.Foldable (toList)
import Data.Text (Text)
import qualified Data.Text as T
import Data.UUID (UUID)
import qualified Data.UUID as UUID
import Servant

import NammaAP.Core.Admin.Types
import NammaAP.Core.Admin.Queries
import NammaAP.Products.Types (ProductSlug (..), productSlugToText, allPermissionsText)
import NammaAP.Core.Auth.Types (PersonAuth (..), PersonProductPerms (..))
import NammaAP.Core.Auth.Queries (findPersonById, findProductAccessForPerson, findAllProductsForPerson, findTokenByValue, TokenRow (..))
import NammaAP.Products.Autopilot.Types.API (APIResponse (..))
import NammaAP.Core.Utils.FlowMonad (Flow, getDBEnv)

-- | Admin API type
type AdminAPI =
  -- Users
       "users" :> Header "Authorization" Text :> Get '[JSON] Value
  :<|> "users" :> Header "Authorization" Text :> ReqBody '[JSON] Value :> Post '[JSON] Value
  :<|> "users" :> Capture "userId" UUID :> Header "Authorization" Text :> Get '[JSON] Value
  :<|> "users" :> Capture "userId" UUID :> Header "Authorization" Text :> ReqBody '[JSON] Value :> Put '[JSON] APIResponse
  :<|> "users" :> Capture "userId" UUID :> Header "Authorization" Text :> Delete '[JSON] APIResponse
  :<|> "users" :> Capture "userId" UUID :> "assign-role" :> Header "Authorization" Text :> ReqBody '[JSON] Value :> Post '[JSON] APIResponse
  :<|> "users" :> Capture "userId" UUID :> "product-access" :> Capture "productSlug" Text :> Header "Authorization" Text :> Delete '[JSON] APIResponse
  :<|> "users" :> Capture "userId" UUID :> "permission-override" :> Header "Authorization" Text :> ReqBody '[JSON] Value :> Post '[JSON] Value
  :<|> "users" :> Capture "userId" UUID :> "permission-override" :> Capture "overrideId" UUID :> Header "Authorization" Text :> Delete '[JSON] APIResponse
  -- Products
  :<|> "products" :> Header "Authorization" Text :> Get '[JSON] Value
  :<|> "products" :> Header "Authorization" Text :> ReqBody '[JSON] Value :> Post '[JSON] Value
  :<|> "products" :> Capture "slug" Text :> "roles" :> Header "Authorization" Text :> Get '[JSON] Value
  :<|> "products" :> Capture "slug" Text :> "roles" :> Header "Authorization" Text :> ReqBody '[JSON] Value :> Post '[JSON] Value
  :<|> "products" :> Capture "slug" Text :> "roles" :> Capture "roleId" UUID :> Header "Authorization" Text :> ReqBody '[JSON] Value :> Put '[JSON] APIResponse
  :<|> "products" :> Capture "slug" Text :> "permissions" :> Header "Authorization" Text :> Get '[JSON] Value

adminServer :: ServerT AdminAPI Flow
adminServer =
       listUsersH
  :<|> createUserH
  :<|> getUserH
  :<|> updateUserH
  :<|> deleteUserH
  :<|> assignRoleH
  :<|> revokeAccessH
  :<|> addOverrideH
  :<|> removeOverrideH
  :<|> listProductsH
  :<|> createProductH
  :<|> listRolesH
  :<|> createRoleH
  :<|> updateRoleH
  :<|> listPermissionsH

-- ── Helpers ─────────────────────────────────────────────────────────

requireAdmin :: Maybe Text -> Flow (Maybe PersonAuth)
requireAdmin mAuth = do
  db <- getDBEnv
  case extractToken mAuth of
    Nothing -> pure Nothing
    Just tok -> do
      mToken <- liftIO $ findTokenByValue db tok
      case mToken of
        Nothing -> pure Nothing
        Just tokenRow -> do
          mPerson <- liftIO $ findPersonById db (trPersonId tokenRow)
          case mPerson of
            Nothing -> pure Nothing
            Just person ->
              if personIsSuperadmin person
                then pure (Just person)
                else pure Nothing

extractToken :: Maybe Text -> Maybe Text
extractToken Nothing = Nothing
extractToken (Just h) =
  let stripped = T.strip h
  in case T.stripPrefix "Bearer " stripped of
    Just t -> Just (T.strip t)
    Nothing -> Just stripped

getStr :: Text -> KM.KeyMap Value -> Text
getStr k obj = case KM.lookup (K.fromText k) obj of
  Just (String t) -> t
  _ -> ""

getStrM :: Text -> KM.KeyMap Value -> Maybe Text
getStrM k obj = case KM.lookup (K.fromText k) obj of
  Just (String t) | not (T.null t) -> Just t
  _ -> Nothing

getBoolM :: Text -> KM.KeyMap Value -> Maybe Bool
getBoolM k obj = case KM.lookup (K.fromText k) obj of
  Just (Bool b) -> Just b
  _ -> Nothing

getStrListM :: Text -> KM.KeyMap Value -> [Text]
getStrListM k obj = case KM.lookup (K.fromText k) obj of
  Just (Array arr) -> concatMap extractStr (toList arr)
  _ -> []
  where
    extractStr (String t) = [t]
    extractStr _ = []

getUuidListM :: Text -> KM.KeyMap Value -> [UUID]
getUuidListM k obj = case KM.lookup (K.fromText k) obj of
  Just (Array arr) -> concatMap extractUuid (toList arr)
  _ -> []
  where
    extractUuid (String t) = case UUID.fromText t of
      Just u -> [u]
      Nothing -> []
    extractUuid _ = []

getUuidM :: Text -> KM.KeyMap Value -> Maybe UUID
getUuidM k obj = case KM.lookup (K.fromText k) obj of
  Just (String t) -> UUID.fromText t
  _ -> Nothing

-- ── Handlers ────────────────────────────────────────────────────────

listUsersH :: Maybe Text -> Flow Value
listUsersH mAuth = do
  mAdmin <- requireAdmin mAuth
  case mAdmin of
    Nothing -> pure $ object ["error" .= ("Unauthorized: superadmin required" :: Text)]
    Just _ -> do
      db <- getDBEnv
      users <- liftIO $ listPersons db
      pure $ object ["users" .= map personDetailToJson users]

createUserH :: Maybe Text -> Value -> Flow Value
createUserH mAuth (Object obj) = do
  mAdmin <- requireAdmin mAuth
  case mAdmin of
    Nothing -> pure $ object ["error" .= ("Unauthorized: superadmin required" :: Text)]
    Just admin -> do
      db <- getDBEnv
      let email = getStr "email" obj
          firstName = getStr "firstName" obj
          lastName = getStr "lastName" obj
          password = getStr "password" obj
          isSuperadmin = maybe False id (getBoolM "isSuperadmin" obj)
      if T.null email || T.null firstName || T.null password
        then pure $ object ["error" .= ("email, firstName, and password are required" :: Text)]
        else do
          pid <- liftIO $ createPerson db email firstName lastName password isSuperadmin
          liftIO $ writeAuditLog db (personId admin) "USER_CREATED" (Just "person") (Just $ UUID.toText pid) Nothing
          pure $ object ["id" .= pid, "status" .= ("SUCCESS" :: Text)]
createUserH _ _ = pure $ object ["error" .= ("Invalid request body" :: Text)]

getUserH :: UUID -> Maybe Text -> Flow Value
getUserH userId mAuth = do
  mAdmin <- requireAdmin mAuth
  case mAdmin of
    Nothing -> pure $ object ["error" .= ("Unauthorized: superadmin required" :: Text)]
    Just _ -> do
      db <- getDBEnv
      mPerson <- liftIO $ findPersonDetailById db userId
      case mPerson of
        Nothing -> pure $ object ["error" .= ("User not found" :: Text)]
        Just pd -> do
          mAuth' <- liftIO $ findPersonById db userId
          products <- case mAuth' of
            Nothing -> pure []
            Just person -> liftIO $ findAllProductsForPerson db person
          overrides <- liftIO $ listOverridesForPerson db userId
          pure $ object
            [ "user" .= personDetailToJson pd
            , "products" .= map (\PersonProductPerms{..} -> object
                [ "slug" .= pppProductSlug
                , "role" .= pppRoleName
                , "permissions" .= pppPermissions
                ]) products
            , "overrides" .= map overrideToJson overrides
            ]

updateUserH :: UUID -> Maybe Text -> Value -> Flow APIResponse
updateUserH userId mAuth (Object obj) = do
  mAdmin <- requireAdmin mAuth
  case mAdmin of
    Nothing -> pure $ APIResponse "ERROR" "Unauthorized: superadmin required"
    Just _ -> do
      db <- getDBEnv
      liftIO $ updatePerson db userId
        (getStrM "firstName" obj)
        (getStrM "lastName" obj)
        (getBoolM "isActive" obj)
        (getBoolM "isSuperadmin" obj)
      pure $ APIResponse "SUCCESS" "User updated"
updateUserH _ _ _ = pure $ APIResponse "ERROR" "Invalid request body"

deleteUserH :: UUID -> Maybe Text -> Flow APIResponse
deleteUserH userId mAuth = do
  mAdmin <- requireAdmin mAuth
  case mAdmin of
    Nothing -> pure $ APIResponse "ERROR" "Unauthorized: superadmin required"
    Just admin -> do
      db <- getDBEnv
      liftIO $ deactivatePerson db userId
      liftIO $ writeAuditLog db (personId admin) "USER_DEACTIVATED" (Just "person") (Just $ UUID.toText userId) Nothing
      pure $ APIResponse "SUCCESS" "User deactivated"

assignRoleH :: UUID -> Maybe Text -> Value -> Flow APIResponse
assignRoleH userId mAuth (Object obj) = do
  mAdmin <- requireAdmin mAuth
  case mAdmin of
    Nothing -> pure $ APIResponse "ERROR" "Unauthorized: superadmin required"
    Just admin -> do
      db <- getDBEnv
      let productSlug = getStr "productSlug" obj
          mRoleId = getUuidM "roleId" obj
      case mRoleId of
        Nothing -> pure $ APIResponse "ERROR" "roleId is required"
        Just roleId -> do
          liftIO $ assignRole db userId productSlug roleId (Just (personId admin))
          liftIO $ writeAuditLog db (personId admin) "ROLE_ASSIGNED" (Just "person_product_access") (Just $ UUID.toText userId) Nothing
          pure $ APIResponse "SUCCESS" "Role assigned"
assignRoleH _ _ _ = pure $ APIResponse "ERROR" "Invalid request body"

revokeAccessH :: UUID -> Text -> Maybe Text -> Flow APIResponse
revokeAccessH userId productSlug mAuth = do
  mAdmin <- requireAdmin mAuth
  case mAdmin of
    Nothing -> pure $ APIResponse "ERROR" "Unauthorized: superadmin required"
    Just admin -> do
      db <- getDBEnv
      liftIO $ revokeProductAccess db userId productSlug
      liftIO $ writeAuditLog db (personId admin) "ACCESS_REVOKED" (Just "person_product_access") (Just $ UUID.toText userId) Nothing
      pure $ APIResponse "SUCCESS" "Product access revoked"

addOverrideH :: UUID -> Maybe Text -> Value -> Flow Value
addOverrideH userId mAuth (Object obj) = do
  mAdmin <- requireAdmin mAuth
  case mAdmin of
    Nothing -> pure $ object ["error" .= ("Unauthorized: superadmin required" :: Text)]
    Just admin -> do
      db <- getDBEnv
      let productSlug = getStr "productSlug" obj
          permAction = getStr "permissionAction" obj
          overrideType = getStr "overrideType" obj
      if T.null productSlug || T.null permAction || T.null overrideType
        then pure $ object ["error" .= ("productSlug, permissionAction, and overrideType are required" :: Text)]
        else if overrideType /= "GRANT" && overrideType /= "DENY"
          then pure $ object ["error" .= ("overrideType must be GRANT or DENY" :: Text)]
          else do
            -- Validate permission against ADT (no DB lookup needed)
            let validPerms = allPermissionsText productSlug
            if permAction `notElem` validPerms
              then pure $ object ["error" .= ("Invalid permission for product: " <> permAction :: Text)]
              else do
                oid <- liftIO $ addPermissionOverride db userId productSlug permAction overrideType (Just (personId admin))
                pure $ object ["id" .= oid, "status" .= ("SUCCESS" :: Text)]
addOverrideH _ _ _ = pure $ object ["error" .= ("Invalid request body" :: Text)]

removeOverrideH :: UUID -> UUID -> Maybe Text -> Flow APIResponse
removeOverrideH _userId overrideId mAuth = do
  mAdmin <- requireAdmin mAuth
  case mAdmin of
    Nothing -> pure $ APIResponse "ERROR" "Unauthorized: superadmin required"
    Just _ -> do
      db <- getDBEnv
      liftIO $ removePermissionOverride db overrideId
      pure $ APIResponse "SUCCESS" "Override removed"

listProductsH :: Maybe Text -> Flow Value
listProductsH mAuth = do
  mAdmin <- requireAdmin mAuth
  case mAdmin of
    Nothing -> pure $ object ["error" .= ("Unauthorized: superadmin required" :: Text)]
    Just _ -> do
      -- Products are derived from ProductSlug ADT — no DB query needed
      let prods = map (\slug -> object
            [ "slug" .= productSlugToText slug
            , "name" .= productSlugToText slug
            ]) [minBound .. maxBound :: ProductSlug]
      pure $ object ["products" .= prods]

createProductH :: Maybe Text -> Value -> Flow Value
createProductH _ _ = do
  -- Products are defined as Haskell ADTs — they cannot be created via API.
  -- To add a new product, add it to ProductSlug in Products/Types.hs
  pure $ object ["error" .= ("Products are defined in code, not via API. Add to ProductSlug ADT." :: Text)]

listRolesH :: Text -> Maybe Text -> Flow Value
listRolesH slug mAuth = do
  mAdmin <- requireAdmin mAuth
  case mAdmin of
    Nothing -> pure $ object ["error" .= ("Unauthorized: superadmin required" :: Text)]
    Just _ -> do
      db <- getDBEnv
      roles <- liftIO $ listRolesForProduct db slug
      pure $ object ["roles" .= map roleToJson roles]

createRoleH :: Text -> Maybe Text -> Value -> Flow Value
createRoleH slug mAuth (Object obj) = do
  mAdmin <- requireAdmin mAuth
  case mAdmin of
    Nothing -> pure $ object ["error" .= ("Unauthorized: superadmin required" :: Text)]
    Just _ -> do
      db <- getDBEnv
      let name = getStr "name" obj
          desc = getStrM "description" obj
          permActions = getStrListM "permissions" obj
      if T.null name
        then pure $ object ["error" .= ("name is required" :: Text)]
        else do
          roleId <- liftIO $ createRole db slug name desc permActions
          pure $ object ["id" .= roleId, "status" .= ("SUCCESS" :: Text)]
createRoleH _ _ _ = pure $ object ["error" .= ("Invalid request body" :: Text)]

updateRoleH :: Text -> UUID -> Maybe Text -> Value -> Flow APIResponse
updateRoleH _slug roleId mAuth (Object obj) = do
  mAdmin <- requireAdmin mAuth
  case mAdmin of
    Nothing -> pure $ APIResponse "ERROR" "Unauthorized: superadmin required"
    Just _ -> do
      db <- getDBEnv
      let desc = getStrM "description" obj
          permActions = getStrListM "permissions" obj
      liftIO $ updateRolePermissions db roleId desc permActions
      pure $ APIResponse "SUCCESS" "Role updated"
updateRoleH _ _ _ _ = pure $ APIResponse "ERROR" "Invalid request body"

listPermissionsH :: Text -> Maybe Text -> Flow Value
listPermissionsH slug mAuth = do
  mAdmin <- requireAdmin mAuth
  case mAdmin of
    Nothing -> pure $ object ["error" .= ("Unauthorized: superadmin required" :: Text)]
    Just _ -> do
      -- Permissions are derived from ADTs — no DB query needed
      let perms = allPermissionsText slug
      pure $ object ["permissions" .= map (\p -> object ["action" .= p]) perms]

-- ── JSON serializers ────────────────────────────────────────────────

personDetailToJson :: PersonDetail -> Value
personDetailToJson PersonDetail{..} = object
  [ "id" .= pdId
  , "email" .= pdEmail
  , "firstName" .= pdFirstName
  , "lastName" .= pdLastName
  , "isActive" .= pdIsActive
  , "isSuperadmin" .= pdIsSuperadmin
  , "createdAt" .= pdCreatedAt
  ]

productToJson :: ProductDetail -> Value
productToJson ProductDetail{..} = object
  [ "id" .= prodId
  , "slug" .= prodSlug
  , "name" .= prodName
  , "description" .= prodDescription
  , "isActive" .= prodIsActive
  ]

roleToJson :: RoleDetail -> Value
roleToJson RoleDetail{..} = object
  [ "id" .= rdId
  , "name" .= rdName
  , "description" .= rdDescription
  , "isSystemRole" .= rdIsSystemRole
  , "permissions" .= rdPermissions
  ]

permToJson :: PermissionDetail -> Value
permToJson PermissionDetail{..} = object
  [ "id" .= permId
  , "action" .= permAction
  , "description" .= permDescription
  ]

overrideToJson :: OverrideDetail -> Value
overrideToJson OverrideDetail{..} = object
  [ "id" .= odId
  , "permissionAction" .= odPermissionAction
  , "overrideType" .= odOverrideType
  , "productSlug" .= odProductSlug
  ]
