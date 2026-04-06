-- System Control Centre — Configuration
-- All settings in one file. Secrets imported from secrets.dhall.
let LogLevel = < DEBUG | INFO | WARNING | ERROR >

let AppState = < SERVER | RUNNER | SERVER_AND_RUNNER >

let secrets = ./secrets.dhall

in  { -- Database
      postgresCfg =
      { connectHost = env:SC_DB_HOST as Text ? "localhost"
      , connectPort = env:SC_DB_PORT as Text ? "5432"
      , connectUser = env:SC_DB_USER as Text ? env:USER as Text ? "postgres"
      , connectPassword = secrets.dbPassword
      , connectDatabase = env:SC_DB_NAME as Text ? "system_control"
      , connectionPoolCount = 10
      }
    , serverCfg =
      { port = env:PORT as Text ? "8012"
      , env = env:SC_ENV as Text ? "development"
      }
    , loggerCfg =
      { logLevel = LogLevel.DEBUG
      , logToFile = True
      , logFilePath = "/tmp/system-control.log"
      , logToConsole = True
      }
    , appState = AppState.SERVER
    , authTokenExpiry = 86400
    , runnerPollSeconds = 20
    , staggerCooloffSeconds = 120
    , maxK8sRetries = 3
    , maintenanceMode = False
    , autoMigrate = True
    , migrationPath = [ "dev/migrations/system-control" ]
    , availableEnvs = env:VITE_AVAILABLE_ENVS as Text ? "UAT,PROD,INTEG_CLUSTER"
    , defaultEnv = env:VITE_DEFAULT_ENV as Text ? "UAT"
    }
