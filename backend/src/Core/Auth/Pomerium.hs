{-# LANGUAGE OverloadedStrings #-}

{- | Shared Pomerium identity resolution. The proxy sets @X-Forwarded-Email@
directly on some routes, but on others only the @x-pomerium-jwt-assertion@
JWT is present (no signature check here -- it's already been verified by
the Pomerium sidecar before reaching us, this just reads the email claim
back out of it).
-}
module Core.Auth.Pomerium (
    resolvePomeriumEmail,
    extractEmailFromJwt,
)
where

import Control.Applicative ((<|>))
import Data.Aeson qualified as A
import Data.Aeson.Key qualified as AK
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString.Base64 qualified as B64
import Data.ByteString.Lazy qualified as LBS
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE

{- | Resolve the caller's verified email from whichever of the two Pomerium
headers is present, preferring the plain header when both are set.
-}
resolvePomeriumEmail :: Maybe Text -> Maybe Text -> Maybe Text
resolvePomeriumEmail mXFE mJwt = nonEmpty mXFE <|> (mJwt >>= extractEmailFromJwt)

nonEmpty :: Maybe Text -> Maybe Text
nonEmpty (Just t) | not (T.null (T.strip t)) = Just (T.strip t)
nonEmpty _ = Nothing

extractEmailFromJwt :: Text -> Maybe Text
extractEmailFromJwt jwt =
    case T.splitOn "." jwt of
        (_ : payload : _) ->
            let decoded = B64.decodeLenient (TE.encodeUtf8 (padBase64 payload))
             in case A.decode (LBS.fromStrict decoded) of
                    Just (A.Object obj) ->
                        case KM.lookup (AK.fromText "email") obj of
                            Just (A.String e) | not (T.null (T.strip e)) -> Just (T.strip e)
                            _ -> Nothing
                    _ -> Nothing
        _ -> Nothing

padBase64 :: Text -> Text
padBase64 t =
    let m = T.length t `mod` 4
     in if m == 0 then t else t <> T.replicate (4 - m) "="
