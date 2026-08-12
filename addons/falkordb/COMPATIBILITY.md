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
is wider than what is actually tested — see the feature matrix below. It has
been left alone because narrowing it would exclude the alpha the addon does run
on, but it should be tightened once a KubeBlocks release exists that the addon
passes end-to-end on.

## Feature matrix

Rows are the capability a user actually asks for, not the API that implements it.
`Yes` means covered by a passing e2e scenario on that version. `?` means untested,
which is not the same as working — run the CI matrix against that version to fill
the cell in, see [Testing another version](#testing-another-version).

`1.0.2` is the last stable KubeBlocks release; everything after it on the 1.1 and
1.2 lines is a pre-release. The addon is pinned to `1.2.0-alpha.1`.

| Feature | 1.0.2 | 1.1.0-beta.9 | 1.2.0-alpha.1 | 1.2.0-alpha.2 | 1.2.0-alpha.3 | e2e |
|---|---|---|---|---|---|---|
| Standalone cluster | ? | ? | Yes | ? | ? | 04 |
| Replication cluster (with Sentinel) | ? | ? | Yes | ? | ? | 01, 11 |
| Sharded cluster | ? | ? | Yes | ? | ? | 03 |
| Switchover | ? | ? | Yes | ? | ? | 02 |
| Automatic failover, replication | ? | ? | Yes | ? | ? | 06 |
| Automatic failover, sharded | ? | ? | Yes | ? | ? | 23 |
| Self-healing, sharded | ? | ? | Yes | ? | ? | 08 |
| Horizontal scaling, replication | ? | ? | Yes | ? | ? | 01, 15 |
| Horizontal scaling, sharded (reshard) | ? | ? | Yes | ? | ? | 03 |
| Vertical scaling | ? | ? | Yes | ? | ? | 07 |
| Volume expansion | ? | ? | Yes | ? | ? | 26 |
| Restart | ? | ? | Yes | ? | ? | 07 |
| Stop / start | ? | ? | Yes | ? | ? | 16 |
| Reconfigure | ? | ? | Yes | ? | ? | 10 |
| Minor version upgrade | ? | ? | Yes | ? | ? | 18 |
| Account and ACL management | ? | ? | Yes | ? | degraded — A1 | 20 |
| Custom ops (rebalance, reset master) | ? | ? | Yes | ? | ? | 21, 22 |
| Expose via NodePort | ? | ? | Yes | ? | ? | 17 |
| External hostname, replication | ? | ? | Yes | ? | ? | 27 |
| External hostname, sharded | ? | ? | Yes | ? | ? | 28 |
| Metrics exporter | ? | ? | Yes | ? | ? | 24 |
| TLS, standalone and replication | ? | ? | Yes | ? | ? | 05 |
| TLS, sharded | ? — B3 applies | ? — B3 applies | Yes, but only with a user-supplied CA — B3 | ? — B3 applies | ? — B3 applies | 19 |
| Backup, replication (`datafile`, `aof`) | ? | ? | Yes | ? | ? | 09, 13 |
| Backup, volume snapshot | ? | ? | Yes | ? | ? | 25 |
| Backup, sharded | ? | ? | Yes, but not exercised in CI — A2 | ? | ? | 12 |
| **Restore, standalone and replication** | ? | ? | Yes | **No** — B1, B2 | **No** — B1, B2 | 09 |
| **Restore, point-in-time (AOF)** | ? | ? | Yes | **No** — B1, B2 | **No** — B1, B2 | 13 |
| **Restore, volume snapshot** | ? | ? | Yes | **No** — B1, B2 | **No** — B1, B2 | 25 |
| **Restore, sharded** | **No** — C1 | **No** — C1 | **No** — C1 | **No** — B1, B2, C1 | **No** — B1, B2, C1 | 12, A2 |
| **Rebuild instance** | ? — B4 applies | ? — B4 applies | **No** — B4 | **No** — B4 | **No** — B4 | 14, A3 |

C1 is a bug in ape-dts rather than in KubeBlocks, so it holds sharded restore
down on every version regardless of what the platform does.

The practical reading: **`1.2.0-alpha.1` is the only version on which restore is
known to work.** `alpha.2` removed the annotation the addon uses in the same
release that introduced the replacement, and the replacement has never completed
a restore in any release that has it.

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
| `ComponentDefinition` `v1alpha1` | present | present | present | present | removed (unused by this addon) |

`1.1.0-beta.9` is the only release that serves both spellings of the password
field, which makes it the one place a migration for A1 could be staged.

## Testing another version

The e2e workflow takes a list of KubeBlocks versions and runs the whole suite
against each of them, so the `?` cells above can be filled in with measurements
rather than guesses:

```
gh workflow run e2e-falkordb.yml \
  -f kb_versions=1.0.2,1.1.0-beta.9,1.2.0-alpha.1,1.2.0-alpha.3 \
  -f shards=4
```

Each leg reports `pass`, `fail`, or `install failed` — the last meaning the
addon's own definitions were rejected on that version, which is a different
problem from a scenario failing. The `matrix-summary` job collapses the shards
and prints one row per version, ready to transcribe here.

Locally, the same axis is just an environment variable:

```
E2E_KB_VERSION=1.0.2 make e2e-up && make e2e
```

## Register of broken and blocked items

### A — addon-side, fixable here

| id | Item | Affects | Status | Waiting on |
|---|---|---|---|---|
| A1 | The three ComponentDefinitions set `systemAccounts[].passwordGenerationPolicy`, which `1.2.0-alpha.3` renamed to `passwordConfig`. It is not rejected: the field is absent from that release's `systemAccounts` item schema and the schema does not preserve unknown fields, so the API server prunes it silently and accounts fall back to the default password config. | `1.2.0-alpha.3`+ | open | Nothing upstream — this is ours. It cannot be a straight rename, because no release serves both spellings except the 1.1 line: `1.2.0-alpha.1` (what we pin) has only the old name and `alpha.3` has only the new one. So it has to move together with the pin. 27 of the addons in this repo carry the same line. |
| A2 | Sharded backup/restore ([e2e/tests/12-sharding-backup-restore](e2e/tests/12-sharding-backup-restore)) is excluded from CI. | all | excluded from CI | C1 |
| A3 | `RebuildInstance` ([e2e/tests/14-rebuild-instance](e2e/tests/14-rebuild-instance)) is excluded from CI. | all | excluded from CI | B4 |
| A4 | Application-created ACL accounts are not captured by backups. | all | open, product limitation | A decision on whether to capture them. Identical in the in-tree `redis` addon. |

### B — upstream KubeBlocks

| id | Item | Affects | Status | Waiting on |
|---|---|---|---|---|
| B1 | `kubeblocks.io/restore-from-backup` was removed in `1.2.0-alpha.2` rather than deprecated. It is dropped without an error and the cluster reports `Running` over an empty volume. | `1.2.0-alpha.2`+ | [#10755](https://github.com/apecloud/kubeblocks/issues/10755), open, confirmed intentional | A rejection or warning event for the obsolete annotation, plus B2 before the addon can migrate. |
| B2 | `Cluster.spec.restore` has never completed a restore in any release that has it. `alpha.2` hung on the `restore-manager` sidecar ([#10749](https://github.com/apecloud/kubeblocks/issues/10749), closed as duplicate); `alpha.3` deletes the `kb-populate-<uid>` PVC underneath its own `prepareData` job. | `1.2.0-alpha.2`+ | [#10755](https://github.com/apecloud/kubeblocks/issues/10755), open, assigned | An upstream fix. This is the single blocker on moving the pin past `alpha.1`. |
| B3 | Every shard of a sharding gets its own self-signed CA, so the Redis cluster bus cannot chain-validate between shards. `ShardingDefinition.spec.tls.shared` is the intended fix and is accepted by the CRD, but `clusterShardingTLSTransformer` is never added to the cluster reconciler's transformer chain, in every tag from `v1.1.0-alpha.4` to `main`, so the field is silently ignored. | all | [#10756](https://github.com/apecloud/kubeblocks/issues/10756), open | A one-line registration upstream. Until then, sharded TLS requires a user-supplied CA. |
| B4 | An Upgrade OpsRequest hangs forever when a ComponentDefinition declares a container the pod does not have (`disableExporter: true`). | all | [#10757](https://github.com/apecloud/kubeblocks/issues/10757), open | An upstream fix. |

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
| [14-rebuild-instance](e2e/tests/14-rebuild-instance) | yes | B4 |

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
