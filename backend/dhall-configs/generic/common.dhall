-- System Control Centre — Generic type definitions
-- These types are environment-independent.

let LogLevel = < DEBUG | INFO | WARNING | ERROR >

let AppState = < SERVER | RUNNER | SERVER_AND_RUNNER >

let PostgresCfg =
      { connectHost : Text
      , connectPort : Natural
      , connectUser : Text
      , connectPassword : Text
      , connectDatabase : Text
      , connectionPoolCount : Natural
      }

let ServerCfg =
      { port : Natural
      , env : Text
      }

in  { LogLevel, AppState, PostgresCfg, ServerCfg }
