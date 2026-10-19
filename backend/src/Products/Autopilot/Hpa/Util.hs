{-# LANGUAGE OverloadedStrings #-}

-- | Small helpers shared by the HPA scheduler modules (kept in one place so a fix is made once).
module Products.Autopilot.Hpa.Util (
    decodeValue,
    newId,
    isAsync,
    tshow,
)
where

import Control.Exception (SomeAsyncException (..))
import Control.Monad.Catch (SomeException, fromException)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Data.Aeson (FromJSON, Value)
import Data.Aeson qualified as A
import Data.Text (Text)
import Data.Text qualified as T
import Data.UUID qualified as UUID
import Data.UUID.V4 qualified as UUID

tshow :: (Show a) => a -> Text
tshow = T.pack . show

-- | Decode a stored JSON value; the error text is for logs and events.
decodeValue :: (FromJSON a) => Value -> Either Text a
decodeValue v = case A.fromJSON v of
    A.Success a -> Right a
    A.Error e -> Left (T.pack e)

newId :: (MonadIO m) => m Text
newId = liftIO (UUID.toText <$> UUID.nextRandom)

{- | An asynchronous exception (shutdown, cancellation). Handlers that catch everything must
re-throw these so a loop can actually be stopped.
-}
isAsync :: SomeException -> Bool
isAsync e = case fromException e of
    Just (SomeAsyncException _) -> True
    Nothing -> False
