{-# LANGUAGE ExistentialQuantification #-}

-- | Typed exception hierarchy for the application.
--
-- Every error is an @Exception@ — throwable anywhere, caught at the
-- Servant boundary by the global error handler in 'Core.Server'.
--
-- == Hierarchy
--
-- @
-- SomeException
--   └── AppException (our root)
--         ├── APIError       — client-facing errors (400/403/404/409/422/500)
--         ├── DBError        — database failures (connection, query, constraint)
--         └── WorkflowError  — release workflow failures
-- @
--
-- Handlers throw typed errors:
--
-- @
-- throwM $ NotFound "Release r-123 not found"
-- throwM $ DBError "Connection timeout"
-- @
--
-- The global handler catches 'AppException' and converts to structured
-- JSON. Anything else becomes a generic 500.
module Core.AppError
  ( -- * Root exception
    AppException (..),

    -- * Conversion typeclass
    ToAppError (..),

    -- * API errors (client-facing)
    APIError (..),
    apiErrorToServant,
    apiErrorCode,
    apiErrorMessage,

    -- * DB errors
    DBError (..),

    -- * Workflow errors
    WorkflowError (..),

    -- * Helpers
    fromMaybeM,
    fromEitherM,
  )
where

import Control.Exception (Exception (..), SomeException)
import Control.Monad.Catch (MonadThrow, throwM)
import Data.Aeson (ToJSON (..), encode, object, (.=))
import Data.Text (Text)
import qualified Data.Text as T
import Data.Typeable (Typeable, cast)
import Servant (ServerError (..), err400, err403, err404, err409, err500)

-- ── Root exception ────────────────────────────────────────────────

-- | Root of our exception hierarchy. The global error handler in
-- 'Core.Server.toHandler' catches this and converts to structured JSON.
data AppException = forall e. (Exception e, ToAppError e) => AppException e

instance Show AppException where
  show (AppException e) = show e

instance Exception AppException

-- | Typeclass to convert domain exceptions to HTTP error responses.
class (Show e, Typeable e) => ToAppError e where
  toServantError :: e -> ServerError

-- ── API errors ────────────────────────────────────────────────────

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
  toServantError = apiErrorToServant

instance ToJSON APIError where
  toJSON err =
    object
      [ "status" .= ("ERROR" :: Text),
        "message" .= apiErrorMessage err,
        "code" .= apiErrorCode err
      ]

apiErrorMessage :: APIError -> Text
apiErrorMessage (NotFound msg) = msg
apiErrorMessage (BadRequest msg) = msg
apiErrorMessage (Forbidden msg) = msg
apiErrorMessage (Conflict msg) = msg
apiErrorMessage (InvalidTransition msg) = msg
apiErrorMessage (InternalError msg) = msg

apiErrorCode :: APIError -> Text
apiErrorCode (NotFound _) = "NOT_FOUND"
apiErrorCode (BadRequest _) = "BAD_REQUEST"
apiErrorCode (Forbidden _) = "FORBIDDEN"
apiErrorCode (Conflict _) = "CONFLICT"
apiErrorCode (InvalidTransition _) = "INVALID_TRANSITION"
apiErrorCode (InternalError _) = "INTERNAL_ERROR"

apiErrorToServant :: APIError -> ServerError
apiErrorToServant err = base {errBody = encode err, errHeaders = jsonHeaders}
  where
    jsonHeaders = [("Content-Type", "application/json")]
    base = case err of
      NotFound _ -> err404
      BadRequest _ -> err400
      Forbidden _ -> err403
      Conflict _ -> err409
      InvalidTransition _ -> ServerError 422 "Unprocessable Entity" "" []
      InternalError _ -> err500

-- ── DB errors ─────────────────────────────────────────────────────

-- | Database errors — auto-wrapped by 'withDB' so handlers never see
-- raw PostgreSQL exceptions.
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
  toServantError (DBError ctx detail) =
    let body =
          encode $
            object
              [ "status" .= ("ERROR" :: Text),
                "code" .= ("DB_ERROR" :: Text),
                "message" .= ("Database error in " <> ctx <> ": " <> detail)
              ]
     in err500 {errBody = body, errHeaders = [("Content-Type", "application/json")]}

-- ── Workflow errors ───────────────────────────────────────────────

-- | Workflow/release execution errors.
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
  toServantError (WorkflowError step detail) =
    let body =
          encode $
            object
              [ "status" .= ("ERROR" :: Text),
                "code" .= ("WORKFLOW_ERROR" :: Text),
                "message" .= ("Workflow failed at " <> step <> ": " <> detail)
              ]
     in err500 {errBody = body, errHeaders = [("Content-Type", "application/json")]}

-- ── Error helpers ─────────────────────────────────────────────────

-- | Extract from Maybe or throw. Better than NammaYatri's version
-- because our errors are typed (not SomeException).
--
-- @
-- release <- fromMaybeM (NotFound "Release not found") mRelease
-- @
fromMaybeM :: (MonadThrow m, Exception e) => e -> Maybe a -> m a
fromMaybeM err = maybe (throwM err) pure

-- | Extract from Either or throw.
--
-- @
-- value <- fromEitherM (BadRequest . T.pack) parseResult
-- @
fromEitherM :: (MonadThrow m, Exception e) => (left -> e) -> Either left a -> m a
fromEitherM toErr = either (throwM . toErr) pure
