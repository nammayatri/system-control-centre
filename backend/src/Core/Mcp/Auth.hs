{-# LANGUAGE OverloadedStrings #-}

module Core.Mcp.Auth
  ( resolvePatPerson,
  )
where

import Control.Monad.IO.Class (liftIO)
import Core.Auth.Queries (findPatKeyByHash, findPersonById, hashPatToken, touchPatKeyLastUsed)
import Core.Auth.Schema (McpPatKeyT (..))
import Core.Auth.Types (PersonAuth (..))
import Core.Environment (MonadFlow)
import Data.Maybe (isJust)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Clock (getCurrentTime)

resolvePatPerson :: (MonadFlow m) => Maybe Text -> m (Maybe PersonAuth)
resolvePatPerson mHeader =
  case extractApiKey mHeader of
    Nothing -> pure Nothing
    Just token -> do
      mKey <- findPatKeyByHash (hashPatToken token)
      case mKey of
        Nothing -> pure Nothing
        Just key -> do
          now <- liftIO getCurrentTime
          if isJust (mpkRevokedAt key) || mpkExpiresAt key < now
            then pure Nothing
            else do
              mPerson <- findPersonById (mpkPersonId key)
              case mPerson of
                Just person | personIsActive person -> do
                  touchPatKeyLastUsed (mpkId key)
                  pure (Just person)
                _ -> pure Nothing

extractApiKey :: Maybe Text -> Maybe Text
extractApiKey Nothing = Nothing
extractApiKey (Just raw0) =
  let raw = T.strip raw0
   in case T.stripPrefix "ApiKey " raw of
        Just t -> let t' = T.strip t in if T.null t' then Nothing else Just t'
        Nothing -> Nothing
