{-# LANGUAGE OverloadedStrings #-}

{- | SQL migrations that ship with a release, attributed to services by DATABASE SCHEMA.

Every changed @.sql@ file of the diff is fetched and split into statements. A statement
belongs to a service when it names one of that service's schemas (@sqlSchemas@ on the
service rule, e.g. @atlas_app@ -> @ALTER TABLE atlas_app.offer …@). The statements of a
service are rendered as one runnable file, so they can be run before its tracker exists.
A statement naming none of the configured schemas is reported, never dropped.
-}
module Products.Autopilot.ReleaseBot.Sql (
    SqlFile (..),
    isSqlFile,
    fetchSqlFiles,
    splitStatements,
    mentionsSchema,
    statementsFor,
    unattributed,
    renderSql,
    countStatements,
) where

import Control.Monad.IO.Class (MonadIO)
import Data.Char (isAlphaNum)
import Data.List (nub, sort)
import Data.Text (Text)
import qualified Data.Text as T
import Products.Autopilot.ProdRelease.Github (getFileAt)

-- | One changed .sql file and its statements.
data SqlFile = SqlFile
    { sfPath :: Text
    , sfStatements :: [Text]
    }
    deriving (Show, Eq)

isSqlFile :: Text -> Bool
isSqlFile = T.isSuffixOf ".sql" . T.toLower

{- | Fetch the changed .sql files at @fullSha@. A file removed by the release no longer exists
there (nothing to run) and is skipped; any other failure is returned so it can be flagged.
-}
fetchSqlFiles :: (MonadIO m) => Text -> Text -> [Text] -> Text -> m ([SqlFile], [Text])
fetchSqlFiles token slug changed fullSha = do
    let files = sort (nub (filter isSqlFile changed))
    fetched <- mapM (\f -> (,) f <$> getFileAt token slug f fullSha) files
    pure
        ( [SqlFile f (splitStatements c) | (f, Right c) <- fetched]
        , [f <> ": " <> e | (f, Left e) <- fetched, not ("not found" `T.isInfixOf` T.toLower e)]
        )

{- | Split SQL text into statements on top-level @;@, honouring @'…'@ strings, @--@ and
@/* */@ comments and @$tag$…$tag$@ bodies. Comment-only chunks are dropped.
-}
splitStatements :: Text -> [Text]
splitStatements = filter hasCode . map (T.strip . T.pack . reverse) . go [] . T.unpack
  where
    go acc [] = [acc | not (null acc)]
    go acc (';' : rest) = (';' : acc) : go [] rest
    go acc ('\'' : rest) = let (str, rest') = quoted rest in go (reverse ('\'' : str) ++ acc) rest'
    go acc ('-' : '-' : rest) = let (c, rest') = break (== '\n') rest in go (reverse ("--" ++ c) ++ acc) rest'
    go acc ('/' : '*' : rest) = let (c, rest') = blockEnd rest in go (reverse ("/*" ++ c) ++ acc) rest'
    go acc ('$' : rest)
        | Just (tag, rest') <- dollarTag rest =
            let open = '$' : tag ++ "$"
                (body, rest'') = untilTag open rest'
             in go (reverse (open ++ body) ++ acc) rest''
    go acc (c : rest) = go (c : acc) rest
    -- text after an opening quote up to and including the closing one ('' is an escaped quote)
    quoted ('\'' : '\'' : r) = let (s, r') = quoted r in ("''" ++ s, r')
    quoted ('\'' : r) = ("'", r)
    quoted (c : r) = let (s, r') = quoted r in (c : s, r')
    quoted [] = ([], [])
    blockEnd ('*' : '/' : r) = ("*/", r)
    blockEnd (c : r) = let (s, r') = blockEnd r in (c : s, r')
    blockEnd [] = ([], [])
    dollarTag r = case break (== '$') r of
        (tag, '$' : r') | all (\c -> isAlphaNum c || c == '_') tag -> Just (tag, r')
        _ -> Nothing
    untilTag open r = search r []
      where
        search [] acc = (reverse acc, [])
        search s@(c : cs) acc
            | open `isPrefix` s = (reverse acc ++ open, drop (length open) s)
            | otherwise = search cs (c : acc)
    isPrefix p s = take (length p) s == p
    hasCode t = not (T.null (T.strip (stripComments t)))
    stripComments = T.unlines . filter (not . T.isPrefixOf "--" . T.strip) . T.lines

-- | Does the statement name @schema.@ (also quoted @"schema".@) as a whole identifier?
mentionsSchema :: Text -> Text -> Bool
mentionsSchema schema stmt = any ok (T.breakOnAll needle low) || any okQ (T.breakOnAll ("\"" <> needle') low)
  where
    low = T.toLower stmt
    needle' = T.toLower schema <> "\"."
    needle = T.toLower schema <> "."
    ok (before, _) = T.null before || not (isIdent (T.last before))
    okQ _ = True
    isIdent c = isAlphaNum c || c == '_'

-- | Per file, the statements that name any of @schemas@ (files with none are omitted).
statementsFor :: [Text] -> [SqlFile] -> [SqlFile]
statementsFor schemas files =
    [ SqlFile (sfPath f) ss
    | f <- files
    , let ss = [s | s <- sfStatements f, any (`mentionsSchema` s) schemas]
    , not (null ss)
    ]

-- | Statements that name none of @known@ schemas, per file.
unattributed :: [Text] -> [SqlFile] -> [SqlFile]
unattributed known files =
    [ SqlFile (sfPath f) ss
    | f <- files
    , let ss = [s | s <- sfStatements f, not (any (`mentionsSchema` s) known)]
    , not (null ss)
    ]

countStatements :: [SqlFile] -> Int
countStatements = sum . map (length . sfStatements)

-- | One runnable file for a service.
renderSql :: Text -> Text -> [SqlFile] -> Text
renderSql title schemas files =
    T.unlines $
        ["-- " <> title, "-- Schemas: " <> schemas, "-- Run in order against the database that holds these schemas.", ""]
            ++ concat [["-- >>> " <> sfPath f] ++ concatMap (\s -> [ensureSemi s]) (sfStatements f) ++ [""] | f <- files]
  where
    ensureSemi s = if ";" `T.isSuffixOf` T.stripEnd s then s else s <> ";"
