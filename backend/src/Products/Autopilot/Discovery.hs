{-# LANGUAGE OverloadedStrings #-}

module Products.Autopilot.Discovery
  ( listServicesFromVirtualService,
  )
where

import Core.Config (Config)
import Data.Aeson (Value)
import qualified Data.Aeson as A
import qualified Data.Aeson.Key as K
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString.Lazy.Char8 as BL
import Data.Maybe (mapMaybe)
import Data.Text (Text)
import Data.Text.Encoding (encodeUtf8)
import Products.Autopilot.K8s.Kubectl (K8sError (..), getVirtualServiceJson)

listServicesFromVirtualService :: Config -> Text -> Text -> IO (Either Text [Text])
listServicesFromVirtualService cfg namespace vsName = do
  res <- getVirtualServiceJson cfg namespace vsName
  case res of
    Left (K8sError e) -> pure (Left e)
    Right out ->
      case A.decode (BL.fromStrict (encodeUtf8 out)) of
        Nothing -> pure (Left "Failed to decode VirtualService JSON")
        Just v -> pure (Right (extractHosts v))

extractHosts :: Value -> [Text]
extractHosts (A.Object root) =
  uniq $
    case lookupObject "spec" root >>= lookupArray "http" of
      Nothing -> []
      Just httpRules -> foldMap routeHosts httpRules
  where
    lookupObject key obj =
      case KM.lookup (K.fromText key) obj of
        Just (A.Object v) -> Just v
        _ -> Nothing
    lookupArray key obj =
      case KM.lookup (K.fromText key) obj of
        Just (A.Array v) -> Just v
        _ -> Nothing
    lookupText key obj =
      case KM.lookup (K.fromText key) obj of
        Just (A.String v) -> Just v
        _ -> Nothing
    routeHosts (A.Object httpRule) =
      case lookupArray "route" httpRule of
        Nothing -> []
        Just routes -> mapMaybe destinationHost (foldr (:) [] routes)
    routeHosts _ = []
    destinationHost (A.Object routeObj) = do
      destination <- lookupObject "destination" routeObj
      lookupText "host" destination
    destinationHost _ = Nothing
extractHosts _ = []

uniq :: [Text] -> [Text]
uniq = foldr (\x acc -> if x `elem` acc then acc else x : acc) []
