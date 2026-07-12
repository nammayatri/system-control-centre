{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeOperators #-}

module Core.Mcp.Server
  ( McpAPI,
    mcpServer,
  )
where

import Control.Exception (fromException)
import Control.Monad (filterM)
import Control.Monad.Catch (SomeException, try)
import Core.AppError (AppException (..), ToAppError (..))
import Core.Auth.Protected (checkPersonPermission)
import Core.Auth.Types (PersonAuth)
import Core.Environment (Flow)
import Core.Mcp.Auth (resolvePatPerson)
import Core.Mcp.Tools (McpTool (..), mcpProduct, mcpTools)
import Data.Aeson (Value (..), encode, object, (.=))
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString.Lazy qualified as LBS
import Data.List (find)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Products.Autopilot.Types.Permission (autopilotPermissionToText)
import Servant

type McpAPI = Header "Authorization" Text :> ReqBody '[JSON] Value :> Post '[JSON] Value

mcpServer :: ServerT McpAPI Flow
mcpServer = handleMcpRequest

data RpcRequest = RpcRequest
  { rpcId :: Value,
    rpcMethod :: Text,
    rpcParams :: Value
  }

parseRpc :: Value -> Maybe RpcRequest
parseRpc (Object o) = do
  method <- case KM.lookup "method" o of
    Just (String m) -> Just m
    _ -> Nothing
  let rpcId = fromMaybe Null (KM.lookup "id" o)
      rpcParams = fromMaybe (Object KM.empty) (KM.lookup "params" o)
  pure RpcRequest {rpcMethod = method, ..}
parseRpc _ = Nothing

rpcResult :: Value -> Value -> Value
rpcResult reqId result = object ["jsonrpc" .= ("2.0" :: Text), "id" .= reqId, "result" .= result]

rpcError :: Value -> Int -> Text -> Value
rpcError reqId code msg =
  object
    [ "jsonrpc" .= ("2.0" :: Text),
      "id" .= reqId,
      "error" .= object ["code" .= code, "message" .= msg]
    ]

handleMcpRequest :: Maybe Text -> Value -> Flow Value
handleMcpRequest mAuth body =
  case parseRpc body of
    Nothing -> pure (rpcError Null (-32600) "Invalid Request")
    Just RpcRequest {..} -> dispatch mAuth rpcId rpcMethod rpcParams

dispatch :: Maybe Text -> Value -> Text -> Value -> Flow Value
dispatch mAuth reqId method params = case method of
  "initialize" -> pure (rpcResult reqId initializeResult)
  "notifications/initialized" -> pure (object [])
  "ping" -> pure (rpcResult reqId (object []))
  "tools/list" -> withPerson $ \person -> do
    allowed <- filterAllowedTools person
    pure (rpcResult reqId (object ["tools" .= map toolListing allowed]))
  "tools/call" -> withPerson (\person -> handleToolCall person reqId params)
  _ -> pure (rpcError reqId (-32601) ("Method not found: " <> method))
  where
    withPerson k = do
      mPerson <- resolvePatPerson mAuth
      case mPerson of
        Nothing -> pure (rpcError reqId (-32001) "Unauthorized: missing, invalid, expired, or revoked PAT")
        Just person -> k person

initializeResult :: Value
initializeResult =
  object
    [ "protocolVersion" .= ("2024-11-05" :: Text),
      "capabilities" .= object ["tools" .= object []],
      "serverInfo" .= object ["name" .= ("system-control-centre" :: Text), "version" .= ("0.1.0" :: Text)]
    ]

filterAllowedTools :: PersonAuth -> Flow [McpTool]
filterAllowedTools person = filterM isAllowed mcpTools
  where
    isAllowed tool = do
      result <- checkPersonPermission mcpProduct (autopilotPermissionToText (mtPermission tool)) person
      pure (either (const False) (const True) result)

toolListing :: McpTool -> Value
toolListing McpTool {..} =
  object
    [ "name" .= mtName,
      "description" .= mtDescription,
      "inputSchema" .= mtInputSchema
    ]

parseToolCallParams :: Value -> Maybe (Text, Value)
parseToolCallParams (Object o) = do
  name <- case KM.lookup "name" o of
    Just (String n) -> Just n
    _ -> Nothing
  pure (name, fromMaybe (Object KM.empty) (KM.lookup "arguments" o))
parseToolCallParams _ = Nothing

handleToolCall :: PersonAuth -> Value -> Value -> Flow Value
handleToolCall person reqId params =
  case parseToolCallParams params of
    Nothing -> pure (rpcError reqId (-32602) "Invalid params: expected {name, arguments}")
    Just (toolName, args) ->
      case find (\t -> mtName t == toolName) mcpTools of
        Nothing -> pure (rpcError reqId (-32601) ("Unknown tool: " <> toolName))
        Just tool -> do
          permResult <- checkPersonPermission mcpProduct (autopilotPermissionToText (mtPermission tool)) person
          case permResult of
            Left (_, msg) -> pure (rpcError reqId (-32001) ("Permission denied: " <> msg))
            Right authedPerson -> do
              outcome <- try (mtRun tool authedPerson args) :: Flow (Either SomeException Value)
              case outcome of
                Right resultValue -> pure (rpcResult reqId (toolContent (jsonText resultValue) False))
                Left ex -> pure (rpcResult reqId (toolContent (formatToolError ex) True))

toolContent :: Text -> Bool -> Value
toolContent text isError =
  object
    [ "content" .= [object ["type" .= ("text" :: Text), "text" .= text]],
      "isError" .= isError
    ]

jsonText :: Value -> Text
jsonText v = TE.decodeUtf8 (LBS.toStrict (encode v))

formatToolError :: SomeException -> Text
formatToolError ex
  | Just (AppException inner) <- fromException ex = toErrorMessage inner
  | otherwise = T.pack (show ex)
