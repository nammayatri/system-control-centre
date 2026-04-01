{-# LANGUAGE OverloadedStrings #-}

module Shared.Error
    ( APIError(..)
    , throwAPIError
    , toAPIResponse
    ) where

import Data.Aeson (ToJSON(..), Value, object, (.=))
import Data.Text (Text)
import Servant (ServerError(..), err400, err404, err403, err409)
import Data.Aeson (encode)

data APIError
    = NotFound Text           -- 404
    | BadRequest Text         -- 400
    | Forbidden Text          -- 403
    | Conflict Text           -- 409
    | InvalidTransition Text  -- 422
    | InternalError Text      -- 500
    deriving (Show)

instance ToJSON APIError where
    toJSON err = object
        [ "status" .= ("ERROR" :: Text)
        , "message" .= errorMessage err
        , "code" .= errorCode err
        ]

errorMessage :: APIError -> Text
errorMessage (NotFound msg) = msg
errorMessage (BadRequest msg) = msg
errorMessage (Forbidden msg) = msg
errorMessage (Conflict msg) = msg
errorMessage (InvalidTransition msg) = msg
errorMessage (InternalError msg) = msg

errorCode :: APIError -> Text
errorCode (NotFound _) = "NOT_FOUND"
errorCode (BadRequest _) = "BAD_REQUEST"
errorCode (Forbidden _) = "FORBIDDEN"
errorCode (Conflict _) = "CONFLICT"
errorCode (InvalidTransition _) = "INVALID_TRANSITION"
errorCode (InternalError _) = "INTERNAL_ERROR"

-- Convert APIError to Servant ServerError with JSON body
throwAPIError :: APIError -> ServerError
throwAPIError err@(NotFound _) = (err404 :: ServerError) { errBody = encode err, errHeaders = [("Content-Type", "application/json")] }
throwAPIError err@(BadRequest _) = (err400 :: ServerError) { errBody = encode err, errHeaders = [("Content-Type", "application/json")] }
throwAPIError err@(Forbidden _) = (err403 :: ServerError) { errBody = encode err, errHeaders = [("Content-Type", "application/json")] }
throwAPIError err@(Conflict _) = (err409 :: ServerError) { errBody = encode err, errHeaders = [("Content-Type", "application/json")] }
throwAPIError err@(InvalidTransition _) = let e = ServerError 422 "Unprocessable Entity" (encode err) [("Content-Type", "application/json")] in e
throwAPIError err@(InternalError _) = let e = ServerError 500 "Internal Server Error" (encode err) [("Content-Type", "application/json")] in e

-- Helper to convert to the old APIResponse format (for backward compatibility)
toAPIResponse :: Text -> Text -> Value
toAPIResponse status msg = object ["status" .= status, "message" .= msg]
