# HPA scheduler

Time-based changes to HPAs (replica bounds, cpu/memory/custom metric targets, scale-up/down behaviour) for a
service, with automatic restore, verification, health-gated rollback and a full audit trail. Lives inside the
Autopilot product (`src/Products/Autopilot/Hpa/`); UI at `/backend/hpa`.

## Turning it on

| Env var | Default | Effect |
|---|---|---|
| `SC_HPA_SCHEDULER_ENABLED` | **off** | Reconciler + apply workers. This is the part that writes to clusters. |
| `SC_HPA_OBSERVER_ENABLED` | on | Read-only recorder of *spec changes* (a row only when an HPA's spec differs from the last one seen, checked every 5 min). Writes no time series. |
| `PROMETHEUS_URL` | unset | Metrics endpoint (Prometheus-compatible) used for the replica/CPU history chart. Unset = the page shows live numbers only. |

Loops start in `SERVER` and `RUNNER` modes, are supervised (a crash restarts them) and are safe on several pods:
the reconciler/observer elect a leader through `hpa_loop_lease`; workers claim rows with leases. Apply migration
`dev/migrations/system-control/0055-hpa-scheduler.sql`. Uses the process's kubectl (`SC_KUBECTL_BIN`) and
`PROMETHEUS_URL` (history chart, optional health checks).

## How it works

* **Which HPA?** Resolved at apply time (`Resolver.hs`): the HPA(s) whose version the VirtualService sends
  traffic to. A schedule names a *service*, so a release that swaps HPAs does not strand it; the change follows
  the serving HPA. Two HPAs, KEDA-managed or v1-shaped HPAs are shown and handled (KEDA/v1 are never edited).
* **Level-triggered** (`Reconcile.hs`): each tick asks "is a window open, and does every serving HPA have an
  apply?" Downtime cannot lose a window. Each apply row carries its own `window_end`, so restore happens even
  if the schedule was edited or deleted.
* **Ledger** (`hpa_apply`): the only state. Worker holds a lease + heartbeat; a dead worker's lease expires and any
  pod resumes. Each step decides from the live cluster (`decideApplyAction`, `planRestore`), never from memory.
  The original spec is saved once, before the first change. One in-flight apply per HPA and one apply per
  schedule window are enforced by unique indexes.
* **Safe edits** (`Change.hs`): the live object is edited in place by metric key and replaced with its
  `resourceVersion` (409 on concurrent edit). `spec.metrics` is never sent as a partial list. Quantities compare by
  value (`500m == 0.5`, `1Gi == 1024Mi`, `1G != 1Gi`). Percent (`Utilization`) is only valid for cpu/memory.
* **Restore** puts back only fields that still hold the value we wrote; fields someone else changed are left alone
  and reported.
* **Health gate** (`Health.hs`): after a change, watch unready pods, `ScalingActive=False`, optional Prometheus
  checks; an issue must persist for the grace period before it triggers rollback.
* **Releases**: applies/restores are deferred while a release is in flight for the service. A release that clones
  a boosted HPA copies the *baseline* (annotation `sc.juspay.in/hpa-base-spec`, see `K8s/HPA.hs`).
* **Guardrails**: per-service max cap, min floor, max step %, freeze.

## Metrics and storage (nothing per-minute is stored)

* **History chart** (`Hpa/Metrics.hs`): queried on demand from `PROMETHEUS_URL` (`query_range`), never stored.
  Uses kube-state-metrics `kube_horizontalpodautoscaler_{status_current,status_desired,spec_min,spec_max}_replicas`
  (label `horizontalpodautoscaler`, falling back to `hpa`) and cAdvisor CPU over
  `kube_pod_container_resource_requests` for the HPA's Deployment pods. If kube-state-metrics does not export the HPA
  series at all (as in the ny-prod VictoriaMetrics), the pod count falls back to the Deployment's own
  `kube_deployment_status_replicas_ready` (running) and `kube_deployment_spec_replicas` (wanted), with no min/max lines.
  **Check these metric names exist in your Prometheus.**
* **Live numbers** (pods now / wanted / min / max / CPU / memory) come from the HPA status on every page refresh.
* **Scale events** are read live from Kubernetes events (the cluster keeps about an hour).
* The only things written to the database are: schedules, the apply ledger + its timeline, guardrails, and spec snapshots
  (on change only). `hpa_sample`, `hpa_scale_event` and `hpa_watch` exist from migration 0055 but are no longer written.

## Permissions (Autopilot product, scoped per app group)

`HPA_VIEW` (Viewer+), `HPA_SCHEDULE_EDIT`, `HPA_APPLY`, `HPA_ROLLBACK` (Manager+), `HPA_GUARDRAIL_EDIT` (Admin only).

## Tests

* Unit (pure): `cabal test scc-test` — sections [66]–[72].
* Integration (real Postgres, fake cluster, kills workers at every step):
  `SC_HPA_IT_DB=postgres://…/system_control cabal test scc-hpa-it` (skips when the var is unset).

## Not covered / to know

* A "hold until I restore it" one-off never expires: it keeps following the serving HPA across releases, and deleting it
  restores the original values (that is what delete means for any schedule).
* Time zones are fixed UTC offsets (no DST database).
* Recovery after a hard process kill takes up to the lease length (90 s).
* Verified against a fake kubectl and local Postgres; try a non-critical service on a real cluster first.
