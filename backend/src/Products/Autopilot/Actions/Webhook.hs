{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}

{- | CRUD for outbound release webhooks, plus a placeholder reference and a
"send test" action.

Every route — reads included — is pinned to the app group it touches under
'AP_PRODUCT_CONFIG_EDIT'. Stricter than the sibling config endpoints on
purpose: a header value can be a bearer token.
-}
module Products.Autopilot.Actions.Webhook (
    listWebhooksH,
    createWebhookH,
    updateWebhookH,
    deleteWebhookH,
    testWebhookH,
    listPlaceholdersH,
)
where

import Control.Monad.Catch (throwM)
import Control.Monad.IO.Class (liftIO)
import Core.AppError (APIError (..))
import Core.Auth.Protected (AuthedPerson (..), KnownPermission (..), requireDeploymentPermission)
import Core.Auth.Queries (computeEffectivePermissionsForAppGroups)
import Core.Environment (Flow)
import Data.List (nub)
import Data.Maybe (fromMaybe)
import Data.Proxy (Proxy (..))
import Data.Text (Text)
import Data.Text qualified as T
import GHC.Int (Int32)
import Products.Autopilot.Queries.ReleaseWebhook
import Products.Autopilot.Types.Permission (AutopilotPermission (..))
import Products.Autopilot.Types.Webhook
import Products.Autopilot.Webhooks (fireWebhook)
import Shared.API.Response (APIResponse (..))

editPerm :: Proxy 'AP_PRODUCT_CONFIG_EDIT
editPerm = Proxy

-- | Reference list for the "available placeholders" section of the config UI.
listPlaceholdersH :: AuthedPerson -> Flow [PlaceholderDef]
listPlaceholdersH _ap = pure availablePlaceholders

listWebhooksH :: AuthedPerson -> Maybe Text -> Flow [ReleaseWebhook]
listWebhooksH ap mAppGroup = do
    hooks <- listWebhooks (normalizeOptional mAppGroup)
    filterVisible ap hooks

createWebhookH :: AuthedPerson -> UpsertWebhookReq -> Flow APIResponse
createWebhookH ap rawReq = do
    let req = normalizeReq rawReq
    meth <- validate req
    requireDeploymentPermission editPerm ap (uwAppGroup req)
    requireNameFree (uwAppGroup req) (uwName req) Nothing
    insertWebhook req meth
    pure $ APIResponse "SUCCESS" ("Webhook created: " <> uwName req)

updateWebhookH :: AuthedPerson -> Int32 -> UpsertWebhookReq -> Flow APIResponse
updateWebhookH ap wid rawReq = do
    let req = normalizeReq rawReq
    meth <- validate req
    existing <- findWebhookById wid
    case existing of
        Nothing -> throwM $ NotFound "Webhook not found"
        Just wh
            -- Re-pointing a webhook at another app group would move it outside
            -- the scope the caller was authorised against; reject instead.
            | whAppGroup wh /= uwAppGroup req ->
                throwM $
                    BadRequest
                        ( "Webhook "
                            <> T.pack (show wid)
                            <> " belongs to app group "
                            <> whAppGroup wh
                            <> ", not "
                            <> uwAppGroup req
                        )
            | otherwise -> do
                requireDeploymentPermission editPerm ap (whAppGroup wh)
                requireNameFree (whAppGroup wh) (uwName req) (Just wid)
                updateWebhook wid req meth
                pure $ APIResponse "SUCCESS" ("Webhook updated: " <> uwName req)

deleteWebhookH :: AuthedPerson -> Int32 -> Flow APIResponse
deleteWebhookH ap wid = do
    existing <- findWebhookById wid
    case existing of
        Nothing -> throwM $ NotFound "Webhook not found"
        Just wh -> do
            requireDeploymentPermission editPerm ap (whAppGroup wh)
            deleteWebhook wid
            pure $ APIResponse "SUCCESS" ("Webhook deleted: " <> whName wh)

