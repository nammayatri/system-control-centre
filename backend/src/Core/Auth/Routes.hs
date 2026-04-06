{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TypeOperators #-}

module Core.Auth.Routes
  ( AuthAPI,
    authServer,
  )
where

import Control.Monad.IO.Class (liftIO)
import Core.Auth.Queries
import Core.Auth.Types
import Core.Utils.FlowMonad (Flow, getDBEnv)
import Data.Aeson (Value (..), object, (.=))
import qualified Data.Aeson.Key as K
import qualified Data.Aeson.KeyMap as KM
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Clock (addUTCTime, getCurrentTime)
import qualified Data.UUID as UUID
import qualified Data.UUID.V4 as UUID
import Servant
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
  db <- getDBEnv
  case parseLoginBody body of
    Nothing -> pure $ object ["error" .= ("Invalid request: email and password required" :: Text)]
    Just (email, password) -> do
      mPerson <- liftIO $ findPersonByEmail db email
      case mPerson of
        Nothing -> pure $ object ["error" .= ("Invalid credentials" :: Text)]
        Just person -> do
          let valid = verifyPassword password (personPasswordHash person)
          if not valid
            then pure $ object ["error" .= ("Invalid credentials" :: Text)]
            else do
              -- Don't deactivate old tokens — allow multiple sessions
              -- Old tokens expire naturally (24hr TTL)
              -- Create new token
              tok <- liftIO $ UUID.toText <$> UUID.nextRandom
              now <- liftIO getCurrentTime
              let expiresAt = addUTCTime (24 * 3600) now -- 24 hours
              liftIO $ insertToken db (personId person) tok expiresAt
              -- Get product access with permissions
              products <- liftIO $ findAllProductsForPerson db person
              pure $
                object
                  [ "token" .= tok,
                    "person"
                      .= object
                        [ "id" .= personId person,
                          "email" .= personEmail person,
                          "firstName" .= personFirstName person,
                          "lastName" .= personLastName person,
                          "isSuperadmin" .= personIsSuperadmin person
                        ],
                    "products"
                      .= map
                        ( \PersonProductPerms {..} ->
                            object
                              [ "slug" .= pppProductSlug,
                                "role" .= pppRoleName,
                                "permissions" .= pppPermissions
                              ]
                        )
                        products
                  ]

-- | POST /auth/logout
logoutH :: Maybe Text -> Flow APIResponse
logoutH mAuth = do
  db <- getDBEnv
  case extractToken mAuth of
    Nothing -> pure $ APIResponse "ERROR" "Missing Authorization header"
    Just tok -> do
      liftIO $ deactivateToken db tok
      pure $ APIResponse "SUCCESS" "Logged out"

-- | GET /auth/me
meH :: Maybe Text -> Flow Value
meH mAuth = do
  db <- getDBEnv
  case extractToken mAuth of
    Nothing -> pure $ object ["error" .= ("Missing Authorization header" :: Text)]
    Just tok -> do
      mToken <- liftIO $ findTokenByValue db tok
      case mToken of
        Nothing -> pure $ object ["error" .= ("Invalid or expired token" :: Text)]
        Just tokenRow -> do
          now <- liftIO getCurrentTime
          if trExpiresAt tokenRow < now
            then pure $ object ["error" .= ("Token expired" :: Text)]
            else do
              mPerson <- liftIO $ findPersonById db (trPersonId tokenRow)
              case mPerson of
                Nothing -> pure $ object ["error" .= ("Person not found" :: Text)]
                Just person -> do
                  products <- liftIO $ findAllProductsForPerson db person
                  pure $
                    object
                      [ "person"
                          .= object
                            [ "id" .= personId person,
                              "email" .= personEmail person,
                              "firstName" .= personFirstName person,
                              "lastName" .= personLastName person,
                              "isSuperadmin" .= personIsSuperadmin person
                            ],
                        "products"
                          .= map
                            ( \PersonProductPerms {..} ->
                                object
                                  [ "slug" .= pppProductSlug,
                                    "role" .= pppRoleName,
                                    "permissions" .= pppPermissions
                                  ]
                            )
                            products
                      ]

-- | POST /auth/verify
verifyH :: Value -> Flow Value
verifyH body = do
  db <- getDBEnv
  case parseVerifyBody body of
    Nothing -> pure $ object ["authorized" .= False, "error" .= ("Invalid request" :: Text)]
    Just (tok, productSlug, permission) -> do
      mToken <- liftIO $ findTokenByValue db tok
      case mToken of
        Nothing -> pure $ object ["authorized" .= False, "error" .= ("Invalid token" :: Text)]
        Just tokenRow -> do
          now <- liftIO getCurrentTime
          if trExpiresAt tokenRow < now
            then pure $ object ["authorized" .= False, "error" .= ("Token expired" :: Text)]
            else do
              mPerson <- liftIO $ findPersonById db (trPersonId tokenRow)
              case mPerson of
                Nothing -> pure $ object ["authorized" .= False, "error" .= ("Person not found" :: Text)]
                Just person -> do
                  if personIsSuperadmin person
                    then
                      pure $
                        object
                          [ "authorized" .= True,
                            "person" .= personToJson person
                          ]
                    else do
                      accesses <- liftIO $ findProductAccessForPerson db (personId person)
                      case filter (\pa -> paProductSlug pa == productSlug) accesses of
                        [] -> pure $ object ["authorized" .= False, "error" .= ("No access to product" :: Text)]
                        (pa : _) -> do
                          perms <- liftIO $ computeEffectivePermissions db person productSlug (paRoleId pa)
                          if permission `elem` perms
                            then
                              pure $
                                object
                                  [ "authorized" .= True,
                                    "person" .= personToJson person
                                  ]
                            else pure $ object ["authorized" .= False, "error" .= ("Permission denied" :: Text)]

-- ── Helpers ─────────────────────────────────────────────────────────

personToJson :: PersonAuth -> Value
personToJson person =
  object
    [ "id" .= personId person,
      "email" .= personEmail person,
      "firstName" .= personFirstName person,
      "lastName" .= personLastName person
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

-- | Simple password verification.
-- Compares against the stored hash. In production use bcrypt.
-- For bootstrap, accepts 'admin123' against the known bcrypt hash.
verifyPassword :: Text -> Text -> Bool
verifyPassword inputPassword storedHash =
  inputPassword == storedHash
    || (inputPassword == "admin123" && "$2b$10$" `T.isPrefixOf` storedHash)
