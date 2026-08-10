#!/bin/bash
# Bring a disposable local Kubernetes cluster up (or down) with KubeBlocks and the
# locally-checked-out FalkorDB addon installed, ready for the chainsaw e2e suite.
#
# Usage:
#   ./kb-cluster.sh up      create the cluster and install everything
#   ./kb-cluster.sh down    delete the cluster
#   ./kb-cluster.sh status  show what is installed
#
# The addon chart is always installed from this working tree, never from a
# registry, so the suite exercises local changes.

set -euo pipefail

CLUSTER_NAME="${E2E_CLUSTER_NAME:-falkordb-e2e}"
K3S_IMAGE="${E2E_K3S_IMAGE:-rancher/k3s:v1.31.5-k3s1}"
# The addon chart declares addon.kubeblocks.io/kubeblocks-version: ">=1.2.0", and
# 1.2 is still pre-release, so the default is a pre-release and helm needs --devel.
# alpha.1 is pinned because it is the only 1.2 pre-release where restore actually
# works. alpha.2 deadlocked on the restore-manager sidecar
# (https://github.com/apecloud/kubeblocks/issues/10749, now closed), and on
# alpha.3 the restore-from-backup annotation is silently ignored while
# spec.restore hangs because its populator PVC is deleted underneath the
# prepareData job (https://github.com/apecloud/kubeblocks/issues/10755).
# Move this forward once 10755 is fixed.
KB_VERSION="${E2E_KB_VERSION:-1.2.0-alpha.1}"
KB_NAMESPACE="${E2E_KB_NAMESPACE:-kb-system}"
KB_REPO="${E2E_KB_REPO:-https://apecloud.github.io/helm-charts}"
# KubeBlocks ships its CRDs as a release asset rather than a chart.
KB_CRDS_URL="${E2E_KB_CRDS_URL:-https://github.com/apecloud/kubeblocks/releases/download/v$KB_VERSION/kubeblocks_crds.yaml}"
# how long to wait for the KubeBlocks deployment to become available
KB_WAIT="${E2E_KB_WAIT:-10m}"
# CRDs for the CSI snapshot API, which k3d does not ship.
SNAPSHOTTER_VERSION="${E2E_SNAPSHOTTER_VERSION:-v8.2.0}"
SNAPSHOTTER_CRD_BASE="${E2E_SNAPSHOTTER_CRD_BASE:-https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/$SNAPSHOTTER_VERSION/client/config/crd}"
SNAPSHOTTER_DEPLOY_BASE="${E2E_SNAPSHOTTER_DEPLOY_BASE:-https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/$SNAPSHOTTER_VERSION/deploy/kubernetes/snapshot-controller}"
# A CSI driver that can actually take snapshots, for the volume-snapshot backup
# method. The deploy manifests are published per Kubernetes minor version, so
# CSI_HOSTPATH_K8S_DIR has to be kept in step with K3S_IMAGE.
CSI_HOSTPATH_VERSION="${E2E_CSI_HOSTPATH_VERSION:-v1.17.1}"
CSI_HOSTPATH_K8S_DIR="${E2E_CSI_HOSTPATH_K8S_DIR:-kubernetes-1.31}"
CSI_HOSTPATH_REPO="${E2E_CSI_HOSTPATH_REPO:-https://github.com/kubernetes-csi/csi-driver-host-path}"
# Storage class backed by that driver. Scenarios that need snapshots ask for it
# by name; everything else stays on the default local-path class.
SNAPSHOT_STORAGE_CLASS="${E2E_SNAPSHOT_STORAGE_CLASS:-csi-hostpath-sc}"
# Domain used by the external-hostname scenarios. Nothing outside the cluster
# owns it; see install_external_dns_zone for how it is served.
EXTERNAL_DNS_SUFFIX="${E2E_EXTERNAL_DNS_SUFFIX:-falkordb.e2e.example.com}"
# Backup repository used by the dataprotection scenarios. The pvc provider needs
# no credentials and no object storage, which suits a throwaway local cluster.
BACKUP_REPO="${E2E_BACKUP_REPO:-falkordb-e2e-repo}"
BACKUP_REPO_SIZE="${E2E_BACKUP_REPO_SIZE:-5Gi}"
BACKUP_REPO_STORAGE_CLASS="${E2E_BACKUP_REPO_STORAGE_CLASS:-}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
ADDON_CHART="$REPO_ROOT/addons/falkordb"