-- | Fire the stored webhook once with the sample placeholder values.
testWebhookH :: AuthedPerson -> Int32 -> Flow WebhookTestResult
testWebhookH ap wid = do
    existing <- findWebhookById wid
    case existing of
        Nothing -> throwM $ NotFound "Webhook not found"
        Just wh -> do
            requireDeploymentPermission editPerm ap (whAppGroup wh)
            liftIO $ fireWebhook samplePlaceholderEnv wh

-- Authorisation

-- | The route's 'Protected' gate only proves the permission is held
-- /somewhere/, so scope the result set to the groups the caller can edit.
filterVisible :: AuthedPerson -> [ReleaseWebhook] -> Flow [ReleaseWebhook]
filterVisible ap hooks
    | apIsSuperadmin ap = pure hooks
    | otherwise = do
        perms <- computeEffectivePermissionsForAppGroups (apPersonId ap) (permissionProduct editPerm) groups
        pure [wh | wh <- hooks, permissionName editPerm `elem` fromMaybe [] (lookup (whAppGroup wh) perms)]
  where
    groups = nub (map whAppGroup hooks)

-- | Turn the common 'uq_release_webhook' collision into a 400. Racing writers
-- can still hit the constraint itself.
requireNameFree :: Text -> Text -> Maybe Int32 -> Flow ()
requireNameFree grp name mSelf = do
    existing <- findWebhookByName grp name
    case existing of
        Just wh
            | Just (whId wh) /= mSelf ->
                throwM $ BadRequest ("A webhook named \"" <> name <> "\" already exists in " <> grp)
        _ -> pure ()

-- Validation / normalisation

-- | Runs on the normalised payload, so what is checked is what gets stored.
-- Returns the parsed method so the caller does not re-parse it.
validate :: UpsertWebhookReq -> Flow WebhookMethod
validate req
    | T.null (uwAppGroup req) = bad "appGroup is required"
    | T.null (uwName req) = bad "name is required"
    | T.null (uwUrl req) = bad "url is required"
    | not (isHttpUrl (uwUrl req)) = bad "url must start with http:// or https://"
    | any (T.null . kvKey) (fromMaybe [] (uwHeaders req)) = bad "header names cannot be blank"
    | any (T.null . kvKey) (fromMaybe [] (uwQueryParams req)) = bad "query param names cannot be blank"
    | Just t <- uwTimeoutSeconds req, t < 1 || t > 120 = bad "timeoutSeconds must be between 1 and 120"
    | Just r <- uwRetries req, r < 0 || r > 5 = bad "retries must be between 0 and 5"
    | otherwise = case textToWebhookMethod (uwMethod req) of
        Just m -> pure m
        Nothing -> bad ("Unsupported method: " <> uwMethod req <> " (GET, POST, PUT, PATCH, DELETE)")
  where
    bad = throwM . BadRequest

-- | A placeholder may sit anywhere but the scheme — that has to be literal.
isHttpUrl :: Text -> Bool
isHttpUrl u = let s = T.toLower u in "http://" `T.isPrefixOf` s || "https://" `T.isPrefixOf` s

-- | Trim the free-text fields and clean the service set. An empty service list
-- is the "whole app group" encoding, so @[""]@ and @[]@ both mean "all".
normalizeReq :: UpsertWebhookReq -> UpsertWebhookReq
normalizeReq req =
    req
        { uwAppGroup = T.strip (uwAppGroup req)
        , uwName = T.strip (uwName req)
        , uwUrl = T.strip (uwUrl req)
        , uwServices = Just (normalizeServices (fromMaybe [] (uwServices req)))
        , uwHeaders = fmap (map trimKey) (uwHeaders req)
        , uwQueryParams = fmap (map trimKey) (uwQueryParams req)
        }
  where
    trimKey kv = kv{kvKey = T.strip (kvKey kv)}

normalizeServices :: [Text] -> [Text]
normalizeServices = nub . filter (not . T.null) . map T.strip

normalizeOptional :: Maybe Text -> Maybe Text
normalizeOptional m = case T.strip <$> m of
    Just t | not (T.null t) -> Just t
    _ -> Nothing
