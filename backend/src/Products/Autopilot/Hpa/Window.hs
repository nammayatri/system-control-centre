{-# LANGUAGE OverloadedStrings #-}

{- | Pure schedule-time maths: which windows a 'ScheduleKind' has, whether one
is open right now, and whether two schedules collide. Everything is a
function of an explicit @now@ so it can be tested without a clock.

Windows are half-open, @[start, end)@: a window ending at 10:00 and another
starting at 10:00 do not overlap.
-}
module Products.Autopilot.Hpa.Window (
    Window (..),
    windowsBetween,
    activeWindow,
    nextWindowStart,
    schedulesOverlap,
    validateKind,
)
where

import Data.List (find)
import Data.Text (Text)
import Data.Time.Calendar (DayOfWeek, addDays, dayOfWeek)
import Data.Time.Clock (NominalDiffTime, UTCTime (..), addUTCTime)
import Products.Autopilot.Hpa.Types

data Window = Window
    { wStart :: UTCTime
    , wEnd :: Maybe UTCTime
    -- ^ @Nothing@ = open-ended (a permanent one-off change).
    }
    deriving (Eq, Show)

isoDay :: DayOfWeek -> Int
isoDay = fromEnum

minutes :: Int -> NominalDiffTime
minutes n = fromIntegral (n * 60)

{- | Windows that START in @[from, to)@, oldest first. A window that started
before @from@ is not returned even if still open; see 'activeWindow'.
-}
windowsBetween :: ScheduleKind -> UTCTime -> UTCTime -> [Window]
windowsBetween (Once s e) from to
    | s >= from && s < to = [Window s e]
    | otherwise = []
windowsBetween (Weekly days sm dur off) from to =
    [ Window st (Just (addUTCTime (minutes dur) st))
    | d <- candidateDays
    , isoDay (dayOfWeek d) `elem` days
    , let st = addUTCTime (minutes (sm - off)) (UTCTime d 0)
    , st >= from
    , st < to
    ]
  where
    -- The local day of a window start can be a day either side of its UTC day.
    candidateDays = takeWhileDay (utctDay from `addDaysSafe` (-2))
    takeWhileDay d
        | d > utctDay to `addDaysSafe` 2 = []
        | otherwise = d : takeWhileDay (addDays 1 d)
    addDaysSafe d n = addDays n d

-- | The window containing @now@, if any.
activeWindow :: ScheduleKind -> UTCTime -> Maybe Window
activeWindow k now = find contains (windowsBetween k lookback (addUTCTime 1 now))
  where
    -- Longest possible window is bounded for Weekly; Once starts anywhere in the past.
    lookback = case k of
        Once s _ -> min s now
        Weekly{} -> addUTCTime (negate (minutes (24 * 60 + 60))) now
    contains w = wStart w <= now && maybe True (now <) (wEnd w)

-- | First window start strictly after @t@, looking ahead 8 days for Weekly.
nextWindowStart :: ScheduleKind -> UTCTime -> Maybe UTCTime
nextWindowStart k t = case k of
    Once s _ -> if s > t then Just s else Nothing
    Weekly{} -> case filter ((> t) . wStart) (windowsBetween k t (addUTCTime (minutes (8 * 24 * 60)) t)) of
        (w : _) -> Just (wStart w)
        [] -> Nothing

{- | Do two schedules ever hold windows at the same time within the next
@horizonDays@ from @now@? Used to refuse a second schedule on a service
whose windows would collide with an existing one. An open-ended one-off
change is treated as lasting to the horizon.
-}
schedulesOverlap :: UTCTime -> Int -> ScheduleKind -> ScheduleKind -> Bool
schedulesOverlap now horizonDays a b =
    or [intersects x y | x <- wins a, y <- wins b]
  where
    horizon = addUTCTime (minutes (horizonDays * 24 * 60)) now
    wins k = openWindow k <> windowsBetween k now horizon
    -- A window already open at `now` started before the lookahead range.
    openWindow k = maybe [] pure (activeWindow k now)
    endOf w = maybe horizon id (wEnd w)
    intersects x y = wStart x < endOf y && wStart y < endOf x

-- | Structural checks; does not look at the clock.
validateKind :: ScheduleKind -> [Text]
validateKind (Once s e) =
    [ "endAt must be after startAt" | Just end <- [e], end <= s ]
validateKind (Weekly days sm dur off) =
    [ "days must not be empty" | null days ]
        <> [ "days must be ISO weekdays 1 (Mon) .. 7 (Sun)" | any (\d -> d < 1 || d > 7) days ]
        <> [ "days must not repeat" | hasDup days ]
        <> [ "startTime must be within a day" | sm < 0 || sm > 1439 ]
        <> [ "durationMinutes must be 1..1440" | dur < 1 || dur > 1440 ]
        <> [ "utcOffsetMinutes must be -720..840" | off < -720 || off > 840 ]
  where
    hasDup xs = length xs /= length (dedupe xs)
    dedupe [] = []
    dedupe (x : xs) = x : dedupe (filter (/= x) xs)