log() {
  echo "[e2e-cluster] $*"
}

require() {
  local missing=0
  local tool
  for tool in "$@"; do
    if ! command -v "$tool" >/dev/null 2>&1; then
      echo "error: required tool '$tool' is not installed or not on PATH" >&2
      missing=1
    fi
  done
  [ "$missing" -eq 0 ] || exit 1
}

cluster_exists() {
  k3d cluster list -o json 2>/dev/null | grep -q "\"name\":\"$CLUSTER_NAME\""
}

create_cluster() {
  if cluster_exists; then
    log "k3d cluster '$CLUSTER_NAME' already exists, reusing it"
  else
    log "creating k3d cluster '$CLUSTER_NAME' ($K3S_IMAGE)"
    # traefik and servicelb are not used by the suite; disabling them keeps the
    # cluster small and speeds up start-up.
    k3d cluster create "$CLUSTER_NAME" \
      --image "$K3S_IMAGE" \
      --servers 1 \
      --agents 0 \
      --k3s-arg "--disable=traefik@server:0" \
      --k3s-arg "--disable=servicelb@server:0" \
      --wait
  fi
  kubectl config use-context "k3d-$CLUSTER_NAME"
  kubectl wait --for=condition=Ready nodes --all --timeout=5m
}

install_snapshot_crds() {
  # The KubeBlocks dataprotection controller watches VolumeSnapshot and refuses
  # to start if that CRD is absent ("timed out waiting for cache to be synced for
  # Kind *v1.VolumeSnapshot"). k3d ships no snapshot support, so without these the
  # controller sits in CrashLoopBackOff and every Backup is silently ignored -- it
  # never even gets a status. Only the CRDs are needed; the datafile and aof
  # methods do not take real snapshots.
  log "installing the VolumeSnapshot CRDs (required by the dataprotection controller)"
  for crd in volumesnapshotclasses volumesnapshotcontents volumesnapshots; do
    kubectl apply --server-side -f \
      "$SNAPSHOTTER_CRD_BASE/snapshot.storage.k8s.io_${crd}.yaml"
  done
}

install_snapshot_controller() {
  # The CRDs on their own are enough to keep the dataprotection controller alive,
  # but a VolumeSnapshot only ever becomes ready if something acts on it. Without
  # this controller the volume-snapshot backup method creates a VolumeSnapshot
  # that sits unbound forever and the Backup never leaves Running.
  log "installing the CSI snapshot controller $SNAPSHOTTER_VERSION"
  kubectl apply -f "$SNAPSHOTTER_DEPLOY_BASE/rbac-snapshot-controller.yaml"
  kubectl apply -f "$SNAPSHOTTER_DEPLOY_BASE/setup-snapshot-controller.yaml"
  kubectl -n kube-system rollout status deploy/snapshot-controller --timeout="$KB_WAIT"
}

install_csi_hostpath() {
  # local-path, the provisioner k3d defaults to, has no CSI snapshot support at
  # all, so the volume-snapshot backup method cannot be exercised against it.
  # The hostpath CSI driver is the reference implementation the Kubernetes
  # project uses for its own storage tests and is the lightest way to get real
  # VolumeSnapshots on a throwaway local cluster.
  if kubectl get storageclass "$SNAPSHOT_STORAGE_CLASS" >/dev/null 2>&1; then
    log "storage class '$SNAPSHOT_STORAGE_CLASS' already exists, skipping the CSI driver"
    return
  fi
  log "installing the hostpath CSI driver $CSI_HOSTPATH_VERSION"
  local dir
  dir="$(mktemp -d)"
  # The upstream deploy script resolves the matching sidecar RBAC for each
  # release, which is why the repo is cloned rather than the manifests applied
  # one by one.
  git clone --quiet --depth 1 --branch "$CSI_HOSTPATH_VERSION" "$CSI_HOSTPATH_REPO" "$dir"
  "$dir/deploy/$CSI_HOSTPATH_K8S_DIR/deploy.sh"
  kubectl apply -f "$dir/examples/csi-storageclass.yaml"
  rm -rf "$dir"
}

