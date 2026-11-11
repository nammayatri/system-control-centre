{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}

module Products.Autopilot.ConfigPilot.Client
  ( ConfigPilotItem (..),
    ConfigPilotMeta (..),
    ConfigSide (..),
    parseConfigPilotMeta,
    upsertItemRollout,
    concludeItem,
    abortItem,
  )
where

import Control.Exception (SomeException, try)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Core.Config (Config (..))
import Core.Http.Client (HttpError, HttpReq (..), HttpResponse (..), Method (..), defaultReq, httpRaw)
import Core.Secrets (lookupEnvSecret)
import Core.Types.Time (Seconds (..))
import Data.Aeson (FromJSON, ToJSON, Value, object, (.=))
import Data.Aeson qualified as A
import Data.ByteString.Lazy qualified as LBS
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import GHC.Generics (Generic)
import Network.HTTP.Types.URI (urlEncode)
import Products.Autopilot.Types.Release (ReleaseTracker (..))
import Prelude

data ConfigSide = BAP | BPP
  deriving (Eq, Show, Generic)

instance ToJSON ConfigSide

instance FromJSON ConfigSide

data ConfigPilotItem = ConfigPilotItem
  { configType :: Text,
    version :: Int
  }
  deriving (Eq, Show, Generic)

instance ToJSON ConfigPilotItem

instance FromJSON ConfigPilotItem

data ConfigPilotMeta = ConfigPilotMeta
  { side :: ConfigSide,
    merchantShortId :: Text,
    city :: Text,
    items :: [ConfigPilotItem]
  }
  deriving (Eq, Show, Generic)

instance ToJSON ConfigPilotMeta

instance FromJSON ConfigPilotMeta

parseConfigPilotMeta :: ReleaseTracker -> Either Text ConfigPilotMeta
parseConfigPilotMeta rt = case metadata rt of
  Nothing -> Left "ConfigPilot release has no metadata"
  Just v -> case A.fromJSON v of
    A.Success m
      | null (items m) -> Left "ConfigPilot release has no items"
      | otherwise -> Right m
    A.Error e -> Left ("Invalid ConfigPilot metadata: " <> T.pack e)

baseUrlFor :: Config -> ConfigSide -> String
baseUrlFor cfg BAP = configPilotBapUrl cfg
baseUrlFor cfg BPP = configPilotBppUrl cfg

itemUrl :: Config -> ConfigPilotMeta -> ConfigPilotItem -> Text -> Text
itemUrl cfg meta item verb =
  let base = T.dropWhileEnd (== '/') (T.pack (baseUrlFor cfg (side meta)))
      prefix = case side meta of
        BPP -> "/driver-offer"
        BAP -> ""
   in base
        <> prefix
        <> "/"
        <> merchantShortId meta
        <> "/"
        <> city meta
        <> "/nammaTag/configPilot/"
        <> TE.decodeUtf8 (urlEncode False (TE.encodeUtf8 (configType item)))
        <> "/"
        <> verb

postDashboard :: (MonadIO m) => Config -> ConfigPilotMeta -> ConfigPilotItem -> Text -> Value -> m (Either Text ())
postDashboard cfg meta item verb body
  | null (baseUrlFor cfg (side meta)) = pure (Left "ConfigPilot dashboard URL is not configured")
  | otherwise = do
      mToken <- lookupEnvSecret "SC_CONFIGPILOT_TOKEN"
      case mToken of
        Nothing -> pure (Left "SC_CONFIGPILOT_TOKEN is not set")
        Just token -> liftIO $ do
          let req =
                (defaultReq (itemUrl cfg meta item verb))
                  { reqMethod = POST,
                    reqHeaders = [("Content-Type", "application/json"), ("token", token)],
                    reqBody = Just (A.encode body),
                    reqTimeout = Seconds 30,
                    reqRetries = 2,
                    reqLogTag = "configpilot"
                  }
          r <- try (httpRaw req) :: IO (Either SomeException (Either HttpError HttpResponse))
          pure $ case r of
            Right (Right HttpResponse {respStatus = s}) | s < 300 -> Right ()
            Right (Right HttpResponse {respStatus = s, respBody = b}) ->
              Left (verb <> " " <> configType item <> " HTTP " <> T.pack (show s) <> ": " <> T.take 300 (TE.decodeUtf8 (LBS.toStrict b)))
            Right (Left _) -> Left (verb <> " " <> configType item <> ": request failed")
            Left ex -> Left (verb <> " " <> configType item <> ": " <> T.pack (show ex))

upsertItemRollout :: (MonadIO m) => Config -> ConfigPilotMeta -> ConfigPilotItem -> Text -> Int -> m (Either Text ())
upsertItemRollout cfg meta item group pct =
  postDashboard cfg meta item "upsertLogicRollout" $
    A.toJSON
      [ object
          [ "timeBounds" .= ("Unbounded" :: Text),
            "rollout"
              .= [ object
                     [ "version" .= version item,
                       "rolloutPercentage" .= pct,
                       "versionDescription" .= ("" :: Text),
                       "experimentGroup" .= group
                     ]
                 ]
          ]
      ]

concludeItem :: (MonadIO m) => Config -> ConfigPilotMeta -> ConfigPilotItem -> m (Either Text ())
concludeItem cfg meta item =
  postDashboard cfg meta item "rolloutAction" $
    object ["tag" .= ("ConfigPilotConclude" :: Text), "contents" .= object ["version" .= version item]]

abortItem :: (MonadIO m) => Config -> ConfigPilotMeta -> ConfigPilotItem -> m (Either Text ())
abortItem cfg meta item =
  postDashboard cfg meta item "rolloutAction" $
    object ["tag" .= ("ConfigPilotAbort" :: Text), "contents" .= object ["version" .= version item]]
