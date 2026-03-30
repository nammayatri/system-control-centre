-- System Control Centre — Dev environment defaults

let generic = ../generic/common.dhall

in  { logLevel = generic.LogLevel.DEBUG
    , appState = generic.AppState.SERVER
    , postgresCfg =
      { connectHost = "localhost"
      , connectPort = 5432
      , connectUser = env:USER as Text ? "postgres"
      , connectPassword = ""
      , connectDatabase = "system_control"
      , connectionPoolCount = 10
      }
    , serverCfg =
      { port = 8012
      , env = "development"
      }
    }
