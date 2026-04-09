{-# LANGUAGE RankNTypes #-}

{- | Product-agnostic workflow spec: name, ordered stages, rollback handler,
and persist function. One 'WorkflowSpec s' per release type per product;
all of them run through 'Core.Workflow.Engine.runWorkflowSpec'.
-}
module Core.Workflow.Spec (
    WorkflowSpec (..),
)
where

import Core.Environment (Flow)
import Core.Workflow.Stage (Stage, StageM)
import Core.Workflow.Types (WorkFlowError)
import Data.Text (Text)

data WorkflowSpec s = WorkflowSpec
    { wsName :: Text
    -- ^ Log tag / metric label / event record name. Usually matches the
    --   'ReleaseCategory' constructor (e.g. @"BackendService"@).
    , wsStages :: [Stage s]
    -- ^ Ordered stages. Sharing stage values across specs is fine.
    , wsRollback :: forall m. (StageM s m) => WorkFlowError -> m ()
    -- ^ Runs once on any stage failure, AFTER the failing stage's
    --   'stageOnError' and BEFORE the error propagates out. MUST be
    --   idempotent — may run again on runner retries.
    , wsPersist :: s -> Flow ()
    -- ^ Durable persist after each successful stage advance; enables
    --   crash-resume on the next tick. MUST be transactional + idempotent.
    }
