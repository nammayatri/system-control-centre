{- | Shared workflow types used by all SCC product workflows.

Exposes 'WorkFlowError', the error classification used by checkpointed workflows:

* 'DomainError'      — unrecoverable; mark the workflow terminally failed.
* 'RetriableError'   — transient; the runner will retry on the next tick.
* 'MultipleErrors'   — aggregate multiple validation errors (collects all issues
                       before failing; prevents whack-a-mole fix cycles).

Product-specific workflow state types (e.g. @ReleaseState@ in Autopilot)
live in their own product modules and reference this module for the
shared error type only.
-}
module Core.Workflow.Types (
    WorkFlowError (..),
)
where

{- | Error classification for checkpointed workflows.

The 'MultipleErrors' constructor allows collecting multiple validation
failures before aborting, giving users a complete picture of what
needs fixing (pattern from infra-switch's WorkFlowError ErrList).
-}
data WorkFlowError
    = -- | Unrecoverable — do not retry.
      DomainError String
    | -- | Transient — runner will retry on the next tick.
      RetriableError String
    | -- | Multiple errors — unrecoverable aggregate.
      MultipleErrors [String]
    deriving (Eq, Show)
