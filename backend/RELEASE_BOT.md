# Xyne release bot

`@system-control-center-bot release rider app and driver app till e4e0b16` in an
allow-listed Xyne channel → analysis → Jenkins build → (approval) → config applied via
SCC trackers → release trackers created.

Code: `src/Products/Autopilot/ReleaseBot/` (+ `ProdRelease/` for config/GitHub/Jenkins/intent).
Public page: `frontend/src/core/public/ReleaseRequestPublic.tsx` (`/r/:id`).
Table: `release_request` (migration `0053`).

## Flow

1. **Webhook** `POST /xyne/events` (HMAC `x-xyne-signature`, verified on the raw body). Mentions and
   Approve/Reject clicks both arrive here; `/xyne/interactions` accepts the Slack-style click shape.
2. **Gates** (all must pass, else the request is `DENIED`/`INFO_ONLY` and nothing runs):
   channel is in `channels` · sender's Xyne email maps to an active `sc_person` holding
   `RELEASE_CREATE` · repo/branch/commit/services parse and exist · commit is on the branch.
3. **Intent**: the LLM (Grid, same `ai_*` config as release summaries) only *extracts*
   `{branch, commit, services}`; every value is validated against the config JSON. If AI is off or
   fails, a keyword parser takes over. The LLM never decides what is applied.
4. **Analysis** (deterministic, fail-closed): per service, diff *deployed commit → requested commit*;
   flag changed secret files; diff the live configmap(s) and the live `DHALL_CONFIG` env
   (**base64-decoded** both sides) against the files at the commit.
