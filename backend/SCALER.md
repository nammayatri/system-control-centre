# Capacity scaler

Scheduled capacity, and an editor for the autoscaler behind it, for **Memorystore for Valkey** instances and
**AlloyDB read pools**. It is the counterpart of the [HPA scheduler](HPA_SCHEDULER.md) for managed data stores:
same schedules (`ONCE` / `WEEKLY`), same lease + ledger design, same apply state machine. Lives inside the
Autopilot product (`src/Products/Autopilot/Scaler/`); UI at `/backend/scaler`.

## Why it exists

An autoscaler that resizes a cluster during traffic hurts: with no replicas, every resize stalls nodes while slots
migrate, and clients see pool-acquire timeouts, 5xx and disconnects. If the autoscaler also shrinks the cluster
overnight, the morning ramp triggers a series of resizes at the worst time. This tool lets you do the resize once, at
a quiet hour, stop the autoscaler from undoing it during the busy window, and change the autoscaler's own settings
from the console instead of editing a Cloud Scheduler payload by hand.

## Targets are registered in the console

Not in `deployment_config`, and not tied to a product. Two tables (migration `0060`):

| Table | Holds | Scales by |
|---|---|---|
| `redis_config` | a Valkey instance (project, location, instance, optional autoscaler job) | shards (`CLUSTER`) or replicas (`CLUSTER_DISABLED`, "standalone") |
| `db_config` | an AlloyDB read pool (project, location, cluster, read pool, optional autoscaler job) | nodes |

**Add target** takes a kind, project and location, can list what exists there to pick from, and reads the instance
live before saving. Only registered targets can be scheduled, resized, or have their autoscaler touched. A target in
use (live schedules, a change in flight) cannot be removed.

## The autoscaler editor

Each autoscaler is a Cloud Scheduler job whose payload (one entry per managed target) holds its settings and scaling
rules. For a target with an `autoscaler job`, the **Autoscaler** tab shows that entry and lets an admin change it:

* Whitelisted settings only, and only ones that already exist in the entry: Valkey `minSize`, `maxSize`,
  `scaleOutLimit`, `scaleInLimit`, the two cooling minutes, `minFreeMemoryPercent`, `scalingMethod`; AlloyDB
  `minNodeCount`, `maxNodeCount`, `stepSize`, the two cooling minutes. The entry's identity is never touched.
* The thresholds and comparison operators of the scaling rules (rules are validated structurally, so a typo cannot
  silently turn scaling off).
* An edit carries the payload it was made against; if the job changed in between it is refused, not overwritten.
* While a scheduled change holds the minimum, that one setting is read-only (everything else stays editable).
* Every change is read back, and recorded with both entries and who/why; any change can be **reverted** from the
  history. The job can be **paused** and **resumed** (a paused job makes no scaling decisions).

## What a scheduled apply does

1. **PENDING**: read the live target, check the guardrail, decide whether there is anything to do. Already at or above
   the target, with no scale-in block asked for, is `SKIPPED`.
2. **APPLYING**: save the original values once. If `blockScaleIn`, record the intent, then raise the autoscaler's
   minimum to the target BEFORE resizing, so it cannot scale in meanwhile. The payload is checked to be for this
   target (cluster, pool, project, region) first. Then start the resize.
3. **OBSERVING**: wait for the resize (minutes). A resize that finishes with an error is never retried blindly.
4. **APPLIED**: capacity in place; held until the window ends (or forever for a manual hold).
5. **RESTORING** (window end or "Restore now"): put the autoscaler's minimum back, but only if it still holds the value
   we wrote; a value anyone else set since is left alone and reported. Optionally shrink capacity back (`shrinkOnEnd`,
   off by default; with a deadline and a check for a failed shrink).
6. **ROLLING_BACK** (guardrail freeze, manual rollback, "give up", deleting the schedule, or any failure after the
   autoscaler was pinned): same as restoring the autoscaler, but it never takes capacity away.

Capacity only ever goes **up** at the start of a window. Every write to Google Cloud is made only while the worker
still holds its lease.

## Turning it on

| Env var | Default | Effect |
|---|---|---|
| `SC_SCALER_SCHEDULER_ENABLED` | **off** | Reconciler + apply workers. This is the part that writes to Google Cloud for schedules. |
| `SC_GCP_ACCESS_TOKEN` | unset | Local development only: a bearer token to use instead of the metadata server. |

The HTTP API, including the autoscaler editor, works without the flag (it only needs Google access). Loops start in
`SERVER` and `RUNNER` modes next to the HPA loops and are safe on several pods.

### Google Cloud access

No `gcloud` in the image: the pod's workload identity supplies a token from the metadata server. The service account
needs: `memorystore.instances.get/list/update` and `memorystore.operations.get` (Valkey);
`alloydb.instances.get/list/update` and `alloydb.operations.get` (read pools); and
`cloudscheduler.jobs.get/update/pause/enable` for autoscaler jobs.

## Permissions

The HPA permissions, used globally (not per product): `HPA_VIEW` (read, preview), `HPA_SCHEDULE_EDIT`, `HPA_APPLY`
(scale now, restore early), `HPA_ROLLBACK` (rollback, cancel, give up), and `HPA_GUARDRAIL_EDIT` (Admin only:
register / edit / remove targets, guardrails, edit / revert / pause an autoscaler).

## Tests

* Unit (pure): `cabal test scc-test`, section [75].
* Integration (real Postgres, fake Google Cloud, kills the worker at awkward moments):
  `SC_SCALER_IT_DB=postgres://…/system_control cabal test scc-scaler-it` (skips when the var is unset).

## Not covered / to know

* Verified against an in-memory fake of the Google APIs, not real Memorystore, AlloyDB or Cloud Scheduler. Try a
  sandbox target first.
* Machine size / node type is not handled; only shards, replicas and read-pool nodes.
* A resize still stalls clients for its duration. This tool moves it to a quiet hour; it does not make it free.
* In `ny-prod` the AlloyDB poller job (`poll-alloydb-readpool-metrics`) is **paused** and its payload names a cluster
  that does not exist (`atlas-driver-v1-alloydb-cluster`); registering a read pool with that job is refused until the
  payload is fixed. A read pool can still be scheduled without an autoscaler job.
* Time zones are fixed UTC offsets (no DST database), as in the HPA scheduler. Recovery after a hard process kill
  takes up to the lease length (90 s).
