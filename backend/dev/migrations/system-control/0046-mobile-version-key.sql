-- Version-first comparator for mobile slot convergence, shared by the
-- convergence SQL in Queries/Supersession.hs and the operator inspect script.
-- MUST match StoreSync.versionOlderThan exactly: split on '.', each segment
-- parses as a whole number or reads 0 (so '3.3.16-beta' = {3,3,0}, like the
-- Haskell readMaybe fallback). Postgres array comparison is elementwise with
-- shorter-is-less on equal prefixes, matching Haskell list Ord.
-- Single-quoted body (not $$): prod is hand-applied via Cloud SQL Studio,
-- whose statement splitter cannot lex dollar-quoted strings ("unterminated
-- dollar-quoted string"). ''[^0-9]'' non-empty check == the old ^[0-9]+$ regex.
CREATE OR REPLACE FUNCTION mobile_version_key(v text) RETURNS bigint[]
LANGUAGE sql IMMUTABLE STRICT AS
'SELECT COALESCE(
   array_agg(CASE WHEN t.s <> '''' AND t.s !~ ''[^0-9]'' THEN t.s::bigint ELSE 0 END ORDER BY t.ord),
   ARRAY[]::bigint[])
 FROM unnest(string_to_array(v, ''.'')) WITH ORDINALITY AS t(s, ord)';

