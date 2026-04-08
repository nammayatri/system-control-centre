{- | Shared workflow types used by all SCC product workflows.

Currently exposes only 'WorkFlowError', the two-bucket error classification
used by every checkpointed workflow:

* 'DomainError'    — unrecoverable; mark the workflow terminally failed.
* 'RetriableError' — transient; the runner will retry on the next tick.

Product-specific workflow state types (e.g. @ReleaseState@ in Autopilot)
live in their own product modules and reference this module for the
shared error type only.
-}
module Core.Workflow.Types (
    WorkFlowError (..),
)
where

-- | Two-bucket error classification for checkpointed workflows.
data WorkFlowError
    = -- | Unrecoverable — do not retry.
      DomainError String
    | -- | Transient — runner will retry on the next tick.
      RetriableError String
    deriving (Eq, Show)
