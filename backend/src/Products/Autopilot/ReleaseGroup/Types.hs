{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

{- | Types and pure planning for release bundles and grouped runs
(migration 0057). No IO here — the planner is what the coordinator tests.
-}
module Products.Autopilot.ReleaseGroup.Types (
    StageMode (..),
    StepDef (..),
    StageDef (..),
    Bundle (..),
    RunState (..),
    StepState (..),
    RunStep (..),
    GroupRun (..),
    Outcome (..),
    StepView (..),
    Decision (..),
    stageModeText,
    parseStageMode,
    runStateText,
    parseRunState,
    stepStateText,
    parseStepState,
    validateStages,
    withSteps,
    flattenSteps,
    classifyStatus,
    planAdvance,
)
where

import Data.Aeson (FromJSON (..), ToJSON (..), withText)
import Data.List (nub, sortOn)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time.Clock (UTCTime)
import GHC.Generics (Generic)

data StageMode = Parallel | Sequential
    deriving (Show, Eq, Generic)

stageModeText :: StageMode -> Text
stageModeText Parallel = "PARALLEL"
stageModeText Sequential = "SEQUENTIAL"

parseStageMode :: Text -> Maybe StageMode
parseStageMode t = case T.toUpper t of
    "PARALLEL" -> Just Parallel
    "SEQUENTIAL" -> Just Sequential
    _ -> Nothing

instance ToJSON StageMode where toJSON = toJSON . stageModeText
instance FromJSON StageMode where
    parseJSON = withText "StageMode" $ maybe (fail "mode must be PARALLEL or SEQUENTIAL") pure . parseStageMode

data StepDef = StepDef
    { appGroup :: Text
    , service :: Text
    }
    deriving (Show, Eq, Generic)

instance ToJSON StepDef
instance FromJSON StepDef

data StageDef = StageDef
    { name :: Text
    , mode :: StageMode
    , steps :: [StepDef]
    }
    deriving (Show, Eq, Generic)

instance ToJSON StageDef
instance FromJSON StageDef

data Bundle = Bundle
    { bundleId :: Text
    , name :: Text
    , description :: Text
    , stages :: [StageDef]
    , archived :: Bool
    , createdBy :: Text
    , createdAt :: UTCTime
    , updatedAt :: UTCTime
    }
    deriving (Show, Eq, Generic)

instance ToJSON Bundle

data RunState = PendingApproval | Running | Halted | Completed | Aborted
    deriving (Show, Eq, Generic)

runStateText :: RunState -> Text
runStateText PendingApproval = "PENDING_APPROVAL"
runStateText Running = "RUNNING"
runStateText Halted = "HALTED"
runStateText Completed = "COMPLETED"
runStateText Aborted = "ABORTED"

parseRunState :: Text -> Maybe RunState
parseRunState t = case t of
    "PENDING_APPROVAL" -> Just PendingApproval
    "RUNNING" -> Just Running
    "HALTED" -> Just Halted
    "COMPLETED" -> Just Completed
    "ABORTED" -> Just Aborted
    _ -> Nothing

instance ToJSON RunState where toJSON = toJSON . runStateText

data StepState = Waiting | Started | Skipped
    deriving (Show, Eq, Generic)

stepStateText :: StepState -> Text
stepStateText Waiting = "WAITING"
stepStateText Started = "STARTED"
stepStateText Skipped = "SKIPPED"

parseStepState :: Text -> Maybe StepState
parseStepState t = case t of
    "WAITING" -> Just Waiting
    "STARTED" -> Just Started
    "SKIPPED" -> Just Skipped
    _ -> Nothing

instance ToJSON StepState where toJSON = toJSON . stepStateText

data RunStep = RunStep
    { stageIdx :: Int
    , stepIdx :: Int
    , stageName :: Text
    , stageMode :: StageMode
    , appGroup :: Text
    , service :: Text
    , releaseId :: Text
    , state :: StepState
    , releaseStatus :: Maybe Text
    -- ^ live tracker status; filled in by the API layer, not stored
    }
    deriving (Show, Eq, Generic)

instance ToJSON RunStep

data GroupRun = GroupRun
    { runId :: Text
    , bundleId :: Text
    , bundleName :: Text
    , env :: Text
    , description :: Text
    , state :: RunState
    , haltReason :: Text
    , createdBy :: Text
    , approvedBy :: Maybe Text
    , createdAt :: UTCTime
    , updatedAt :: UTCTime
    , steps :: [RunStep]
    }
    deriving (Show, Eq, Generic)

instance ToJSON GroupRun

-- | Replace a run's steps (e.g. with live tracker status filled in).
withSteps :: [RunStep] -> GroupRun -> GroupRun
withSteps ss (GroupRun a b c d e f g h i j k _) = GroupRun a b c d e f g h i j k ss

-- | Reject shapes that would create an unusable or ambiguous bundle.
validateStages :: [StageDef] -> Either Text ()
validateStages stgs
    | null stgs = Left "A bundle needs at least one stage"
    | any (null . (.steps)) stgs = Left "Every stage needs at least one service"
    | any (T.null . T.strip . (.name)) stgs = Left "Every stage needs a name"
    | any (\s -> T.null (T.strip s.appGroup) || T.null (T.strip s.service)) allSteps = Left "Every step needs an app group and a service"
    | length (nub keys) /= length keys = Left "A service can appear only once in a bundle"
    | otherwise = Right ()
  where
    allSteps = concatMap (.steps) stgs
    keys = [(s.appGroup, s.service) | s <- allSteps]

-- | (stageIdx, stepIdx, stage, step) in execution order.
flattenSteps :: [StageDef] -> [(Int, Int, StageDef, StepDef)]
flattenSteps stgs =
    [ (si, pi', stg, stp)
    | (si, stg) <- zip [0 ..] stgs
    , (pi', stp) <- zip [0 ..] stg.steps
    ]

-- | What a started step's tracker is doing, from the coordinator's view.
data Outcome = NotStarted | InFlight | Done | Failed Text | Unknown
    deriving (Show, Eq)

-- | Tracker status text -> outcome for a STARTED step.
classifyStatus :: Text -> Outcome
classifyStatus s
    | s == "COMPLETED" = Done
    | s `elem` ["ABORTED", "USER_ABORTED", "GCLT_ABORTED", "DISCARDED", "REVERTED", "UNLOCKED"] = Failed s
    | otherwise = InFlight

data StepView = StepView
    { stage :: Int
    , step :: Int
    , mode :: StageMode
    , outcome :: Outcome
    }
    deriving (Show, Eq)

data Decision
    = StartSteps [(Int, Int)]
    | HaltRun Text
    | CompleteRun
    | Wait
    deriving (Show, Eq)

{- | Decide the next move for a RUNNING group. Stages go strictly in order; the
first stage that isn't fully done is "current". A failed step there halts the
group (siblings already running are left alone). PARALLEL stages start every
waiting step at once; SEQUENTIAL ones start the next only when none is in flight.
-}
planAdvance :: [StepView] -> Decision
planAdvance views = case current of
    [] -> CompleteRun
    cur
        | (f : _) <- [r | StepView {outcome = Failed r} <- cur] -> HaltRun f
        | any ((== Unknown) . (.outcome)) cur -> Wait
        | otherwise ->
            let waiting = [(v.stage, v.step) | v <- cur, v.outcome == NotStarted]
             in case stageMode' cur of
                    Parallel -> startOrWait waiting
                    Sequential
                        | any ((== InFlight) . (.outcome)) cur -> Wait
                        | otherwise -> startOrWait (take 1 waiting)
  where
    sorted = sortOn (\v -> (v.stage, v.step)) views
    stageIds = nub (map (.stage) sorted)
    unfinishedStage = [i | i <- stageIds, any ((/= Done) . (.outcome)) (inStage i)]
    inStage i = [v | v <- sorted, v.stage == i]
    current = case unfinishedStage of
        (i : _) -> inStage i
        [] -> []
    stageMode' (v : _) = v.mode
    stageMode' [] = Sequential
    startOrWait [] = Wait
    startOrWait xs = StartSteps xs
