# KubeBlocks compatibility

The addon is developed and tested against **exactly one** KubeBlocks version at a
time. Everything below is measured rather than inferred: each claim has a way to
re-check it at the bottom of this file.

| | |
|---|---|
| Supported KubeBlocks version | `1.2.0-alpha.1` |
| Where it is pinned | [e2e/setup/kb-cluster.sh](e2e/setup/kb-cluster.sh) (`KB_VERSION`), [.github/workflows/e2e-falkordb.yml](../../.github/workflows/e2e-falkordb.yml) (`E2E_KB_VERSION`) |
| Current chart version | `1.6.6` |

`Chart.yaml` advertises `addon.kubeblocks.io/kubeblocks-version: ">=1.2.0"`. That
is both wider and narrower than what is measured: it admits `1.2.0` releases
nobody has run the suite against, and it excludes `1.0.2` and `1.1.0-beta.9`,
which pass. Two of the three versions this file calls good therefore need
`kbcli addon install --force` (or `helm install` directly, which does not read
the annotation at all). The constraint has been left alone rather than widened
because a range that admits a pre-release has to spell that out — `>=1.0.2`
alone does not match `1.1.0-beta.9` under semver — and getting it wrong fails
closed at install time. Tighten it to a single tested range once a stable
KubeBlocks release passes the suite end to end.

## Feature matrix

