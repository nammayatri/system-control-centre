-- System Control Centre — Main service config (dev)

let common = ./common.dhall

let sec = ./secrets/common.dhall

in  { postgresCfg = common.postgresCfg // { connectPassword = sec.dbPassword }
    , serverCfg = common.serverCfg
    , logLevel = common.logLevel
    , appState = common.appState
    , authTokenExpiry = 86400
    , runnerPollSeconds = 20
    , staggerCooloffSeconds = 120
    , maxK8sRetries = 3
    , maintenanceMode = False
    , autoMigrate = True
    , migrationPath = [ "dev/migrations/system-control" ]
    }