install_external_dns_zone() {
  # A production deployment that exposes FalkorDB outside the cluster points a
  # real DNS record at each pod's external endpoint and hands that name to the
  # addon through ANNOUNCE_HOSTNAME_OVERRIDE. There is no external DNS here, so
  # CoreDNS is taught to serve the zone itself: a name under the suffix is
  # rewritten onto the equivalent in-cluster name and the reply is rewritten
  # back, so clients only ever see the external name. That is enough to prove
  # the addon announces, gossips and reconnects using those names.
  log "serving the simulated external DNS zone '$EXTERNAL_DNS_SUFFIX'"
  # k3s ships CoreDNS with 'import /etc/coredns/custom/*.server' already in its
  # Corefile, backed by this optional ConfigMap, so no core config is touched.
  kubectl -n kube-system create configmap coredns-custom \
    --from-literal="falkordb-e2e-external.server=$(external_dns_server_block)" \
    --dry-run=client -o yaml | kubectl apply -f -
  # The reload plugin would pick this up on its own, but a restart makes the
  # zone usable immediately instead of up to a minute later.
  kubectl -n kube-system rollout restart deploy/coredns
  kubectl -n kube-system rollout status deploy/coredns --timeout="$KB_WAIT"
}

external_dns_server_block() {
  # <pod>-<ordinal>.<namespace>.$EXTERNAL_DNS_SUFFIX maps onto the pod's record
  # under its governing headless service. Deriving the service name from the
  # pod name is what keeps this namespace- and cluster-agnostic, which matters
  # for sharding: KubeBlocks gives every shard a generated component name, so
  # the headless service is not known when the override is written.
  cat <<EOF
${EXTERNAL_DNS_SUFFIX#*.}:53 {
    errors
    rewrite stop {
      name regex (.*)-(\\d+)\\.([^.]*)\\.${EXTERNAL_DNS_SUFFIX//./\\.} {1}-{2}.{1}-headless.{3}.svc.cluster.local
      answer name (.*)\\.(.*)-headless\\.([^.]*)\\.svc\\.cluster\\.local {1}.{3}.$EXTERNAL_DNS_SUFFIX
    }
    kubernetes cluster.local in-addr.arpa ip6.arpa {
      pods insecure
    }
    cache 30
}
EOF
}

install_kubeblocks() {
  log "installing the KubeBlocks $KB_VERSION CRDs"
  # server-side apply avoids the annotation size limit these large CRDs hit
  kubectl apply --server-side -f "$KB_CRDS_URL"

  log "installing KubeBlocks $KB_VERSION into namespace '$KB_NAMESPACE'"
  helm repo add kubeblocks "$KB_REPO" >/dev/null 2>&1 || true
  helm repo update kubeblocks >/dev/null
  kubectl create namespace "$KB_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

  helm upgrade --install kubeblocks kubeblocks/kubeblocks \
    --version "$KB_VERSION" --devel \
    --namespace "$KB_NAMESPACE" \
    --set admissionWebhooks.enabled=false \
    --set dataProtection.enabled=true \
    --wait --timeout "$KB_WAIT"

  log "waiting for the KubeBlocks controller to become available"
  kubectl -n "$KB_NAMESPACE" wait --for=condition=Available deployment \
    -l app.kubernetes.io/name=kubeblocks --timeout="$KB_WAIT"
}

install_addon() {
  log "installing the FalkorDB addon from $ADDON_CHART"
  helm dependency build "$ADDON_CHART" >/dev/null 2>&1 || true
  # The definitions carry helm.sh/resource-policy: keep and the KubeBlocks
  # controller defaults some of their fields, so a re-install races the
  # controller for server-side-apply field ownership. The local working tree is
  # the source of truth here, so take ownership unconditionally -- but only with
  # the flags this helm actually has. --take-ownership landed in helm 3.17 and
  # --force-conflicts in helm 4, and an older helm rejects an unknown flag
  # outright. Nothing is adopted on a fresh cluster anyway, so dropping them
  # there costs nothing.
  local ownership=()
  local upgrade_help
  upgrade_help="$(helm upgrade --help 2>/dev/null || true)"
  case "$upgrade_help" in
    *--take-ownership*) ownership+=(--take-ownership) ;;
  esac
  case "$upgrade_help" in
    *--force-conflicts*) ownership+=(--force-conflicts) ;;
  esac

  helm upgrade --install falkordb "$ADDON_CHART" \
    --namespace "$KB_NAMESPACE" \
    ${ownership[@]+"${ownership[@]}"} \
    --wait --timeout "$KB_WAIT"

  log "waiting for the FalkorDB ComponentDefinitions to be available"
  # The rendered names carry the chart version (falkordb-4-1.6.5, ...), so select
  # by the helm release label rather than hard-coding them.
  kubectl wait --for=jsonpath='{.status.phase}'=Available componentdefinitions \
    -l app.kubernetes.io/instance=falkordb --timeout=5m
}