Rows are the capability a user actually asks for, not the API that implements it.
`Yes` means covered by a passing e2e scenario on that version. `?` means untested,
which is not the same as working — run the CI matrix against that version to fill
the cell in, see [Testing another version](#testing-another-version).

`1.0.2` is the last stable KubeBlocks release; everything after it on the 1.1 and
1.2 lines is a pre-release. The addon is pinned to `1.2.0-alpha.1`.

| Feature | 1.0.2 | 1.1.0-beta.9 | 1.2.0-alpha.1 | 1.2.0-alpha.2 | 1.2.0-alpha.3 | e2e |
|---|---|---|---|---|---|---|
| Standalone cluster | Yes | Yes | Yes | Yes | Yes | 04 |
| Replication cluster (with Sentinel) | Yes | Yes | Yes | Yes | Yes | 01, 11 |
| Sharded cluster | Yes | Yes | Yes | Yes | Yes | 03 |
| Switchover | Yes | Yes | Yes | Yes | Yes | 02 |
| Automatic failover, replication | Yes | Yes | Yes | Yes | Yes | 06 |
| Automatic failover, sharded | Yes | Yes | Yes | Yes | Yes | 23 |
| Self-healing, sharded | Yes | Yes | Yes | Yes | Yes | 08 |
| Horizontal scaling, replication | Yes | Yes | Yes | Yes | Yes | 01, 15 |
| Horizontal scaling, sharded (reshard) | Yes, needs `legacyShardingPreTerminate=true` — B5 | Yes | Yes | Yes | Yes | 03 |
| Vertical scaling | Yes | Yes | Yes | Yes | Yes | 07 |
| Volume expansion | Yes | Yes | Yes | Yes | Yes | 26 |
| Restart | Yes | Yes | Yes | Yes | Yes | 07 |
| Stop / start | Yes | Yes | Yes | Yes | Yes | 16 |
| Reconfigure | Yes | Yes | Yes | Yes | Yes | 10 |
| Minor version upgrade | Yes | Yes | Yes | Yes | Yes | 18 |
| Account and ACL management | Yes | Yes | Yes | Yes | Yes | 20 |
| Custom ops (rebalance, reset master) | Yes | Yes | Yes | Yes | Yes | 21, 22 |
| Expose via NodePort | Yes | Yes | Yes | Yes | Yes | 17 |
| External hostname, replication | Yes | Yes | Yes | Yes | Yes | 27 |
| External hostname, sharded | Yes | Yes | Yes | Yes | Yes | 28 |
| Metrics exporter | Yes | Yes | Yes | Yes | Yes | 24 |
| TLS, standalone and replication | Yes | Yes | Yes | Yes | Yes | 05 |
| TLS, sharded | Yes, with a user-supplied CA — B3 | Yes, with a user-supplied CA — B3 | Yes, with a user-supplied CA — B3 | Yes, with a user-supplied CA — B3 | Yes, with a user-supplied CA — B3 | 19 |
| Backup, replication (`datafile`, `aof`) | Yes | Yes | Yes | Yes | Yes | 09, 13 |
| Backup, volume snapshot | Yes | Yes | Yes | Yes | Yes | 25 |
| Backup, sharded | ? — A2 | ? — A2 | Yes, but not exercised in CI — A2 | ? — A2 | ? — A2 | 12 |
| **Restore, standalone and replication** | Yes | Yes | Yes | **No** — B1, B2 | **No** — B1, B2 | 09 |
| **Restore, point-in-time (AOF)** | Yes | Yes | Yes | **No** — B1, B2 | **No** — B1, B2 | 13 |
| **Restore, volume snapshot** | Yes | Yes | Yes | **No** — B1, B2 | **No** — B1, B2 | 25 |
| **Restore, sharded** | **No** — C1 | **No** — C1 | **No** — C1 | **No** — B1, B2, C1 | **No** — B1, B2, C1 | 12, A2 |
| **Rebuild instance** | ? — B7 | ? — B7 | ? — B7 | ? — B7 | ? — B7 | 14, A3 |

Every column was measured by
[run 31582752684](https://github.com/FalkorDB/kubeblocks-addons/actions/runs/31582752684),
four shards each, which is the first run to include `1.2.0-alpha.2` and the
first with the A1/A5/A6 fixes in it. CI runs 26 of the 28 scenarios —
[12-sharding-backup-restore](e2e/tests/12-sharding-backup-restore) and
[14-rebuild-instance](e2e/tests/14-rebuild-instance) are excluded — so the rows
those two cover are not measured by any column. Of the 26 that do run, the only
failures were the three restore scenarios on `alpha.2`/`alpha.3` and sharded
scale-in on `1.0.2`; `1.1.0-beta.9` and `1.2.0-alpha.1` were green on all four
shards. `alpha.1` shard 2 failed on the first attempt in `actions/checkout` with
`server certificate verification failed`, before a single test ran, and passed
on re-run.

C1 is a bug in ape-dts rather than in KubeBlocks, so it holds sharded restore
down on every version regardless of what the platform does.

The practical readings:

- **The addon installs cleanly on every version tested.** Nothing is rejected;
  what breaks, breaks at runtime.
- **Sharded backup and restore are unresolved everywhere.** C1 blocks the
  restore half on every version, and because the scenario is excluded from CI
  the backup half is unmeasured on all but `1.2.0-alpha.1`, where it was last
  run by hand. No version in this table is clean on sharded data protection.
- **`1.0.2` — the last stable release — passed every CI scenario except sharded
  scale-in**, and that gap is now closed, but only when the chart is installed
  with `legacyShardingPreTerminate=true`. `1.0.2` never implemented the
  `shardRemove` hook the drain depends on (B5); it does invoke the
  ComponentDefinition `preTerminate` action, which is where the drain used to run
  before this addon moved to `shardRemove` and dropped the older path. That value
  puts `preTerminate` back. It defaults to `false` because declaring it wedges
  component teardown under namespace deletion on every version that runs the
  action, `1.0` included (B8), and every version from `1.1` has a working
  `shardRemove` that does not need it. Turning it on means also deleting the
  Cluster and waiting for it before deleting its namespace. Confirmed by CI:
  scenario 03 passes on `1.0.2`.
- **`1.1.0-beta.9` and `1.2.0-alpha.1` pass every scenario CI runs**, and are the
  only versions where sharded scale-in is safe *and* non-sharded restore works.
  Neither has been shown to handle sharded restore or rebuild-instance.
- **`alpha.3`'s sharded failures were ours, and are gone.** A1 left every
  instance passwordless (A6); with that fixed, `alpha.2` and `alpha.3` fail on
  exactly the same three scenarios and nothing else.
- **Non-sharded restore works up to and including `1.2.0-alpha.1` and nowhere
  after it.** `alpha.2` removed the annotation the addon uses in the same
  release that introduced the replacement, and the replacement has never
  completed a restore in any release that has it. On `alpha.3` the restored
  cluster comes up healthy and empty, which is the failure mode B1 describes.

### API-level changes behind the matrix

Tracked separately because these are what actually move when a KubeBlocks version
changes, and they are cheap to re-check. Everything here is read out of each
release's published CRDs, which is what the API server enforces — the Go source
can disagree with it, and for `passwordConfig` it does.

| API surface | 1.0.2 | 1.1.0-beta.9 | 1.2.0-alpha.1 | 1.2.0-alpha.2 | 1.2.0-alpha.3 |
|---|---|---|---|---|---|
| `kubeblocks.io/restore-from-backup` annotation | present | present | present | removed | removed |
| `Cluster.spec.restore` | absent | absent | absent | present | present |
| `ShardingDefinition.spec.tls.shared` | accepted, no-op | accepted, no-op | accepted, no-op | accepted, no-op | accepted, no-op |
| `systemAccounts[].passwordGenerationPolicy` | yes | yes | yes | yes | **removed** |
| `systemAccounts[].passwordConfig` | no | **yes** | no | no | yes |
| `ShardingDefinition.spec.lifecycleActions.shardAdd` / `shardRemove` | accepted, **no-op** | invoked | invoked | invoked | invoked |
| `ComponentDefinition` `v1alpha1` | present | present | present | present | removed (unused by this addon) |

`1.1.0-beta.9` is the only release that serves both spellings of the password
field, which makes it the one place a migration for A1 could be staged.

## Testing another version

The e2e workflow takes a list of KubeBlocks versions and runs the whole suite
against each of them, so the `?` cells above can be filled in with measurements
rather than guesses:

```bash
gh workflow run e2e-falkordb.yml \
  -f kb_versions=1.0.2,1.1.0-beta.9,1.2.0-alpha.1,1.2.0-alpha.3 \
  -f shards=4
```

Each leg reports `pass`, `fail`, or `install failed` — the last meaning the
addon's own definitions were rejected on that version, which is a different
problem from a scenario failing. The `matrix-summary` job collapses the shards
and prints one row per version, ready to transcribe here.

Locally, the same axis is just an environment variable:

```bash
E2E_KB_VERSION=1.0.2 make e2e-up && make e2e
```

The setup script derives the version-dependent chart values from
`E2E_KB_VERSION`, so nothing else has to be passed: `1.0.x` gets
`legacyShardingPreTerminate=true` (B5) and everything through `1.2.0-alpha.2`
gets the old `passwordGenerationPolicy` field name (A1). Installing the chart by
hand on `1.0.x` needs the first of those set explicitly.

## Register of broken and blocked items

### A — addon-side, fixable here

| id | Item | Affects | Status | Waiting on |
|---|---|---|---|---|
| A1 | The three ComponentDefinitions set `systemAccounts[].passwordGenerationPolicy`, which `1.2.0-alpha.3` renamed to `passwordConfig`. It is not rejected: the field is absent from that release's `systemAccounts` item schema and the schema does not preserve unknown fields, so the API server prunes it silently. | `1.2.0-alpha.3`+ | **fixed** | Nothing. The spelling is now a chart value, `systemAccountPasswordField`, because no release serves both names except the 1.1 line — writing both is not an option either, since `kubectl apply` defaults to strict decoding and rejects the unknown one even though Helm prunes it. [e2e/setup/kb-cluster.sh](e2e/setup/kb-cluster.sh) maps `KB_VERSION` to the right spelling. 27 of the addons in this repo still carry the bare old name. |
| A2 | Sharded backup/restore ([e2e/tests/12-sharding-backup-restore](e2e/tests/12-sharding-backup-restore)) is excluded from CI. | all | excluded from CI | C1 |
| A3 | `RebuildInstance` ([e2e/tests/14-rebuild-instance](e2e/tests/14-rebuild-instance)) is excluded from CI. It passes locally on `local-path`, where the race below is reliably won. | all | excluded from CI | B7 |
| A4 | Application-created ACL accounts are not captured by backups. | all | open, product limitation | A decision on whether to capture them. Identical in the in-tree `redis` addon. |
| A5 | [e2e/tests/15-sentinel-scaling](e2e/tests/15-sentinel-scaling) timed out waiting for a promotion after the primary was killed with five sentinels watching. Sentinel *did* see the outage — `+sdown`, `+odown`, four `+try-failover` — but every attempt ended in `-failover-abort-not-elected`: no candidate reached the majority of 3. The scenario killed the primary as soon as each new sentinel monitored the master, without waiting for the five to discover each other, and a sentinel that knows no peers votes for itself. Failed on `1.1.0-beta.9` and `1.2.0-alpha.1`, passed on `1.0.2` and `1.2.0-alpha.3` in the same run — a test race, not a version boundary. | CI only | **fixed** | Nothing. The scenario now waits for every sentinel to report `num-other-sentinels` 4 before killing the primary. |
| A6 | On `1.2.0-alpha.3` every FalkorDB instance came up **with no password at all**: `AUTH` answered `ERR AUTH <password> called without any password configured for the default user` 384–1231 times per job, and zero times on `1.0.2`, `1.1.0-beta.9` and `1.2.0-alpha.1`. This is A1's blast radius, not a separate bug — `GenerateSystemAccountPassword` returns the empty string when `PasswordConfig` is nil, the pruned field made it nil, the empty password reached the container as an empty `REDIS_DEFAULT_PASSWORD`, and [scripts/falkordb-start.sh](scripts/falkordb-start.sh) then skips writing the `user default on >...` ACL line entirely. Every sharded scenario failed at its first read or write; replication scenarios retried through it and passed, because `redis-cli` prints `AUTH failed:` and carries on. | `1.2.0-alpha.3` | **fixed** | Nothing — fixed by A1. Worth remembering as the reason a pruned field is not a cosmetic problem. |

### B — upstream KubeBlocks

| id | Item | Affects | Status | Waiting on |
|---|---|---|---|---|
| B1 | `kubeblocks.io/restore-from-backup` was removed in `1.2.0-alpha.2` rather than deprecated. It is dropped without an error and the cluster reports `Running` over an empty volume. | `1.2.0-alpha.2`+ | [#10755](https://github.com/apecloud/kubeblocks/issues/10755), open, confirmed intentional | A rejection or warning event for the obsolete annotation, plus B2 before the addon can migrate. |
| B2 | `Cluster.spec.restore` has never completed a restore in any release that has it. `alpha.2` hung on the `restore-manager` sidecar ([#10749](https://github.com/apecloud/kubeblocks/issues/10749), closed as duplicate); `alpha.3` deletes the `kb-populate-<uid>` PVC underneath its own `prepareData` job. | `1.2.0-alpha.2`+ | [#10755](https://github.com/apecloud/kubeblocks/issues/10755), open, assigned | An upstream fix. This is the single blocker on moving the pin past `alpha.1`. |
| B3 | Every shard of a sharding gets its own self-signed CA, so the Redis cluster bus cannot chain-validate between shards. `ShardingDefinition.spec.tls.shared` is the intended fix and is accepted by the CRD, but `clusterShardingTLSTransformer` is never added to the cluster reconciler's transformer chain, in every tag from `v1.1.0-alpha.4` to `main`, so the field is silently ignored. | all | [#10756](https://github.com/apecloud/kubeblocks/issues/10756), open | A one-line registration upstream. Until then, sharded TLS requires a user-supplied CA. |
| B4 | An Upgrade OpsRequest hangs forever when a ComponentDefinition declares a container the pod does not have. KubeBlocks compares every declared container against the pod and falls back to the pod's *first* container when the named one is absent, so a missing `metrics` container resolves to the falkordb image, never matches the expected exporter image, and the OpsRequest stays `Running` after a successful upgrade. The trigger is `disableExporter: true`. | all | [#10757](https://github.com/apecloud/kubeblocks/issues/10757), open | An upstream fix. Worked around by shipping the exporter **enabled** by default in [addons-cluster/falkordb](../../addons-cluster/falkordb/values.yaml), and by keeping it on in [e2e/tests/18-version-upgrade](e2e/tests/18-version-upgrade); anyone who turns it off cannot upgrade until this is fixed. |
| B5 | `ShardingDefinition.spec.lifecycleActions.shardAdd` and `shardRemove` are served by the `1.0.2` CRD and never invoked: at that tag the identifiers appear only in `apis/apps/v1/shardingdefinition_types.go` and the generated deepcopy, with no reference anywhere in `controllers/`. The API landed in 2024 ([#8272](https://github.com/apecloud/kubeblocks/pull/8272), renamed by [#8621](https://github.com/apecloud/kubeblocks/pull/8621)); the implementation only arrived in [#9830](https://github.com/apecloud/kubeblocks/pull/9830), merged to `main` after `release-1.0` was branched. So a sharded scale-in deletes the shard without ever running the addon's drain hook. | `1.0.2`, `1.0.3-beta.10` | [#10768](https://github.com/apecloud/kubeblocks/issues/10768), open | An upstream backport or an explicit rejection, though the addon no longer depends on one. Worked around here: `1.0` does invoke the ComponentDefinition `preTerminate` action, which is where this addon ran the drain until [#2947](https://github.com/apecloud/kubeblocks-addons/pull/2947) switched to `shardRemove` and deleted the older path, leaving `1.0` with neither. `preTerminate` is declared again behind the `legacyShardingPreTerminate` chart value, off by default because declaring it wedges teardown under namespace deletion on every version that runs it (B8). With it on, `detect_scale_in_context` still picks whichever mechanism the running version populates — `1.0` sets `KB_CLUSTER_COMPONENT_DELETING_LIST`/`UNDELETED_LIST` and has no `KB_REMOVE_SHARD_NAME`, `1.1` onwards is the reverse — so exactly one path drains and a whole-cluster delete drains via neither. Still the same class as B3 — a field the API accepts and the controller ignores. The in-tree `redis`, `mongodb` and `rocketmq` addons declare the same hook with no `preTerminate` fallback. |
| B6 | Consequence of B5: on `1.0.2`, scaling a sharding in from 4 to 3 shards reports success in ~30s — the cluster returns to 3 shards, all 16384 slots assigned, state `ok` — but the removed shard's keys are gone and the survivors still redirect to it (`Could not connect to Redis at fdb-shard-shard-zbv-0...: Name or service not known`, or `CLUSTERDOWN` when a survivor's own view goes to `fail`). Scale-*out* and rebalance on the same version are fine, because the addon drives those itself. | `1.0.2` | [#10768](https://github.com/apecloud/kubeblocks/issues/10768), open | Resolved here by `legacyShardingPreTerminate=true` — see B5. Confirmed: scenario 03 passes on `1.0.2` with the value set, having failed on the same commit without it. |
| B8 | A ComponentDefinition that declares `preTerminate` cannot finish deleting once its pods are gone. `componentPreTerminateTransformer` resolves the action through `ListOwnedPods` and returns a plain `has no pods to running the pre-terminate action` error, and the caller only swallows `IgnoreNotDefined`, so anything else requeues forever and `markPreTerminateDone` is never reached. `synthesizedComponent` can fail the same permanent way through `ResolveTemplateNEnvVars` once the namespace's Services start disappearing. Observed as a sharded cluster whose namespace never finishes deleting: scenario 28 passed every assertion and then timed out in cleanup after exactly 10 minutes. Reproduced locally on `1.0.2`, so this is not a `1.1` regression — it tracks whether `preTerminate` is declared, not the version. The controller log shows two stages: first `dial tcp 10.42.0.29:3501: connect: connection refused` while the Pod object still exists but kbagent is already dead, then `has no pods to running the pre-terminate action` forever after. The `1.0.2` source carries a `// TODO: (good-first-issue)` at that exact line, and `transformer_component_pre_terminate_test.go` asserts the error string, so upstream considers it expected. Only namespace GC triggers it: it deletes Cluster, Component, InstanceSet and Pods in parallel, whereas deleting the Cluster on its own runs the action while the pods are still up and finishes in about 30s. | all versions that run the action (reproduced on `1.0.2`, seen on `1.1.0-beta.9`) | unfiled | An upstream fix that treats a component with no pods as nothing to do. Not reachable in the default configuration, where `legacyShardingPreTerminate` is off. Where it is on, the e2e scenarios delete the Cluster and wait for it before the namespace goes; the `apply`-based ones get that from chainsaw's own step cleanup, the script-created ones (12, 28) do it explicitly. Annotating a stuck Component `apps.kubeblocks.io/skip-pre-terminate=true` releases it immediately and is the recovery for a namespace already wedged. |
| B7 | `RebuildInstance` provisions a scratch PVC, waits for its PV, restores into it and rebinds that PV onto the original claim, and neither storage class the e2e cluster offers survives the round trip. `local-path` (`WaitForFirstConsumer`) has no PV until the rebuild pod is scheduled, so KubeBlocks gives up with `can not found the pv by the pvc "rebuild-<hash>-..."` — a race, won on a developer machine and lost on a loaded runner. `csi-hostpath-sc` (`Immediate`) clears that and then stalls forever on `Waiting for source PVCs to bind restored PVs`. | all | open, not yet filed | An upstream fix, or a documented storage-class requirement. Previously mis-attributed to B4, which is a different failure. |

### C — other upstream

| id | Item | Affects | Status | Waiting on |
|---|---|---|---|---|
| C1 | ape-dts mis-parses FalkorDB's `telemetry{<graph>}` stream keys (RDB type byte 26); the parser desyncs, panics, then hangs instead of exiting, so a sharded restore stalls with a partial dataset. | all | fix **merged** upstream ([ape-dts#564](https://github.com/apecloud/ape-dts/pull/564), 2026-08-10) | A *release* carrying it. Every published tag, including `v2.0.26` and `v2.0.26-alpha.22`, predates the merge, so `values.yaml` is still pinned to `2.0.26-alpha.16`. Bump `apeDts.tag`, `apeDts.reshardTag` and `apeDtsImage.tag` and un-gate A2 when a tag containing `1a593863` ships. |

## Chart version history

| Chart | appVersion | Date |
|---|---|---|
| 1.6.6 | 4.20.1 | 2026-08-09 (current) |
| 1.6.5 | 4.20.1 | 2026-08-05 |
| 1.6.0 | 4.20.1 | 2026-07-16 |
| 1.5.0 | 4.20.1 | 2026-07-15 |
| 1.4.1 | 4.18.8 | 2026-05-25 |
| 1.0.2 | 4.14.10 | 2026-02-16 |
| 1.0.1 | 4.14.10 | 2025-12-29 |

Supported FalkorDB service versions: 4.20.1 (default), 4.18.11, 4.18.8, 4.14.12,
4.14.10, 4.12.5.

## e2e coverage

28 scenarios in [e2e/tests](e2e/tests). Two are excluded from CI and are expected
to fail until their blockers clear:

| Scenario | Excluded | Blocker |
|---|---|---|
| [12-sharding-backup-restore](e2e/tests/12-sharding-backup-restore) | yes | C1 |
| [14-rebuild-instance](e2e/tests/14-rebuild-instance) | yes | B7 |

Exclusion is by label, so CI runs `make e2e E2E_SELECTOR='e2e.falkordb/ci!=unsupported'`
while a local full run includes them.

## Re-checking this file

Whether an API exists in a given KubeBlocks release:

```bash
gh api "repos/apecloud/kubeblocks/contents/apis/apps/v1/cluster_types.go?ref=v1.2.0-alpha.3" \
  -q '.content' | base64 -d | grep 'json:"restore'
```

Whether a controller actually implements a field — the CRD containing it is not
evidence, as B3 shows. Check that the transformer is registered, not just present:

```bash
gh api "repos/apecloud/kubeblocks/contents/controllers/apps/cluster/cluster_controller.go?ref=main" \
  -q '.content' | base64 -d | grep 'Transformer{}'
```

Whether a removed field is rejected or silently pruned, which decides whether a
version bump is an outage or a behaviour change:

```bash
curl -sSL -o /tmp/crds.yaml \
  https://github.com/apecloud/kubeblocks/releases/download/v1.2.0-alpha.3/kubeblocks_crds.yaml
# then inspect the relevant schema for the field and for
# x-kubernetes-preserve-unknown-fields
```

Which capabilities hold on the pinned version:

```bash
make e2e
```
