# FalkorDB Addon – Deployment Guide

This document covers how to build, install, upgrade, and locally test the FalkorDB KubeBlocks addon chart.
It is specifically relevant to the **POSIX sh migration** (chart version `1.0.2`), which makes all scripts
compatible with `/bin/sh` (dash) so the addon works on Debian 13 and any Linux image that ships without
`/bin/bash`.

## What changed in 1.0.2

All lifecycle shell scripts (`scripts/`, `falkordb-cluster-scripts/`, `dataprotection/`) and the Helm
templates that reference a shell interpreter were migrated from `/bin/bash` to `/bin/sh`.

Key changes:
- Shebangs: `#!/bin/bash` → `#!/bin/sh` across 30+ scripts
- Bash arrays → pipe-separated strings or TAB-delimited temp files
- `declare -A` associative arrays → temp-file maps with `_map_get`/`_map_append`/`_map_size`/`_map_keys`
- `[[ ... ]]` / `BASH_REMATCH` → POSIX `[ ]` and `sed`
- `<<< here-strings` → `<< _EOF_` heredocs
- `source` → `.` (dot-source)
- `${var/pattern/replace}` → `sed`-based helper `_mask_password()`
- Template YAML: all `command: ["/bin/bash", "-c"]` and `- bash` entries updated to `/bin/sh` / `sh`

---

## Prerequisites

| Tool | Minimum version | Purpose |
|------|----------------|---------|
| `kubectl` | 1.21 | Apply Kubernetes manifests |
| `helm` | 3.x | Package and install the chart |
| KubeBlocks | 1.0.0 | Addon runtime |

Verify KubeBlocks is running:
```bash
kubectl get pod -n kb-system
```

---

## Build the chart package

Dependencies must be resolved before packaging:
```bash
# From the repo root
helm dependency update addons/falkordb

# Package to dist/
mkdir -p dist
helm package addons/falkordb --destination dist
# → dist/falkordb-1.0.2.tgz
```

---

## Local testing (before committing)

### 1. Render templates and inspect output

Check that all `command`/`args` fields reference `/bin/sh`, not `/bin/bash`:
```bash
helm template falkordb dist/falkordb-1.0.2.tgz \
  | grep -n 'bash\|/bin/sh'
```

Expected: only `/bin/sh` references, zero `/bin/bash` matches.

Render and spot-check a specific template:
```bash
helm template falkordb dist/falkordb-1.0.2.tgz \
  --show-only templates/cmpd-falkordb.yaml | less
```

### 2. Run helm lint

```bash
helm lint addons/falkordb --strict
# Expected: 1 chart(s) linted, 0 chart(s) failed
```

### 3. Run shellcheck on scripts

```bash
find addons/falkordb -type f -name "*.sh" ! -path "*/scripts-ut-spec/*" \
  | sort | xargs shellcheck --shell=sh --severity=error
# Expected: no output (zero errors)
```

### 4. Dry-run install against a cluster

```bash
helm install falkordb dist/falkordb-1.0.2.tgz \
  --namespace kb-system \
  --dry-run --debug 2>&1 | grep -E 'MANIFEST|Error'
```

### 5. Verify script shebangs inside the package

```bash
tar -tzf dist/falkordb-1.0.2.tgz | grep '\.sh$' | while read f; do
  line=$(tar -xOf dist/falkordb-1.0.2.tgz "$f" 2>/dev/null | head -1)
  printf '%-70s %s\n' "$f" "$line"
done
```

All lines should show `#!/bin/sh`, not `#!/bin/bash`.

---

## Install / upgrade

### Install (first time)

```bash
helm install falkordb dist/falkordb-1.0.2.tgz \
  --namespace kb-system \
  --create-namespace
```

### Upgrade from a previous version

```bash
helm upgrade falkordb dist/falkordb-1.0.2.tgz \
  --namespace kb-system \
  --atomic \
  --timeout 5m
```

`--atomic` rolls back automatically if any hook or resource fails.

### Verify the addon resources were applied

```bash
# ComponentDefinitions
kubectl get componentdefinition -l app.kubernetes.io/name=falkordb

# ClusterDefinition
kubectl get clusterdefinition falkordb

# ConfigMap with scripts
kubectl get cm -n kb-system | grep falkordb
```

---

## Create a FalkorDB cluster

After the addon is installed, create a cluster with one of the included topology examples.

### Replication (primary + secondary + 3 sentinels)

