{-# LANGUAGE OverloadedStrings #-}

{- | Client for the Multi-Cloud DB Manager's query-request API, so a release's SQL migrations become ONE
approval request there instead of statements pasted into a thread.

The DB Manager has session-cookie auth only, so the bot logs in as its own (low-privilege) account
(@POST /api/auth/login@, cookie @connect.sid@) and then @POST /api/query-requests@ (a request is a list
of 1–25 queries, each with its own database / cloud mode, under one written reason). The request runs
only when a human whose role permits it approves it there; the bot never executes SQL.

Config (env secrets, never the DB): @SC_DBM_URL@ (internal service URL, e.g.
@http://dual-db-backend.atlas.svc.cluster.local:3000@), @SC_DBM_USER@, @SC_DBM_PASSWORD@, and
@SC_DBM_WEB_URL@ (the UI host people open; the link is @<web>/?request=<groupId>@).
-}
module Products.Autopilot.ReleaseBot.DbManager (
    DbmItem (..),
    dbmConfigured,
    submitRequest,
) where

import Control.Monad.IO.Class (MonadIO, liftIO)
import Core.Http.Client (HttpError (..), HttpReq (..), HttpResponse (..), Method (..), defaultReq, httpRaw)
import Core.Secrets (lookupEnvSecret)
import Core.Types.Time (Seconds (..))
import Data.Aeson (Value (..), eitherDecodeStrict, encode, object, (.=))
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString.Lazy as LBS
import Data.Maybe (isJust)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE

data DbmItem = DbmItem
    { diQuery :: Text
    , diDatabase :: Text
    , diMode :: Text
    , diPgSchema :: Maybe Text
    }
    deriving (Show, Eq)

dbmConfigured :: (MonadIO m) => m Bool
dbmConfigured = do
    u <- lookupEnvSecret "SC_DBM_URL"
    n <- lookupEnvSecret "SC_DBM_USER"
    p <- lookupEnvSecret "SC_DBM_PASSWORD"
    pure (isJust u && isJust n && isJust p)

-- | Create one request holding every item. @Right link@ (or the group id when no web URL is set).
submitRequest :: (MonadIO m) => Text -> [DbmItem] -> m (Either Text Text)
submitRequest reason items = do
    mUrl <- lookupEnvSecret "SC_DBM_URL"
    mUser <- lookupEnvSecret "SC_DBM_USER"
    mPass <- lookupEnvSecret "SC_DBM_PASSWORD"
    mWeb <- lookupEnvSecret "SC_DBM_WEB_URL"
    case (mUrl, mUser, mPass) of
        (Just base0, Just user, Just pass) -> do
            let base = T.dropWhileEnd (== '/') base0
            ck <- login base user pass
            case ck of
                Left e -> pure (Left e)
                Right cookie -> do
                    let body = encode (object ["reason" .= T.take 1000 reason, "items" .= map itemJson items])
                        req =
                            (defaultReq (base <> "/api/query-requests"))
                                { reqMethod = POST
                                , reqHeaders = [("Content-Type", "application/json"), ("Cookie", cookie), ("X-Forwarded-Proto", "https")]
                                , reqBody = Just body
                                , reqTimeout = Seconds 30
                                , -- a retry could file the request twice
                                  reqRetries = 0
                                , reqLogTag = "dbm-create-request"
                                }
                    r <- liftIO (httpRaw req)
                    pure $ case r of
                        Left e -> Left (render e)
                        Right resp
                            | respStatus resp `elem` [200, 201] -> case groupIdOf (respBody resp) of
                                Just gid -> Right (maybe gid (\w -> T.dropWhileEnd (== '/') w <> "/?request=" <> gid) mWeb)
                                Nothing -> Left "DB Manager accepted the request but returned no group id"
                            | otherwise -> Left ("DB Manager HTTP " <> T.pack (show (respStatus resp)) <> ": " <> T.take 300 (TE.decodeUtf8With (\_ _ -> Just '?') (LBS.toStrict (respBody resp))))
        _ -> pure (Left "SC_DBM_URL / SC_DBM_USER / SC_DBM_PASSWORD are not all set on the backend")
  where
    itemJson i =
        object $
            ["query" .= diQuery i, "database" .= diDatabase i, "mode" .= diMode i]
                ++ maybe [] (\s -> ["pgSchema" .= s]) (diPgSchema i)

login :: (MonadIO m) => Text -> Text -> Text -> m (Either Text Text)
login base user pass = do
    let req =
            (defaultReq (base <> "/api/auth/login"))
                { reqMethod = POST
                , reqHeaders = [("Content-Type", "application/json"), ("X-Forwarded-Proto", "https")]
                , reqBody = Just (encode (object ["username" .= user, "password" .= pass]))
                , reqTimeout = Seconds 20
                , reqRetries = 0
                , reqLogTag = "dbm-login"
                }
    r <- liftIO (httpRaw req)
    pure $ case r of
        Left e -> Left (render e)
        Right resp
            | respStatus resp /= 200 -> Left ("DB Manager login failed: HTTP " <> T.pack (show (respStatus resp)))
            | otherwise -> case [T.strip (T.takeWhile (/= ';') v) | (n, v) <- respHeaders resp, T.toLower n == "set-cookie", "connect.sid=" `T.isPrefixOf` T.strip v] of
                (c : _) -> Right c
                [] -> Left "DB Manager login returned no session cookie"

groupIdOf :: LBS.ByteString -> Maybe Text
groupIdOf b = case eitherDecodeStrict (LBS.toStrict b) of
    Right (Object o) -> firstString [KM.lookup "groupId" o, KM.lookup "group_id" o, KM.lookup "id" o]
    _ -> Nothing
  where
    firstString xs = case [t | Just (String t) <- xs] of (t : _) -> Just t; [] -> Nothing

render :: HttpError -> Text
render (HttpExceptionError m) = m
render e = T.pack (show e)
