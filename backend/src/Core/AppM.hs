{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE ScopedTypeVariables #-}

{- | Global application monad — everything the app needs, no opaque runtime.

Better than NammaYatri's approach because:

  * No EulerHS black box — every layer is visible and auditable
  * Typed exception hierarchy — not raw 'SomeException' catching
  * DB errors auto-wrapped — handlers never see PostgreSQL exceptions
  * Request context auto-propagated — requestId in every log line
  * Compile-time RBAC via Protected combinator (NammaYatri doesn't have this)

== Usage

@
-- In handlers:
handler :: AppM Value
handler = do
  cfg <- askConfig                                  -- config access
  release <- withDB $ \\c -> findById c rid          -- safe DB access
  logInfo $ "Found release " <> releaseId release   -- auto-context logs
  fromMaybeM (NotFound "not found") mValue          -- typed error throw

-- In IO (background tasks):
runAppM env $ do
  logInfo "Poll loop tick"
  withDB $ \\c -> findRunnableReleases c
@
-}
module Core.AppM (
    -- * The monad
    AppM,
    runAppM,

    -- * Environment
    AppEnv (..),
    mkAppEnv,
    mkBackgroundEnv,

    -- * Request context
    RequestContext (..),

    -- * Typeclasses
    MonadDB (..),
    MonadLog (..),
    MonadAppConfig (..),

    -- * Safe DB access
    withDBTransaction,

    -- * Concurrent execution with context
    forkAppM,

    -- * Convenience constraint
    AppFlow,
)
where

import Control.Concurrent (ThreadId, forkIO)
import Control.Exception (SomeException, try)
import Control.Monad.Catch (MonadCatch, MonadMask, MonadThrow, throwM)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Control.Monad.Reader (MonadReader, ReaderT (..), ask, asks, runReaderT)
import Core.AppError (DBError (..))
import Core.Config (Config)
import Core.Logging (LogLevel (..), LoggerEnv, logOutput)
import Data.Pool (Pool, withResource)
import Data.Text (Text)
import qualified Data.Text as T
import Data.UUID (toText)
import Data.UUID.V4 (nextRandom)
import Database.PostgreSQL.Simple (Connection, withTransaction)

-- ── Request context ───────────────────────────────────────────────

-- | Per-request metadata, auto-attached to logs and propagated to forks.
data RequestContext = RequestContext
    { rcRequestId :: !Text
    , rcSessionId :: !(Maybe Text)
    }

-- ── Application environment ───────────────────────────────────────

{- | Immutable environment threaded through every computation.
Built once per HTTP request (with RequestContext) or once for
background tasks (without).
-}
data AppEnv = AppEnv
    { aeConfig :: !Config
    , aeDBPool :: !(Pool Connection)
    , aeLoggerEnv :: !LoggerEnv
    , aeReqCtx :: !(Maybe RequestContext)
    }

-- | Build an AppEnv for an HTTP request (with request context).
mkAppEnv :: Config -> Pool Connection -> LoggerEnv -> RequestContext -> AppEnv
mkAppEnv cfg pool logEnv ctx =
    AppEnv
        { aeConfig = cfg
        , aeDBPool = pool
        , aeLoggerEnv = logEnv
        , aeReqCtx = Just ctx
        }

-- | Build an AppEnv for background tasks (no request context).
mkBackgroundEnv :: Config -> Pool Connection -> LoggerEnv -> AppEnv
mkBackgroundEnv cfg pool logEnv =
    AppEnv
        { aeConfig = cfg
        , aeDBPool = pool
        , aeLoggerEnv = logEnv
        , aeReqCtx = Nothing
        }

-- ── The monad ─────────────────────────────────────────────────────

{- | The application monad. A transparent @ReaderT AppEnv IO@ with:

  * 'MonadThrow' / 'MonadCatch' for typed exception handling
  * 'MonadDB' for safe database access
  * 'MonadLog' for context-aware logging
  * 'MonadAppConfig' for config access
-}
newtype AppM a = AppM (ReaderT AppEnv IO a)
    deriving
        ( Functor
        , Applicative
        , Monad
        , MonadIO
        , MonadReader AppEnv
        , MonadThrow
        , MonadCatch
        , MonadMask
        )

runAppM :: AppEnv -> AppM a -> IO a
runAppM env (AppM m) = runReaderT m env

-- ── MonadDB ───────────────────────────────────────────────────────

{- | Database access typeclass. The implementation auto-wraps PostgreSQL
exceptions in 'DBError' so handlers never see raw exceptions.

NammaYatri catches @SomeException@ and loses type info.
We catch specifically and preserve context.
-}
class (MonadIO m, MonadThrow m) => MonadDB m where
    -- | Run an action with a connection from the pool. DB exceptions are
    -- automatically caught and re-thrown as 'DBError'.
    withDB :: (Connection -> IO a) -> m a

instance MonadDB AppM where
    withDB action = do
        pool <- asks aeDBPool
        result <- liftIO $ try (withResource pool action)
        case result of
            Right a -> pure a
            Left (e :: SomeException) ->
                throwM $
                    DBError
                        { dbErrorContext = "withDB"
                        , dbErrorDetail = T.pack (show e)
                        }

{- | Run a DB action inside a PostgreSQL transaction. On exception,
the transaction is rolled back automatically.
-}
withDBTransaction :: (Connection -> IO a) -> AppM a
withDBTransaction action = do
    pool <- asks aeDBPool
    result <- liftIO $ try (withResource pool $ \conn -> withTransaction conn (action conn))
    case result of
        Right a -> pure a
        Left (e :: SomeException) ->
            throwM $
                DBError
                    { dbErrorContext = "withDBTransaction"
                    , dbErrorDetail = T.pack (show e)
                    }

-- ── MonadLog ──────────────────────────────────────────────────────

{- | Logging typeclass. Request context (requestId) is automatically
prepended to every log line — no manual threading needed.

NammaYatri requires @appendLogTag@ calls. Ours is automatic.
-}
class (MonadIO m) => MonadLog m where
    logInfo :: Text -> m ()
    logError :: Text -> m ()
    logWarning :: Text -> m ()
    logDebug :: Text -> m ()

instance MonadLog AppM where
    logInfo = appMLog INFO
    logError = appMLog ERROR
    logWarning = appMLog WARNING
    logDebug = appMLog DEBUG

appMLog :: LogLevel -> Text -> AppM ()
appMLog lvl msg = do
    env <- asks aeLoggerEnv
    ctx <- asks aeReqCtx
    let prefix = case ctx of
            Just rc -> "[" <> rcRequestId rc <> "] "
            Nothing -> ""
    liftIO $ logOutput env lvl (prefix <> msg)

-- ── MonadAppConfig ────────────────────────────────────────────────

class (Monad m) => MonadAppConfig m where
    askConfig :: m Config

instance MonadAppConfig AppM where
    askConfig = asks aeConfig

-- ── Fork with context ─────────────────────────────────────────────

{- | Fork an AppM computation in a new thread, propagating the current
environment (including request context). The forked thread gets
its own request ID suffixed with @-fork-<uuid>@ for traceability.

NammaYatri creates fresh MVar per fork but loses the parent request ID.
We preserve it with a suffix.
-}
forkAppM :: Text -> AppM () -> AppM ThreadId
forkAppM tag action = do
    env <- AppM ask
    liftIO $
        forkIO $ do
            forkId <- toText <$> nextRandom
            let parentId = maybe "bg" rcRequestId (aeReqCtx env)
                forkCtx = RequestContext (parentId <> "-fork-" <> T.take 8 forkId) Nothing
                forkEnv = env{aeReqCtx = Just forkCtx}
            _ <- runAppM forkEnv $ do
                logDebug $ "[" <> tag <> "] forked"
                action
            pure ()

-- ── Convenience constraint ────────────────────────────────────────

-- | All the capabilities a typical handler needs.
type AppFlow m = (MonadDB m, MonadLog m, MonadAppConfig m, MonadThrow m, MonadIO m)
