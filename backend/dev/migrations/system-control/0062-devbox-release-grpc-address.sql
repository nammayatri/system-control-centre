-- 0062: Devbox Releases — the workspace's notification-service gRPC address.
--
-- devbox.yaml's DEVBOX_RESULT reports grpc_address (devbox tailnet IP + the
-- workspace's notification-service-grpc port, e.g. 100.64.0.12:50066). The
-- Android driver app build gets it as its grpc_address input, so the app takes
-- ride requests from the devbox instead of production gRPC. NULL for releases
-- from before devbox_core reported it.

ALTER TABLE devbox_release
  ADD COLUMN IF NOT EXISTS grpc_address TEXT;   -- 'host:port', e.g. '100.64.0.12:50066'