5. **Build**: Jenkins job is triggered immediately (a build is inert).
6. **No config change** → tracker(s) created when the build succeeds.
   **Config change** → an Approve/Reject card is posted with a no-VPN diff link.
   **Any blocker** (can't verify something) → build only, no tracker, reason posted.
7. **Approval**: approver needs `RELEASE_APPROVE` (the requester may approve their own release if they hold it). After the build, a second **Approve & start rollout / Discard release** card approves or discards the created trackers.
8. **Apply** after approval *and* a successful build: re-verifies, then creates a `BackendConfig`
   tracker per changed configmap — **unapproved**, one at a time, stopping at the first failure (so a
   partial failure applies nothing). Once SCC's AI config review has settled, the bot approves each through
   the normal update path *as the approver* (needs `RELEASE_UPDATE`), so the AI breaking-change gate is
   honoured, never bypassed; if it refuses (or the approver lacks the permission) the bot says so and a
   human approves in SCC. When all configmap trackers COMPLETE, it creates the `BackendService`
   tracker(s) with `envOverrideData` (**unapproved** — the rollout is approved in SCC as usual).

## Safety properties

- Nothing is applied without an authorised human approving *that exact diff*: a content hash fixed at
  approval and a live-state fingerprint are both re-checked right before applying. Any drift aborts
  the apply with no writes.
- Config goes through SCC trackers, never direct `kubectl patch` (keeps staged rollout, health gates,
  audit, revert). `envOverrideData` **replaces the whole container env**, so the bot sends the live env
  array with only `DHALL_CONFIG` swapped (`valueFrom` entries preserved; it refuses to invent a missing
  var or overwrite a `valueFrom` one).
- Every state change is compare-and-set → replicated workers can't double-apply; approval has exactly one
  winner; webhook retries dedupe on the Xyne message id; tracker creation is idempotent (`globalId`).
- Secret-file changes are **flagged** (thread + page), never read or applied by the bot.
- The public page is read-only, token-gated, and the API strips apply payloads (base64 values, raw
  configmap data, fingerprints) before serving.

## Credentials — what already exists, what is new

Checked against the `scc-backend` secret (key NAMES only) in `ny-prod` and `ny-sandbox`:

| Need | Reuses | Status |
|---|---|---|
| Post as the bot | `SLACK_BOT_TOKEN` + `SLACK_API_BASE_URL` (what `Notifications.hs` already posts with; the base URL is the Slack-compatible gateway, i.e. Xyne) | **already in both secrets** — falls back automatically; `SC_XYNE_BOT_TOKEN` / `SC_XYNE_BASE_URL` override |
| Read the repo (compare, files) | GitHub App: `SC_GITHUB_APP_ID`, `SC_GITHUB_APP_INSTALLATION_ID`, `SC_GITHUB_APP_PRIVATE_KEY_B64` | **already in both** — the App installation must cover `nammayatri/nammayatri` with *Contents: read*; `SC_GITHUB_TOKEN` (PAT) overrides |
| AI intent parsing | `SC_AI_API_KEY` + `ai_*` server_config | already in both |
| Verify inbound webhooks | `SC_XYNE_SIGNING_SECRET` | **NEW** — issued by Xyne when the app's webhook URL is set; add to the secret |
| Trigger Jenkins | `SC_JENKINS_URL`, `SC_JENKINS_USER`, `SC_JENKINS_TOKEN`, `SC_JENKINS_WEB_URL` | **NEW** — not in either secret. `SC_JENKINS_URL` differs per cluster; see "Jenkins" below. |
| Sign no-VPN links | `SC_RELEASE_BOT_LINK_SECRET`, `SC_PUBLIC_BASE_URL` | **NEW** (generate a random secret) |

## Setup

Run migrations `0053` and `0054`, then set (env only — nothing secret lives in the DB or repo):

| Var | Purpose |
|---|---|
| `SC_RELEASE_BOT_ENABLED=true` | Master switch. Off ⇒ routes 404, worker idle. |
| `SC_RELEASE_BOT_DRY_RUN=true` | Analyze + post, but no Jenkins/trackers/apply. **Start here.** |
| `SC_PROD_RELEASE_CONFIG` | Path to the fallback config JSON (default `./dhall-configs/prod-release-config.json`). |
| `SC_RELEASE_BOT_TTL_MINUTES` | Approval window (default 120). |

## Jenkins

The Jenkins the `cloud-jenkins` job lives on runs **in the ny-prod cluster** (namespace `jenkins`, Service `jenkins`, 8080;
Jenkins 2.541.1). Pick `SC_JENKINS_URL` by where the bot's SCC runs — do not route prod through the SSO front door:

| SCC instance | `SC_JENKINS_URL` | Why |
|---|---|---|
| **ny-prod** (the one to run the bot on) | `http://jenkins.jenkins.svc.cluster.local:8080` | In-cluster Service. Verified from the prod scc-backend pod: same instance (version + session id match the one reached via the proxy host). No Pomerium, no allowlist. |
| ny-sandbox (MASTER-env releases) | `https://mcp-jenkins.c2.sso.internal.svc.movingtech.net` | Verified reachable from the sandbox pod. Do NOT use the sandbox's own `jenkins-service` (an older, separate Jenkins 2.580.1). |
| mti-eu-prod | n/a | No Jenkins in that cluster, and the proxy host is blocked from it (bare 403, even with valid credentials). Don't run the bot there: one build on the ny-prod Jenkins pushes to EU via `EU_PROD` / `EU_PROD_GCP`. |

Other facts (checked read-only):

- **Auth:** HTTP Basic, `user:API-token` (no CSRF crumb needed with a token). Without credentials Jenkins answers 403.
- **Link host:** Jenkins reports queue/build URLs on `https://jenkins.c2.sso.internal.svc.movingtech.net` (SSO-fronted; rejects API
  calls). The bot re-roots every polled URL onto `SC_JENKINS_URL`, and shows people `SC_JENKINS_WEB_URL`
  (set it to that `jenkins.c2.sso…` host so the links open in a browser).
- **Job:** `ny-internal/cloud-jenkins/main` (GitHub org folder `ny-internal` → repo `cloud-jenkins` → branch `main`).
- **Parameters:** `commit` (first **6** chars — used verbatim as the image tag, so the bot sends exactly 6 and it
  matches the version SCC records), `SERVICE` (`nammayatri` | `location-tracking-service` | `notification-service` | `byte`),
  and booleans `GCP_SANDBOX`, `AWS_PROD`, `GCP_PROD`, `EU_PROD`, `EU_PROD_GCP`, `MSIL`. **The defaults push to the
  sandbox AND both prod clouds**, so the config sets every one explicitly:
  PROD = `GCP_SANDBOX=false, AWS_PROD=true, GCP_PROD=true`, EU/MSIL `false` (exactly what a real recent run, build #4957,
  used). MASTER = `GCP_SANDBOX=true`, the rest `false`. Jenkins settings are **per env** (`jenkinsByEnv` in the file
  config; on rows they come from each app group's own `env`).
- A build takes ~10 minutes; the worker polls every 20 s. The trigger is
  `POST …/job/ny-internal/job/cloud-jenkins/job/main/buildWithParameters`.

## Tagging the bot and the callback URL

The bot is a Xyne app. Two things are configured **in the Xyne app settings** (not in the cluster):

1. **Event/webhook URL** → `https://<public-api-host>/xyne/events`. Xyne POSTs here, signed with
   `x-xyne-signature` = hex HMAC-SHA256 of the raw body using the app's *signing secret*
   (put that in `SC_XYNE_SIGNING_SECRET`). Subscribe the app to mention events (`APP_MENTIONED`).
2. **Interactive-component URL** (only if the app has a separate field for it) → `/xyne/interactions`.
   Approve/Reject button clicks normally arrive on the same events URL as a `flow_action`; both are handled.

How a tag works: someone writes `@system-control-center-bot release …` in a channel the app is in. Xyne sends
`APP_MENTIONED` with `channelId`, `userId`, `senderName`, `cleanContent`, and the mentioned user ids as
`data-user-id` spans in `content`. Because a webhook URL can be shared with other apps, the bot only reacts if
**its own id** (`auth.test`) is among the mentioned ids. The bot must be a member of the channel, and the app
needs the scopes to post (`chat:write`) and look users up (`users:read[.email]`) — without the email the sender
cannot be matched to an SCC account and is denied.

Known Xyne quirk: the webhook's message ids can't be used as a thread id, so the first reply is a top-level
post and later replies thread under *that* one.

### Public (no-VPN) exposure — expose only these

- API host: `GET /public/release-requests/*`, `POST /xyne/events`, `POST /xyne/interactions`
- Frontend host: `/r/*` and `/assets/*`; set `VITE_API_BASE_URL` (runtime `window.__ENV__`) to the public API host.

Everything else stays on the VPN. Put rate limiting on the public host.

### Config: where it lives

**Primary: on the deployment config rows** (migration `0054`, column `deployment_config.release_bot_config`,
JSON text like `rollout_strategy`). Edit it in **Deployment Config → app group / service → "Release bot
rules (JSON)"**; each rule sits next to the thing it is about. Saving validates the JSON (a bad value is
rejected); leaving the field untouched keeps what is stored, clearing the box clears it. The existing UI
saves are delete+insert on the row, so the rules are explicitly carried across — verified against Postgres.

*App group row* (`service IS NULL`; the GitHub repo is the row's existing **GitHub Repo** field):

```json
{
  "env": "PROD",
  "branches": ["prodHotPush-Common"],
  "channels": ["<xyne channel id>"],
  "jenkins": { "job": "nammayatri/cloud-jenkins/main", "commitParam": "COMMIT", "fixedParams": {} },
  "secretFiles": ["*secret*"],
  "configMaps": [ { "name": "beckn-production-pilot", "files": { "common.dhall": "<repo path>/common.dhall" } } ],
  "ignoreConfigMaps": []
}
```

*Service row*:

```json
{
  "aliases": ["rider app", "backend"],
  "dhallFiles": ["rider-app.dhall"],
  "envVar": { "envVar": "DHALL_CONFIG", "repoPath": "<repo path>/rider-app.dhall", "watch": [] },
  "defaultRollout": [{ "rolloutPercent": 100, "cooloffMinutes": 0, "podCount": 1 }]
}
```

The service inherits `env` from its app group (override with `"env"` in the service JSON). Several app groups
may share one repo: branches, secret patterns, configmaps and channels are merged; they must agree on the
Jenkins job and a channel can map to only one repo/env — a conflict is reported as an error naming the rows,
never silently resolved.

**Fallbacks (first hit wins, an invalid source is an error, never a silent fall-through):**
1. any deployment config row with rules → built from the rows;
2. the `release_bot_config_json` row in `server_config` (one blob for the whole bot);
3. the JSON file (`dhall-configs/prod-release-config.json`, `SC_PROD_RELEASE_CONFIG`).

### The rules

**Rules** — a *changed file triggers its check* (it does not blindly compare everything):

| In the config | Meaning |
|---|---|
| `channels[]` | Xyne channel id → repo + env (`PROD`/`MASTER`). A channel only sees that env's services. |
| `repos[].branches` | Allowed release branches (the commit must be on one). |
| `services[].dhallFiles` | Files whose change makes the service "dhall-affected". |
| `services[].envVar {envVar, repoPath, watch?, mode?}` | If a **watched** file changed (default: `repoPath`) → decode the live `envVar` on the running deployment and diff it against `repoPath` at the commit. `"mode": "merge"` (see configMaps) applies only the repo change onto the live value instead of replacing it — use whenever the live value is an env-specific variant of the repo file (true for prod `DHALL_CONFIG`: ~23% line-similar to the repo's dev file). |
| `configMaps[] {name, files{key→repoPath}, mode?}` | If a file in `files` changed → diff that key of the live configmap against the repo file at the commit (`mode` omitted / `"replace"`: the live key is replaced by the repo file — use where the repo file IS the deployed config). `"mode": "merge"`: the live content is an env-specific variant of the repo file (e.g. the MASTER configmap), so only the repo change (deployed commit → target commit) is applied onto it as a 3-way line merge; an overlap with live edits is a conflict → build-only + flagged, never guessed. Needs all selected services on the same deployed commit. |
| `requireChecks` (app group; default false) / `ignoreChecks[]` | Gate the Jenkins build on the commit's GitHub CI: every check run and commit status must pass. Pending checks park the request in `WAITING_CHECKS` (re-checked every 20 s, gives up after 90 min); a failed one stops it with the failing check names; if GitHub can't be read the build is NOT started. `ignoreChecks` = names (substring, case-insensitive) that never gate. The GitHub App needs read access to checks and commit statuses. |
| `secretFiles` | Changed secret files are flagged in the thread (never read/applied). |
| `ignoreConfigMaps` | Extra configmaps to exclude from coverage (`kube-root-ca.crt`, `istio-ca-root-cert` always are). |
| _service rule_ `sqlSchemas[]` | Database schemas the service uses (e.g. `["atlas_app"]`). Every changed `.sql` file of the release is split into statements; the ones that name one of the service's schemas (`atlas_app.table`) are posted for that service BEFORE its tracker is created (inline if short, plus a downloadable file at `/api/public/release-requests/<id>/sql?s=<service>&t=…`). Statements naming no configured schema are flagged, never dropped. |
| _service rule_ `branches[]` | Branches THIS service releases from, as many as you like (e.g. `["prodHotPush-Frontend", "main"]`). If the message names a branch it must be one of them; if not, the first listed branch that contains the commit is used. Services selected together must share at least one branch, otherwise release them in separate requests. Empty = the app group's branches. |
| _service rule_ `jenkins {job?, commitParam?, commitPrefix?, commitLength?, fixedParams?}` | The service's OWN Jenkins settings, laid over the app group's (so one repo can build different services with different jobs/flags). The app group may omit `jenkins` entirely if every service sets its `job`. Services with the same job and parameters share one build. |
| _service rule_ `jenkinsParams` | Extra Jenkins parameters for this service's build (e.g. `{"app":"control-center-frontend"}`), merged over the group's `fixedParams`. Services with identical parameters share one build; different ones get separate builds, and the release proceeds only when ALL succeed. |
| `jenkins.commitParam` (optional) | Omit it for a job that takes no commit parameter (it always builds the branch head). The bot then only releases the branch's CURRENT head commit and refuses any other. Already-built heads are found by the commit Jenkins checked out. |
| `channels[]` | A channel may be listed on several repos' app groups; the bot picks the repo from the message (repo name, service name or alias — the longest mention wins) and asks if it can't tell. The same channel with two different envs for one repo is an error. |

If the commit diff can't be fully verified, **every** rule is treated as triggered (fail safe).
A changed dhall file that **no rule watches** is a blocker (build-only).

**Coverage ("did you check everything it references?"):** for each selected service the bot reads the
*running* deployment and lists every configmap it references (env `valueFrom`, `envFrom`, volumes, projected,
init containers) and every secret **name** (values are never read). Each configmap is reported as
`changed` / `unchanged` / `not affected` / **`NOT checked`** (no rule covers it). The approval card and the
public page show this checklist with an overall *complete / INCOMPLETE* flag so the approver knows what was
and wasn't reviewed. Incomplete coverage warns; it does not block (the approver decides).

See `dhall-configs/prod-release-config.json`. **Values starting `REPLACE_` must be filled in** (Xyne channel
ids, repo paths of the dhall files). `secretFiles` patterns use `*`; a pattern without `/` matches the file
name anywhere. Services/configmaps can be scoped with `"env": "PROD"|"MASTER"`.

## Not verified here (needs the real systems)

Verified: diff engine, base64 fail-closed, signature, payload parsing, secret patterns, public-view
redaction, env replacement, config parsing, deployment-reference discovery, mention-id parsing, file triggers
(unit tests `[55]–[64]`); the deployment-config-row path — rules set, then preserved across a real
UI-style re-save of both app group and service rows, built into the bot config, and cleared — run against a real
Postgres; the SQL store against real
Postgres (dedupe, CAS, single approval winner, expiry, once-only latch); the GitHub client against the
real repo; frontend typecheck + build.

**Not** exercised: that the GitHub App installation can read `nammayatri/nammayatri` (needs the secret values), live Xyne API calls and card rendering (shapes copied from Vishwakarma's confirmed
integration), the Jenkins *trigger* (never fired — it would start a real prod build; the job, parameters, auth and reachability were verified read-only, polling logic was not run end-to-end), `kubectl` reads, and
the `createConfigMapH` / `createReleaseH` hand-off against a real cluster. Hence: run with
`SC_RELEASE_BOT_DRY_RUN=true` first, then a low-risk service.

## Assumptions to confirm

- The live `DHALL_CONFIG` value is the raw service dhall, base64-encoded. If it is instead a resolved
  expression, the diff will show everything as changed — the apply step would need that same render step.
- The deployment env var name (`DHALL_CONFIG`) and repo paths of the dhall files.