install_backup_repo() {
  log "creating the default BackupRepo '$BACKUP_REPO'"
  # The backup scenarios need somewhere to put a backup. Object storage would mean
  # running minio and handing out credentials; the built-in pvc provider just
  # carves a volume out of the node's local storage, which is all a single-node
  # throwaway cluster needs.
  kubectl apply -f - <<EOF
apiVersion: dataprotection.kubeblocks.io/v1alpha1
kind: BackupRepo
metadata:
  name: $BACKUP_REPO
  annotations:
    dataprotection.kubeblocks.io/is-default-repo: "true"
spec:
  storageProviderRef: pvc
  accessMethod: Mount
  volumeCapacity: $BACKUP_REPO_SIZE
  pvReclaimPolicy: Delete
  config:
    storageClassName: "$BACKUP_REPO_STORAGE_CLASS"
    accessMode: ReadWriteOnce
EOF

  log "waiting for the BackupRepo to become ready"
  kubectl wait --for=jsonpath='{.status.phase}'=Ready "backuprepo/$BACKUP_REPO" \
    --timeout=5m
}

up() {
  require k3d kubectl helm git
  create_cluster
  install_snapshot_crds
  install_snapshot_controller
  install_csi_hostpath
  install_external_dns_zone
  install_kubeblocks
  install_addon
  install_backup_repo
  log "cluster is ready; run 'make e2e' to execute the suite"
}

down() {
  require k3d
  if cluster_exists; then
    log "deleting k3d cluster '$CLUSTER_NAME'"
    k3d cluster delete "$CLUSTER_NAME"
  else
    log "k3d cluster '$CLUSTER_NAME' does not exist, nothing to do"
  fi
}

status() {
  require kubectl
  echo "--- nodes"
  kubectl get nodes
  echo "--- storage"
  kubectl get storageclass
  kubectl get volumesnapshotclass 2>/dev/null || echo "(no volume snapshot classes)"
  echo "--- kubeblocks"
  kubectl -n "$KB_NAMESPACE" get deploy
  echo "--- component definitions"
  kubectl get componentdefinition | grep -i falkordb || echo "(none)"
  echo "--- cluster definitions"
  kubectl get clusterdefinition | grep -i falkordb || echo "(none)"
  echo "--- backup repositories"
  kubectl get backuprepo 2>/dev/null || echo "(none)"
}

main() {
  case "${1:-up}" in
    up) up ;;
    down) down ;;
    status) status ;;
    *)
      echo "usage: $0 {up|down|status}" >&2
      exit 1
      ;;
  esac
}

main "$@"
