{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TypeOperators #-}

module Core.Admin.Routes (
    AdminAPI,
    adminServer,
)
where

import Control.Monad.Catch (throwM)
import Control.Monad.IO.Class (liftIO)
import Core.Admin.Queries
import Core.Admin.Types
import Core.AppError (APIError (..), AuthError (..))
import Core.Auth.Queries (TokenRow (..), findAllProductsForPerson, findPersonById, findTokenByValue)
import Core.Auth.Types (PersonAuth (..), PersonProductPerms (..))
import Core.Utils.FlowMonad (Flow, getDBEnv)
import Data.Aeson (Value (..), object, (.=))
import qualified Data.Aeson.Key as K
import qualified Data.Aeson.KeyMap as KM
import Data.Foldable (toList)
import Data.Text (Text)
import qualified Data.Text as T
import Data.UUID (UUID)
import qualified Data.UUID as UUID
import Products.Types (ProductSlug (..), allPermissionsText, productSlugToText)
import Servant hiding (Unauthorized)
import Shared.API.Response (APIResponse (..))

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

getUuidM :: Text -> KM.KeyMap Value -> Maybe UUID
getUuidM k obj = case KM.lookup (K.fromText k) obj of
    Just (String t) -> UUID.fromText t
    _ -> Nothing

-- ── Handlers ────────────────────────────────────────────────────────

listUsersH :: Maybe Text -> Flow Value
listUsersH mAuth = do
    mAdmin <- requireAdmin mAuth
    case mAdmin of
        Nothing -> throwM $ PermissionDenied "Superadmin required"
        Just _ -> do
            db <- getDBEnv
            users <- liftIO $ listPersons db
            pure $ object ["users" .= map personDetailToJson users]

createUserH :: Maybe Text -> Value -> Flow Value
createUserH mAuth (Object obj) = do
    mAdmin <- requireAdmin mAuth
    case mAdmin of
        Nothing -> throwM $ PermissionDenied "Superadmin required"
        Just admin -> do
            db <- getDBEnv
            let email = getStr "email" obj
                firstName = getStr "firstName" obj
                lastName = getStr "lastName" obj
                password = getStr "password" obj
                isSuperadmin = maybe False id (getBoolM "isSuperadmin" obj)
            if T.null email || T.null firstName || T.null password
                then throwM $ BadRequest "email, firstName, and password are required"
                else do
                    pid <- liftIO $ createPerson db email firstName lastName password isSuperadmin
                    liftIO $ writeAuditLog db (personId admin) "USER_CREATED" (Just "person") (Just $ UUID.toText pid) Nothing
                    pure $ object ["id" .= pid, "status" .= ("SUCCESS" :: Text)]
createUserH _ _ = throwM $ BadRequest "Invalid request body"

getUserH :: UUID -> Maybe Text -> Flow Value
getUserH userId mAuth = do
    mAdmin <- requireAdmin mAuth
    case mAdmin of
        Nothing -> throwM $ PermissionDenied "Superadmin required"
        Just _ -> do
            db <- getDBEnv
            mPerson <- liftIO $ findPersonDetailById db userId
            case mPerson of
                Nothing -> throwM $ NotFound "User not found"
                Just pd -> do
                    mAuth' <- liftIO $ findPersonById db userId
                    products <- case mAuth' of
                        Nothing -> pure []
                        Just person -> liftIO $ findAllProductsForPerson db person
                    overrides <- liftIO $ listOverridesForPerson db userId
                    pure $
                        object
                            [ "user" .= personDetailToJson pd
                            , "products"
                                .= map
                                    ( \PersonProductPerms{..} ->
                                        object
                                            [ "slug" .= pppProductSlug
                                            , "role" .= pppRoleName
                                            , "permissions" .= pppPermissions
                                            ]
                                    )
                                    products
                            , "overrides" .= map overrideToJson overrides
                            ]

updateUserH :: UUID -> Maybe Text -> Value -> Flow APIResponse
updateUserH userId mAuth (Object obj) = do
    mAdmin <- requireAdmin mAuth
    case mAdmin of
        Nothing -> throwM $ PermissionDenied "Superadmin required"
        Just _ -> do
            db <- getDBEnv
            liftIO $
                updatePerson
                    db
                    userId
                    (getStrM "firstName" obj)
                    (getStrM "lastName" obj)
                    (getBoolM "isActive" obj)
                    (getBoolM "isSuperadmin" obj)
            pure $ APIResponse "SUCCESS" "User updated"
updateUserH _ _ _ = throwM $ BadRequest "Invalid request body"

deleteUserH :: UUID -> Maybe Text -> Flow APIResponse
deleteUserH userId mAuth = do
    mAdmin <- requireAdmin mAuth
    case mAdmin of
        Nothing -> throwM $ PermissionDenied "Superadmin required"
        Just admin -> do
            db <- getDBEnv
            liftIO $ deactivatePerson db userId
            liftIO $ writeAuditLog db (personId admin) "USER_DEACTIVATED" (Just "person") (Just $ UUID.toText userId) Nothing
            pure $ APIResponse "SUCCESS" "User deactivated"

assignRoleH :: UUID -> Maybe Text -> Value -> Flow APIResponse
assignRoleH userId mAuth (Object obj) = do
    mAdmin <- requireAdmin mAuth
    case mAdmin of
        Nothing -> throwM $ PermissionDenied "Superadmin required"
        Just admin -> do
            db <- getDBEnv
            let productSlug = getStr "productSlug" obj
                mRoleId = getUuidM "roleId" obj
            case mRoleId of
                Nothing -> throwM $ BadRequest "roleId is required"
                Just roleId -> do
                    liftIO $ assignRole db userId productSlug roleId (Just (personId admin))
                    liftIO $ writeAuditLog db (personId admin) "ROLE_ASSIGNED" (Just "person_product_access") (Just $ UUID.toText userId) Nothing
                    pure $ APIResponse "SUCCESS" "Role assigned"
assignRoleH _ _ _ = throwM $ BadRequest "Invalid request body"

revokeAccessH :: UUID -> Text -> Maybe Text -> Flow APIResponse
revokeAccessH userId productSlug mAuth = do
    mAdmin <- requireAdmin mAuth
    case mAdmin of
        Nothing -> throwM $ PermissionDenied "Superadmin required"
        Just admin -> do
            db <- getDBEnv
            liftIO $ revokeProductAccess db userId productSlug
            liftIO $ writeAuditLog db (personId admin) "ACCESS_REVOKED" (Just "person_product_access") (Just $ UUID.toText userId) Nothing
            pure $ APIResponse "SUCCESS" "Product access revoked"

addOverrideH :: UUID -> Maybe Text -> Value -> Flow Value
addOverrideH userId mAuth (Object obj) = do
    mAdmin <- requireAdmin mAuth
    case mAdmin of
        Nothing -> throwM $ PermissionDenied "Superadmin required"
        Just admin -> do
            db <- getDBEnv
            let productSlug = getStr "productSlug" obj
                permAction = getStr "permissionAction" obj
                overrideType = getStr "overrideType" obj
            if T.null productSlug || T.null permAction || T.null overrideType
                then throwM $ BadRequest "productSlug, permissionAction, and overrideType are required"
                else
                    if overrideType /= "GRANT" && overrideType /= "DENY"
                        then throwM $ BadRequest "overrideType must be GRANT or DENY"
                        else do
                            -- Validate permission against ADT (no DB lookup needed)
                            let validPerms = allPermissionsText productSlug
                            if permAction `notElem` validPerms
                                then throwM $ BadRequest ("Invalid permission for product: " <> permAction)
                                else do
                                    oid <- liftIO $ addPermissionOverride db userId productSlug permAction overrideType (Just (personId admin))
                                    pure $ object ["id" .= oid, "status" .= ("SUCCESS" :: Text)]
addOverrideH _ _ _ = throwM $ BadRequest "Invalid request body"

removeOverrideH :: UUID -> UUID -> Maybe Text -> Flow APIResponse
removeOverrideH _userId overrideId mAuth = do
    mAdmin <- requireAdmin mAuth
    case mAdmin of
        Nothing -> throwM $ PermissionDenied "Superadmin required"
        Just _ -> do
            db <- getDBEnv
            liftIO $ removePermissionOverride db overrideId
            pure $ APIResponse "SUCCESS" "Override removed"

listProductsH :: Maybe Text -> Flow Value
listProductsH mAuth = do
    mAdmin <- requireAdmin mAuth
    case mAdmin of
        Nothing -> throwM $ PermissionDenied "Superadmin required"
        Just _ -> do
            -- Products are derived from ProductSlug ADT — no DB query needed
            let prods =
                    map
                        ( \slug ->
                            object
                                [ "slug" .= productSlugToText slug
                                , "name" .= productSlugToText slug
                                ]
                        )
                        [minBound .. maxBound :: ProductSlug]
            pure $ object ["products" .= prods]

createProductH :: Maybe Text -> Value -> Flow Value
createProductH _ _ = do
    -- Products are defined as Haskell ADTs — they cannot be created via API.
    -- To add a new product, add it to ProductSlug in Products/Types.hs
    throwM $ BadRequest "Products are defined in code, not via API"

listRolesH :: Text -> Maybe Text -> Flow Value
listRolesH slug mAuth = do
    mAdmin <- requireAdmin mAuth
    case mAdmin of
        Nothing -> throwM $ PermissionDenied "Superadmin required"
        Just _ -> do
            db <- getDBEnv
            roles <- liftIO $ listRolesForProduct db slug
            pure $ object ["roles" .= map roleToJson roles]

createRoleH :: Text -> Maybe Text -> Value -> Flow Value
createRoleH slug mAuth (Object obj) = do
    mAdmin <- requireAdmin mAuth
    case mAdmin of
        Nothing -> throwM $ PermissionDenied "Superadmin required"
        Just _ -> do
            db <- getDBEnv
            let name = getStr "name" obj
                desc = getStrM "description" obj
                permActions = getStrListM "permissions" obj
            if T.null name
                then throwM $ BadRequest "name is required"
                else do
                    roleId <- liftIO $ createRole db slug name desc permActions
                    pure $ object ["id" .= roleId, "status" .= ("SUCCESS" :: Text)]
createRoleH _ _ _ = throwM $ BadRequest "Invalid request body"

updateRoleH :: Text -> UUID -> Maybe Text -> Value -> Flow APIResponse
updateRoleH _slug roleId mAuth (Object obj) = do
    mAdmin <- requireAdmin mAuth
    case mAdmin of
        Nothing -> throwM $ PermissionDenied "Superadmin required"
        Just _ -> do
            db <- getDBEnv
            let desc = getStrM "description" obj
                permActions = getStrListM "permissions" obj
            liftIO $ updateRolePermissions db roleId desc permActions
            pure $ APIResponse "SUCCESS" "Role updated"
updateRoleH _ _ _ _ = throwM $ BadRequest "Invalid request body"

listPermissionsH :: Text -> Maybe Text -> Flow Value
listPermissionsH slug mAuth = do
    mAdmin <- requireAdmin mAuth
    case mAdmin of
        Nothing -> throwM $ PermissionDenied "Superadmin required"
        Just _ -> do
            -- Permissions are derived from ADTs — no DB query needed
            let perms = allPermissionsText slug
            pure $ object ["permissions" .= map (\p -> object ["action" .= p]) perms]

-- ── JSON serializers ────────────────────────────────────────────────

personDetailToJson :: PersonDetail -> Value
personDetailToJson PersonDetail{..} =
    object
        [ "id" .= pdId
        , "email" .= pdEmail
        , "firstName" .= pdFirstName
        , "lastName" .= pdLastName
        , "isActive" .= pdIsActive
        , "isSuperadmin" .= pdIsSuperadmin
        , "createdAt" .= pdCreatedAt
        ]

roleToJson :: RoleDetail -> Value
roleToJson RoleDetail{..} =
    object
        [ "id" .= rdId
        , "name" .= rdName
        , "description" .= rdDescription
        , "isSystemRole" .= rdIsSystemRole
        , "permissions" .= rdPermissions
        ]

overrideToJson :: OverrideDetail -> Value
overrideToJson OverrideDetail{..} =
    object
        [ "id" .= odId
        , "permissionAction" .= odPermissionAction
        , "overrideType" .= odOverrideType
        , "productSlug" .= odProductSlug
        ]
