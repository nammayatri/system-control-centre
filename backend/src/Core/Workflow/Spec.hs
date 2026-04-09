{-# LANGUAGE RankNTypes #-}

{- | Product-agnostic workflow spec for the SCC workflow engine.

A 'WorkflowSpec s' is a __value__ that describes one workflow as data:

* a name (for logging / metrics / dispatch)
* an ordered list of stages ('Core.Workflow.Stage.Stage' values)
* a workflow-level rollback handler (runs once on any stage failure)

This is the unit of polymorphism: every SCC product builds 'WorkflowSpec s'
values for its release types, and the engine in 'Core.Workflow.Engine' runs
them generically. Adding a new product type is a new value, not a new module.

== Example shape ==

@
-- Autopilot's BackendService spec
backendServiceSpec :: WorkflowSpec ReleaseState
backendServiceSpec = WorkflowSpec
    { wsName     = "BackendService"
    , wsStages   = [initStage, prepareStage, deployStage, monitorStage, finalizeStage]
    , wsRollback = restoreVsTrafficOnFailure
    }

-- A future frontend release product
frontendBuildSpec :: WorkflowSpec FrontendReleaseState
frontendBuildSpec = WorkflowSpec
    { wsName     = "FrontendBuild"
    , wsStages   = [initStage, buildStage, uploadS3Stage, invalidateCdnStage]
    , wsRollback = restoreS3PreviousVersion
    }
@

Both call the same 'Core.Workflow.Engine.runWorkflowSpec'. Different state
types. Same engine. Same canonical lifecycle.
-}
module Core.Workflow.Spec (
    WorkflowSpec (..),
)
where

import Core.Environment (Flow)
import Core.Workflow.Stage (Stage, StageM)
import Core.Workflow.Types (WorkFlowError)
import Data.Text (Text)

{- | A product-agnostic workflow spec.

Parameterized over the state type @s@ — different products use different
state types but share the same engine. The 'wsRollback' handler is
polymorphic in @m@ via 'StageM' for the same reason 'Stage' executors are:
testability and decoupling from the concrete monad stack.
-}
data WorkflowSpec s = WorkflowSpec
    { wsName :: Text
    -- ^ Workflow name. Used as a log tag, metric label, and event record name.
    --   Should match the corresponding 'ReleaseCategory' constructor or
    --   product type identifier (e.g. @"BackendService"@, @"BackendScheduler"@,
    --   @"FrontendBuild"@).
    , wsStages :: [Stage s]
    -- ^ Ordered list of stages. The engine walks them in order, running each
    --   through the canonical six-step lifecycle (skip-check, acquire-locks,
    --   pre-check, exec, validate, advance-and-persist).
    --
    --   Sharing stages across workflows is encouraged: an @initStage@ that
    --   logs the workflow start can be defined once and reused in every
    --   spec. The engine doesn't care whether two specs share stage values
    --   by reference or define them independently.
    , wsRollback :: forall m. (StageM s m) => WorkFlowError -> m ()
    -- ^ Workflow-level rollback handler. Runs once when any stage in
    --   'wsStages' throws — AFTER the failing stage's @stageOnError@ has
    --   run, BEFORE the exception propagates out of the workflow.
    --
    --   Each product implements its own (e.g. K8s products restore
    --   VirtualService traffic to the old version, frontend products
    --   promote the previous S3 object version, SDK products are no-ops
    --   because npm doesn't really unpublish).
    --
    --   The handler MUST be idempotent — it may run multiple times if
    --   the rollback itself crashes and the runner retries.
    , wsPersist :: s -> Flow ()
    -- ^ Persist the workflow state to durable storage (typically a DB row).
    --   Called by the engine after every successful stage advance, so that a
    --   process crash mid-workflow can be resumed from the last persisted
    --   state on the next runner tick.
    --
    --   This function MUST be idempotent and atomic. SCC's autopilot uses
    --   'persistWorkflowState' which wraps the upsert in 'withTransaction'
    --   and uses 'conditionalUpdateTracker' for CAS-based race protection.
    --
    --   Different products will have different persist functions because
    --   the state type @s@ varies (e.g. @ReleaseState@ for autopilot,
    --   @FrontendReleaseState@ for a future frontend release product).
    }
