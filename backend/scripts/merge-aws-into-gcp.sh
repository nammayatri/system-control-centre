#!/usr/bin/env bash
# ==============================================================================
# Merge the AWS system-control database into the GCP one.
#
# Copies release_tracker, release_events and deployment_config from AWS into
# GCP. AWS rows arrive tagged cloud_type='AWS'; GCP's existing rows are already
# 'GCP' from the migrations. Both sets then coexist in one database.
#
# ORDER MATTERS. Run migrations 0045 + 0046 on BOTH databases first, with each
# database told which cloud it is:
#
#     -- on the AWS database, BEFORE its migrations:
#     ALTER DATABASE <awsdb> SET scc.cloud_type = 'AWS';
#
# The migrations then tag every existing row on each side correctly, so this
# script is a straight copy and never has to guess a row's cloud. Running it
# against an AWS database that has not been migrated will abort (see checks).
#
# Also deploy the cloud_type-aware build to BOTH instances before merging. An
# older binary writes rows with no cloud tag, and an untagged cluster-bound row
# is visible to every instance — both runners would drive it.
#
# Usage:
#   AWS_URL=postgres://...aws...  GCP_URL=postgres://...gcp...  \
#     bash scripts/merge-aws-into-gcp.sh
#
# Idempotent: re-running inserts nothing new (release_tracker is guarded by its
# primary key; the staging schema is rebuilt each run).
# ==============================================================================
set -euo pipefail

: "${AWS_URL:?set AWS_URL to the aws_krukshetra database}"
: "${GCP_URL:?set GCP_URL to the target GCP database}"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

aws_psql() { psql "$AWS_URL" -qtAX "$@"; }
gcp_psql() { psql "$GCP_URL" -qtAX "$@"; }

echo "=== Preflight ==="

# Both sides must already carry cloud_type, or the copy would silently produce
# untagged rows.
for pair in "AWS:$AWS_URL" "GCP:$GCP_URL"; do
  name="${pair%%:*}"; url="${pair#*:}"
  for tbl in release_tracker deployment_config; do
    has=$(psql "$url" -qtAX -c "SELECT count(*) FROM information_schema.columns WHERE table_name='$tbl' AND column_name='cloud_type';")
    if [ "$has" != "1" ]; then
      echo "ABORT: $name.$tbl has no cloud_type column. Run migrations 0045 and 0046 there first." >&2
      exit 1
    fi
  done
done

# The AWS side must be tagged AWS, not left at the GCP default.
aws_tags=$(aws_psql -c "SELECT DISTINCT COALESCE(cloud_type,'<null>') FROM deployment_config ORDER BY 1;")
echo "  AWS deployment_config cloud_type values: $(echo "$aws_tags" | tr '\n' ' ')"
if echo "$aws_tags" | grep -qx "GCP"; then
  echo "ABORT: AWS database has rows tagged 'GCP'. It was migrated without" >&2
  echo "       ALTER DATABASE ... SET scc.cloud_type = 'AWS'. Fix the tags first." >&2
  exit 1
fi

gcp_psql -c "SELECT 'GCP rows before: release_tracker=' || (SELECT count(*) FROM release_tracker) || ' deployment_config=' || (SELECT count(*) FROM deployment_config);"

echo "=== Exporting from AWS ==="
aws_psql -c "\copy (SELECT * FROM release_tracker)    TO '$WORK/release_tracker.csv'    CSV HEADER"
aws_psql -c "\copy (SELECT * FROM release_events)     TO '$WORK/release_events.csv'     CSV HEADER"
aws_psql -c "\copy (SELECT * FROM deployment_config)  TO '$WORK/deployment_config.csv'  CSV HEADER"
wc -l "$WORK"/*.csv

echo "=== Loading into GCP staging schema ==="
gcp_psql -v ON_ERROR_STOP=1 <<'SQL'
DROP SCHEMA IF EXISTS aws_import CASCADE;
CREATE SCHEMA aws_import;
CREATE TABLE aws_import.release_tracker   (LIKE public.release_tracker);
CREATE TABLE aws_import.release_events    (LIKE public.release_events);
CREATE TABLE aws_import.deployment_config (LIKE public.deployment_config);
SQL

gcp_psql -c "\copy aws_import.release_tracker   FROM '$WORK/release_tracker.csv'   CSV HEADER"
gcp_psql -c "\copy aws_import.release_events    FROM '$WORK/release_events.csv'    CSV HEADER"
gcp_psql -c "\copy aws_import.deployment_config FROM '$WORK/deployment_config.csv' CSV HEADER"

echo "=== Merging ==="
# Column lists are built from information_schema rather than hardcoded, so this
# survives schema drift and cannot silently mis-map a column.
#
# release_tracker keeps its id (TEXT uuid, no collision across databases).
# deployment_config and release_events DROP their id: both are SERIAL and their
# values collide between the two databases. Nothing references
# deployment_config.id across databases, and release_events links by
# re_release_id, so regenerating them is safe.
gcp_psql -v ON_ERROR_STOP=1 <<'SQL'
BEGIN;

INSERT INTO public.release_tracker
SELECT * FROM aws_import.release_tracker
ON CONFLICT (id) DO NOTHING;

DO $$
DECLARE cols text;
BEGIN
    SELECT string_agg(quote_ident(column_name), ', ' ORDER BY ordinal_position)
      INTO cols
      FROM information_schema.columns
     WHERE table_schema='public' AND table_name='release_events' AND column_name <> 're_id';
    EXECUTE format('INSERT INTO public.release_events (%s) SELECT %s FROM aws_import.release_events', cols, cols);

    SELECT string_agg(quote_ident(column_name), ', ' ORDER BY ordinal_position)
      INTO cols
      FROM information_schema.columns
     WHERE table_schema='public' AND table_name='deployment_config' AND column_name <> 'id';
    EXECUTE format(
      'INSERT INTO public.deployment_config (%s) SELECT %s FROM aws_import.deployment_config
       ON CONFLICT (app_group, COALESCE(service, %L), cloud_type) DO NOTHING', cols, cols, '');
END
$$;

-- Independent runtime state must not carry over from the other database's
-- snapshot: a lock or an in-flight mutex held at dump time would arrive stuck.
UPDATE public.deployment_config
   SET vs_locked_by = NULL, vs_lock_timestamp = NULL,
       service_state = 'AVAILABLE'
 WHERE cloud_type = 'AWS';

COMMIT;
SQL

echo "=== Result ==="
gcp_psql -c "
SELECT 'release_tracker' AS tbl, COALESCE(cloud_type,'<null: mobile>') AS cloud, count(*)
  FROM release_tracker GROUP BY 1,2
UNION ALL
SELECT 'deployment_config', cloud_type, count(*)
  FROM deployment_config GROUP BY 1,2
ORDER BY 1,2;"

echo
echo "Staging schema aws_import left in place for inspection."
echo "Drop it once verified:  DROP SCHEMA aws_import CASCADE;"
echo
echo "NOT handled by this script — decide before pointing AWS at this database:"
echo "  * RBAC (sc_person and friends): the same person has DIFFERENT uuids in"
echo "    each database, and five FK columns reference sc_person(id). Merging"
echo "    needs an email-keyed remap, not a copy."
echo "  * server_config: deliberately has no cloud_type. Reconcile by hand if"
echo "    the two sides diverged."
echo "  * Mobile rows arrive with cloud_type NULL (global) and are therefore"
echo "    visible to BOTH runners. Elect a single mobile driver first or the"
echo "    same build dispatches twice."
