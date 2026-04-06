{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Typed exception hierarchy — NammaYatri-style error codes, messages,
-- and tags, but with a cleaner single-module design.
--
-- == Hierarchy
--
-- @
-- SomeException
--   └── AppException (our root — carries ToAppError constraint)
--         ├── APIError       — client-facing (400/403/404/409/422/500)
--         ├── AuthError      — authentication/authorization failures (401/403)
--         ├── DBError        — database failures (500)
--         └── WorkflowError  — release workflow failures (500)
-- @
--
-- == JSON response format (all errors)
--
-- @
-- {
--   "status": "ERROR",
--   "code": "NOT_FOUND",
--   "message": "Release r-123 not found",
--   "tag": "APIError"
-- }
-- @
module Core.AppError
  ( -- * Root exception
    AppException (..),

    -- * Conversion typeclass
    ToAppError (..),

    -- * API errors (client-facing)
    APIError (..),

    -- * Auth errors
    AuthError (..),

    -- * DB errors
    DBError (..),

    -- * Workflow errors
    WorkflowError (..),

    -- * Helpers
    fromMaybeM,
    fromEitherM,

    -- * Error JSON builders (for global handler)
    errorResponseJSON,
  )
where

import Control.Exception (Exception (..))
import Control.Monad.Catch (MonadThrow, throwM)
import Data.Aeson (ToJSON (..), encode, object, (.=))
import qualified Data.ByteString.Lazy as LBS
import Data.Text (Text)
import Data.Typeable (Typeable, cast)
import Network.HTTP.Types (Header)
import Servant (ServerError (..), err400, err401, err403, err404, err409, err500)

-- ── Structured error response ─────────────────────────────────────

-- | Build a structured JSON error body (used by all error types).
errorResponseJSON :: Text -> Text -> Text -> Text -> LBS.ByteString
errorResponseJSON status code message tag =
  encode $
    object
      [ "status" .= status,
        "code" .= code,
        "message" .= message,
        "tag" .= tag
      ]

jsonHeaders :: [Header]
jsonHeaders = [("Content-Type", "application/json")]

-- ── Root exception ────────────────────────────────────────────────

-- | Root of our exception hierarchy. The global error handler in
-- 'Core.Server.toHandler' catches this and calls 'toServantError'.
data AppException = forall e. (Exception e, ToAppError e) => AppException e

instance Show AppException where
  show (AppException e) = show e

instance Exception AppException

-- | Convert a domain exception to an HTTP error response.
-- Every error type in the hierarchy implements this.
class (Show e, Typeable e) => ToAppError e where
  toServantError :: e -> ServerError
  toErrorCode :: e -> Text
  toErrorTag :: e -> Text
  toErrorMessage :: e -> Text

-- ── APIError ──────────────────────────────────────────────────────

data APIError
  = NotFound Text
  | BadRequest Text
  | Forbidden Text
  | Conflict Text
  | InvalidTransition Text
  | InternalError Text
  deriving (Show, Typeable)

instance Exception APIError where
  toException = toException . AppException
  fromException x = do
    AppException e <- fromException x
    cast e

instance ToAppError APIError where
  toErrorTag _ = "APIError"

  toErrorCode (NotFound _) = "NOT_FOUND"
  toErrorCode (BadRequest _) = "BAD_REQUEST"
  toErrorCode (Forbidden _) = "FORBIDDEN"
  toErrorCode (Conflict _) = "CONFLICT"
  toErrorCode (InvalidTransition _) = "INVALID_TRANSITION"
  toErrorCode (InternalError _) = "INTERNAL_ERROR"

  toErrorMessage (NotFound msg) = msg
  toErrorMessage (BadRequest msg) = msg
  toErrorMessage (Forbidden msg) = msg
  toErrorMessage (Conflict msg) = msg
  toErrorMessage (InvalidTransition msg) = msg
  toErrorMessage (InternalError msg) = msg

  toServantError err =
    base
      { errBody = errorResponseJSON "ERROR" (toErrorCode err) (toErrorMessage err) (toErrorTag err),
        errHeaders = jsonHeaders
      }
    where
      base = case err of
        NotFound _ -> err404
        BadRequest _ -> err400
        Forbidden _ -> err403
        Conflict _ -> err409
        InvalidTransition _ -> ServerError 422 "Unprocessable Entity" "" []
        InternalError _ -> err500

instance ToJSON APIError where
  toJSON err =
    object
      [ "status" .= ("ERROR" :: Text),
        "code" .= toErrorCode err,
        "message" .= toErrorMessage err,
        "tag" .= toErrorTag err
      ]

-- ── AuthError ─────────────────────────────────────────────────────

data AuthError
  = Unauthorized Text
  | InvalidToken Text
  | TokenExpired
  | TokenNotFound
  | AccountDisabled Text
  | PermissionDenied Text
  deriving (Show, Typeable)

instance Exception AuthError where
  toException = toException . AppException
  fromException x = do
    AppException e <- fromException x
    cast e

instance ToAppError AuthError where
  toErrorTag _ = "AuthError"

  toErrorCode (Unauthorized _) = "UNAUTHORIZED"
  toErrorCode (InvalidToken _) = "INVALID_TOKEN"
  toErrorCode TokenExpired = "TOKEN_EXPIRED"
  toErrorCode TokenNotFound = "TOKEN_NOT_FOUND"
  toErrorCode (AccountDisabled _) = "ACCOUNT_DISABLED"
  toErrorCode (PermissionDenied _) = "PERMISSION_DENIED"

  toErrorMessage (Unauthorized msg) = msg
  toErrorMessage (InvalidToken msg) = "Invalid token: " <> msg
  toErrorMessage TokenExpired = "Token has expired"
  toErrorMessage TokenNotFound = "Token not found"
  toErrorMessage (AccountDisabled msg) = "Account disabled: " <> msg
  toErrorMessage (PermissionDenied msg) = "Permission denied: " <> msg

  toServantError err =
    base
      { errBody = errorResponseJSON "ERROR" (toErrorCode err) (toErrorMessage err) (toErrorTag err),
        errHeaders = jsonHeaders
      }
    where
      base = case err of
        Unauthorized _ -> err401
        InvalidToken _ -> err401
        TokenExpired -> err401
        TokenNotFound -> err401
        AccountDisabled _ -> err403
        PermissionDenied _ -> err403

-- ── DBError ───────────────────────────────────────────────────────

data DBError = DBError
  { dbErrorContext :: Text,
    dbErrorDetail :: Text
  }
  deriving (Show, Typeable)

instance Exception DBError where
  toException = toException . AppException
  fromException x = do
    AppException e <- fromException x
    cast e

instance ToAppError DBError where
  toErrorTag _ = "DBError"
  toErrorCode _ = "DB_ERROR"
  toErrorMessage (DBError ctx detail) = "Database error in " <> ctx <> ": " <> detail
  toServantError err =
    err500
      { errBody = errorResponseJSON "ERROR" (toErrorCode err) (toErrorMessage err) (toErrorTag err),
        errHeaders = jsonHeaders
      }

-- ── WorkflowError ─────────────────────────────────────────────────

data WorkflowError = WorkflowError
  { wfErrorStep :: Text,
    wfErrorDetail :: Text
  }
  deriving (Show, Typeable)

instance Exception WorkflowError where
  toException = toException . AppException
  fromException x = do
    AppException e <- fromException x
    cast e

instance ToAppError WorkflowError where
  toErrorTag _ = "WorkflowError"
  toErrorCode _ = "WORKFLOW_ERROR"
  toErrorMessage (WorkflowError step detail) = "Workflow failed at " <> step <> ": " <> detail
  toServantError err =
    err500
      { errBody = errorResponseJSON "ERROR" (toErrorCode err) (toErrorMessage err) (toErrorTag err),
        errHeaders = jsonHeaders
      }

-- ── Error helpers ─────────────────────────────────────────────────

-- | Extract from Maybe or throw typed error.
--
-- @
-- release <- fromMaybeM (NotFound "Release not found") mRelease
-- @
fromMaybeM :: (MonadThrow m, Exception e) => e -> Maybe a -> m a
fromMaybeM err = maybe (throwM err) pure

-- | Extract from Either or throw, mapping the Left value.
--
-- @
-- value <- fromEitherM (BadRequest . T.pack) parseResult
-- @
fromEitherM :: (MonadThrow m, Exception e) => (left -> e) -> Either left a -> m a
fromEitherM toErr = either (throwM . toErr) pure
