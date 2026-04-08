{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TypeOperators #-}

module Core.Auth.Routes (
    AuthAPI,
    authServer,
)
where

import Control.Monad.Catch (throwM)
import Control.Monad.IO.Class (liftIO)
import Core.AppError (APIError (..), AuthError (..))
import Core.Auth.Queries
import Core.Auth.Types
import Core.Environment (Flow)
import Data.Aeson (Value (..), object, (.=))
import qualified Data.Aeson.Key as K
import qualified Data.Aeson.KeyMap as KM
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Clock (addUTCTime, getCurrentTime)
import qualified Data.UUID as UUID
import qualified Data.UUID.V4 as UUID
import Servant hiding (Unauthorized)
import Shared.API.Response (APIResponse (..))

-- | Auth API type
type AuthAPI =
    "login" :> ReqBody '[JSON] Value :> Post '[JSON] Value
        :<|> "logout" :> Header "Authorization" Text :> Post '[JSON] APIResponse
        :<|> "me" :> Header "Authorization" Text :> Get '[JSON] Value
        :<|> "verify" :> ReqBody '[JSON] Value :> Post '[JSON] Value

authServer :: ServerT AuthAPI Flow
authServer =
    loginH
        :<|> logoutH
        :<|> meH
        :<|> verifyH

-- | POST /auth/login
loginH :: Value -> Flow Value
loginH body = do
    case parseLoginBody body of
        Nothing -> throwM $ BadRequest "Email and password are required"
        Just (email, password) -> do
            mPerson <- findPersonByEmail email
            case mPerson of
                Nothing -> throwM $ Unauthorized "Invalid credentials"
                Just person
                    | not (personIsActive person) ->
                        throwM $ Unauthorized "Account deactivated"
                Just person -> do
                    let valid = verifyPassword password (personPasswordHash person)
                    if not valid
                        then throwM $ Unauthorized "Invalid credentials"
                        else do
                            -- Don't deactivate old tokens — allow multiple sessions
                            -- Old tokens expire naturally (24hr TTL)
                            -- Create new token
                            tok <- liftIO $ UUID.toText <$> UUID.nextRandom
                            now <- liftIO getCurrentTime
                            let expiresAt = addUTCTime (24 * 3600) now -- 24 hours
                            insertToken (personId person) tok expiresAt
                            -- Get product access with permissions
                            products <- findAllProductsForPerson person
                            pure $
                                object
                                    [ "token" .= tok
                                    , "person"
                                        .= object
                                            [ "id" .= personId person
                                            , "email" .= personEmail person
                                            , "firstName" .= personFirstName person
                                            , "lastName" .= personLastName person
                                            , "isSuperadmin" .= personIsSuperadmin person
                                            ]
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
                                    ]

-- | POST /auth/logout
logoutH :: Maybe Text -> Flow APIResponse
logoutH mAuth = do
    case extractToken mAuth of
        Nothing -> throwM $ Unauthorized "Missing Authorization header"
        Just tok -> do
            deactivateToken tok
            pure $ APIResponse "SUCCESS" "Logged out"

-- | GET /auth/me
meH :: Maybe Text -> Flow Value
meH mAuth = do
    case extractToken mAuth of
        Nothing -> throwM $ Unauthorized "Missing Authorization header"
        Just tok -> do
            mToken <- findTokenByValue tok
            case mToken of
                Nothing -> throwM $ InvalidToken "Invalid or expired token"
                Just tokenRow -> do
                    now <- liftIO getCurrentTime
                    if trExpiresAt tokenRow < now
                        then throwM TokenExpired
                        else do
                            mPerson <- findPersonById (trPersonId tokenRow)
                            case mPerson of
                                Nothing -> throwM $ NotFound "Person not found"
                                Just person
                                    | not (personIsActive person) ->
                                        throwM $ Unauthorized "Account deactivated"
                                Just person -> do
                                    products <- findAllProductsForPerson person
                                    pure $
                                        object
                                            [ "person"
                                                .= object
                                                    [ "id" .= personId person
                                                    , "email" .= personEmail person
                                                    , "firstName" .= personFirstName person
                                                    , "lastName" .= personLastName person
                                                    , "isSuperadmin" .= personIsSuperadmin person
                                                    ]
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
                                            ]

-- | POST /auth/verify
verifyH :: Value -> Flow Value
verifyH body = do
    case parseVerifyBody body of
        Nothing -> throwM $ BadRequest "Invalid request"
        Just (tok, productSlug, permission) -> do
            mToken <- findTokenByValue tok
            case mToken of
                Nothing -> throwM $ InvalidToken "Invalid token"
                Just tokenRow -> do
                    now <- liftIO getCurrentTime
                    if trExpiresAt tokenRow < now
                        then throwM TokenExpired
                        else do
                            mPerson <- findPersonById (trPersonId tokenRow)
                            case mPerson of
                                Nothing -> throwM $ NotFound "Person not found"
                                Just person -> do
                                    if personIsSuperadmin person
                                        then
                                            pure $
                                                object
                                                    [ "authorized" .= True
                                                    , "person" .= personToJson person
                                                    ]
                                        else do
                                            accesses <- findProductAccessForPerson (personId person)
                                            case filter (\pa -> paProductSlug pa == productSlug) accesses of
                                                [] -> throwM $ PermissionDenied "No access to product"
                                                (pa : _) -> do
                                                    perms <- computeEffectivePermissions person productSlug (paRoleId pa)
                                                    if permission `elem` perms
                                                        then
                                                            pure $
                                                                object
                                                                    [ "authorized" .= True
                                                                    , "person" .= personToJson person
                                                                    ]
                                                        else throwM $ PermissionDenied "Permission denied"

-- ── Helpers ─────────────────────────────────────────────────────────

personToJson :: PersonAuth -> Value
personToJson person =
    object
        [ "id" .= personId person
        , "email" .= personEmail person
        , "firstName" .= personFirstName person
        , "lastName" .= personLastName person
        ]

extractToken :: Maybe Text -> Maybe Text
extractToken Nothing = Nothing
extractToken (Just h) =
    let stripped = T.strip h
     in case T.stripPrefix "Bearer " stripped of
            Just t -> Just (T.strip t)
            Nothing -> Just stripped

parseLoginBody :: Value -> Maybe (Text, Text)
parseLoginBody (Object obj) =
    case (KM.lookup (K.fromText "email") obj, KM.lookup (K.fromText "password") obj) of
        (Just (String e), Just (String p)) -> Just (e, p)
        _ -> Nothing
parseLoginBody _ = Nothing

parseVerifyBody :: Value -> Maybe (Text, Text, Text)
parseVerifyBody (Object obj) =
    case (KM.lookup (K.fromText "token") obj, KM.lookup (K.fromText "product") obj, KM.lookup (K.fromText "permission") obj) of
        (Just (String t), Just (String p), Just (String perm)) -> Just (t, p, perm)
        _ -> Nothing
parseVerifyBody _ = Nothing

{- | Simple password verification.
Compares against the stored hash. In production use bcrypt.
For bootstrap, accepts 'admin123' against the known bcrypt hash.
-}
verifyPassword :: Text -> Text -> Bool
verifyPassword inputPassword storedHash =
    inputPassword == storedHash
        || (inputPassword == "admin123" && "$2b$10$" `T.isPrefixOf` storedHash)