```bash
kubectl create ns demo

kubectl apply -f - <<'EOF'
apiVersion: apps.kubeblocks.io/v1
kind: Cluster
metadata:
  name: falkordb-replication
  namespace: demo
spec:
  terminationPolicy: Delete
  clusterDef: falkordb
  topology: replication
  componentSpecs:
    - name: falkordb
      serviceVersion: "4.18.7"
      replicas: 2
      resources:
        limits: { cpu: "0.5", memory: "512Mi" }
        requests: { cpu: "0.5", memory: "512Mi" }
      volumeClaimTemplates:
        - name: data
          spec:
            accessModes: [ReadWriteOnce]
            resources:
              requests:
                storage: 10Gi
    - name: falkordb-sent
      serviceVersion: "4.18.7"
      replicas: 3
      resources:
        limits: { cpu: "0.25", memory: "256Mi" }
        requests: { cpu: "0.25", memory: "256Mi" }
      volumeClaimTemplates:
        - name: data
          spec:
            accessModes: [ReadWriteOnce]
            resources:
              requests:
                storage: 1Gi
EOF
```

Wait for the cluster to become ready:
```bash
kubectl get -n demo cluster falkordb-replication --watch
```

Check pod roles once the cluster is `Running`:
```bash
kubectl get po -n demo \
  -l app.kubernetes.io/instance=falkordb-replication,apps.kubeblocks.io/component-name=falkordb \
  -L kubeblocks.io/role
```

### Standalone (single node, development)

```bash
kubectl apply -f - <<'EOF'
apiVersion: apps.kubeblocks.io/v1
kind: Cluster
metadata:
  name: falkordb-standalone
  namespace: demo
spec:
  terminationPolicy: Delete
  clusterDef: falkordb
  topology: standalone
  componentSpecs:
    - name: falkordb
      serviceVersion: "4.18.7"
      replicas: 1
      resources:
        limits: { cpu: "0.5", memory: "512Mi" }
        requests: { cpu: "0.5", memory: "512Mi" }
      volumeClaimTemplates:
        - name: data
          spec:
            accessModes: [ReadWriteOnce]
            resources:
              requests:
                storage: 10Gi
EOF
```

### Sharding (3 shards × 2 replicas)

```bash
kubectl apply -f - <<'EOF'
apiVersion: apps.kubeblocks.io/v1
kind: Cluster
metadata:
  name: falkordb-sharding
  namespace: demo
spec:
  terminationPolicy: Delete
  clusterDef: falkordb
  shardings:
    - name: shard
      shards: 3
      template:
        name: falkordb
        componentDef: falkordb-cluster-4
        serviceVersion: "4.18.7"
        replicas: 2
        resources:
          limits: { cpu: "1", memory: "1Gi" }
          requests: { cpu: "1", memory: "1Gi" }
        services:
          - name: falkordb-advertised
            podService: true
            serviceType: NodePort
        volumeClaimTemplates:
          - name: data
            spec:
              accessModes: [ReadWriteOnce]
              resources:
                requests:
                  storage: 20Gi
EOF
```

---

## Connectivity test

Once the cluster is `Running`, forward a local port to the primary pod and run a smoke test:

```bash
# Replication cluster example
kubectl port-forward -n demo \
  $(kubectl get po -n demo -l kubeblocks.io/role=primary \
    -l app.kubernetes.io/instance=falkordb-replication \
    -o jsonpath='{.items[0].metadata.name}') \
  6379:6379 &

# Smoke test – FalkorDB graph query
redis-cli -p 6379 PING
redis-cli -p 6379 GRAPH.QUERY mygraph "CREATE (:Node {name:'hello'})"
redis-cli -p 6379 GRAPH.QUERY mygraph "MATCH (n) RETURN n.name"
```

---

## Rollback

If the upgrade causes problems, roll back to the previous Helm release:
```bash
helm rollback falkordb --namespace kb-system
```

Or to a specific revision:
```bash
helm history falkordb -n kb-system      # list revisions
helm rollback falkordb <REVISION> -n kb-system
```

---

## Uninstall

Remove the addon and all its CRDs:
```bash
helm uninstall falkordb --namespace kb-system
```

> **Note:** This removes the ComponentDefinitions and ClusterDefinition but leaves any existing
> FalkorDB `Cluster` resources intact. Delete clusters first if you want a full cleanup.

---

## Troubleshooting

### Script errors mentioning `/bin/bash: not found`

This was the motivating problem solved in 1.0.2. If you see this on a Debian 13 node, the addon
may still be running an old version. Verify the installed chart version:
```bash
helm list -n kb-system | grep falkordb
```

Then upgrade to `1.0.2` or later.

### Inspect the mounted scripts inside a pod

```bash
POD=$(kubectl get po -n demo -l app.kubernetes.io/instance=falkordb-replication \
  -o jsonpath='{.items[0].metadata.name}')

kubectl exec -n demo "$POD" -- head -1 /scripts/falkordb-start.sh
# Expected: #!/bin/sh
```
