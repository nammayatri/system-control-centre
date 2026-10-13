{-# LANGUAGE OverloadedStrings #-}

{- | SQL migrations that ship with a release.

The changed @.sql@ files of the diff are grouped by the database each one belongs to (the
@sqlFiles@ rules on the app group: database name -> repo path prefixes) and rendered as ONE
runnable file, so whoever releases can run them before the tracker is created. A changed
SQL file that no rule claims is reported, never dropped.
-}
module Products.Autopilot.ReleaseBot.Sql (
    SqlPlan (..),
    isSqlFile,
    collectSql,
    renderSql,
) where

import Control.Monad.IO.Class (MonadIO)
import Data.List (nub, sort)
import Data.Maybe (mapMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import Products.Autopilot.ProdRelease.Config
import Products.Autopilot.ProdRelease.Github (getFileAt)

data SqlPlan = SqlPlan
    { spByDb :: [(Text, [(Text, Text)])]
    -- ^ database -> [(repo path, file content)], in path order
    , spUnmapped :: [Text]
    -- ^ changed .sql files no rule claims
    , spUnreadable :: [Text]
    -- ^ "path: why" for files that could not be fetched (deleted files are skipped silently)
    }
    deriving (Show)

isSqlFile :: Text -> Bool
isSqlFile = T.isSuffixOf ".sql" . T.toLower

-- | Prefix match, or a wildcard pattern (reusing the repo's path-pattern matcher).
claims :: SqlRule -> Text -> Bool
claims r path = any ok (sqPaths r)
  where
    ok p
        | T.any (== '*') p = matchesAny [p] path
        | otherwise = p `T.isPrefixOf` path

-- | Fetch every changed .sql file at @fullSha@ and group it by database.
collectSql :: (MonadIO m) => Text -> Text -> RepoCfg -> [Text] -> Text -> m SqlPlan
collectSql token slug repo changed fullSha = do
    let files = sort (nub (filter isSqlFile changed))
        owner f = case [sqDb r | r <- rcSql repo, claims r f] of
            (d : _) -> Just d
            [] -> Nothing
        unmapped = [f | f <- files, owner f == Nothing]
    fetched <- mapM (\f -> (,) f <$> getFileAt token slug f fullSha) [f | f <- files, owner f /= Nothing]
    let good = [(f, c) | (f, Right c) <- fetched]
        -- a file removed by the release no longer exists at the target: nothing to run
        bad = [f <> ": " <> e | (f, Left e) <- fetched, not ("not found" `T.isInfixOf` T.toLower e)]
        dbs = nub (mapMaybe (owner . fst) good)
    pure
        SqlPlan
            { spByDb = [(d, [(f, c) | (f, c) <- good, owner f == Just d]) | d <- dbs]
            , spUnmapped = unmapped
            , spUnreadable = bad
            }

-- | One runnable file: a header per database, then each migration under its path.
renderSql :: Text -> SqlPlan -> Text
renderSql title plan =
    T.unlines $
        ["-- " <> title, "-- Run each section against the database named in its header, in order.", ""]
            ++ concat
                [ ["-- ============================================================", "-- DATABASE: " <> db, "-- ============================================================", ""]
                    ++ concat [["-- >>> " <> f, T.stripEnd c, ""] | (f, c) <- fs]
                | (db, fs) <- spByDb plan
                ]
