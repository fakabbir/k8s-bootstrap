#!/usr/bin/env bash
#
# Bootstrap Argo CD on the deployer cluster and connect the dev + orbstack clusters.
#
#   ./build.sh                 full run (install, register clusters, apply root app)
#   ./build.sh --skip-install  reuse the existing Argo CD release
#   ./build.sh --skip-clusters only re-register the member clusters
#   ./build.sh --skip-root     leave the GitOps root app and its apps alone
#
# Safe to re-run: helm upgrade --install plus kubectl apply, and existing service
# account tokens are reused instead of rotated.

set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cd "$REPO_ROOT"

# shellcheck source=scripts/lib.sh
source scripts/lib.sh
# shellcheck source=config/bootstrap.env
source config/bootstrap.env

WORK_DIR=$REPO_ROOT/.work
PROBE_POD=argocd-bootstrap-probe
SKIP_INSTALL=false
SKIP_CLUSTERS=false
SKIP_ROOT=false

while (( $# > 0 )); do
  case $1 in
    --skip-install)  SKIP_INSTALL=true ;;
    --skip-clusters) SKIP_CLUSTERS=true ;;
    --skip-root)     SKIP_ROOT=true ;;
    -h|--help)
      sed -n '3,15p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) die "Unknown option: $1 (try --help)" ;;
  esac
  shift
done

cleanup() {
  kubectl --context "$ARGOCD_CONTEXT" -n "$ARGOCD_NAMESPACE" \
    delete pod "$PROBE_POD" --ignore-not-found --wait=false >/dev/null 2>&1 || true
}
trap cleanup EXIT

# --- kubeconfig / address helpers --------------------------------------------

kube_server_for() {
  local ctx=$1 cname
  cname=$(kubectl config view --raw -o jsonpath="{.contexts[?(@.name=='${ctx}')].context.cluster}")
  kubectl config view --raw -o jsonpath="{.clusters[?(@.name=='${cname}')].cluster.server}"
}

ca_data_for() {
  local ctx=$1 cname
  cname=$(kubectl config view --raw -o jsonpath="{.contexts[?(@.name=='${ctx}')].context.cluster}")
  kubectl config view --raw -o jsonpath="{.clusters[?(@.name=='${cname}')].cluster.certificate-authority-data}"
}

# Candidate API addresses, best guess first.
#
# A laptop kubeconfig points at 127.0.0.1:<published-port>, which means nothing to
# a pod inside the deployer cluster, so the member node's own internal IP is used.
# Two ports are tried because kind publishes 6443 on the node itself while OrbStack
# only forwards its API through the laptop, on the port found in the kubeconfig.
candidate_urls() {
  local ctx=$1 pinned=$2 server hostport port node_ip
  node_ip=$(kubectl --context "$ctx" get nodes \
    -o jsonpath='{.items[*].status.addresses[?(@.type=="InternalIP")].address}' | awk '{print $1}')
  server=$(kube_server_for "$ctx")
  hostport=${server#*://}
  port=${hostport##*:}
  {
    if [[ -n $pinned ]]; then printf '%s\n' "$pinned"; fi
    if [[ -n $node_ip ]]; then
      printf 'https://%s:6443\nhttps://%s:%s\n' "$node_ip" "$node_ip" "$port"
    fi
  } | awk '!seen[$0]++'
}

# --- reachability probe ------------------------------------------------------
#
# Argo CD keeps cluster connection state in memory, so nothing readable is written
# back to the cluster Secret. Instead of guessing, ask the question the way Argo CD
# would: from a pod in the deployer cluster, with this CA bundle and this token.

start_probe_pod() {
  step "Starting reachability probe pod on $ARGOCD_CONTEXT"
  kubectl --context "$ARGOCD_CONTEXT" -n "$ARGOCD_NAMESPACE" \
    delete pod "$PROBE_POD" --ignore-not-found --wait=true >/dev/null 2>&1 || true
  kubectl --context "$ARGOCD_CONTEXT" -n "$ARGOCD_NAMESPACE" run "$PROBE_POD" \
    --image="$PROBE_IMAGE" --restart=Never \
    --overrides="{\"spec\":{\"containers\":[{\"name\":\"$PROBE_POD\",\"image\":\"$PROBE_IMAGE\",\"command\":[\"sleep\",\"600\"]}]}}" \
    >/dev/null
  poll "pod/$PROBE_POD to be Ready" 180 5 probe_pod_ready ||
    die "Probe pod $PROBE_POD never became ready. If $ARGOCD_CONTEXT has no internet access for image
     pulls, set PROBE_IMAGE in config/bootstrap.env to an image already present on the nodes."
  ok "probe pod ready ($PROBE_POD)"
}

probe_pod_ready() {
  [[ $(kubectl --context "$ARGOCD_CONTEXT" -n "$ARGOCD_NAMESPACE" \
        get pod "$PROBE_POD" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null) == True ]]
}

probe_write() {
  # probe_write <remote-path> <content-on-stdin>
  kubectl --context "$ARGOCD_CONTEXT" -n "$ARGOCD_NAMESPACE" \
    exec -i "$PROBE_POD" -- sh -c "cat > $1"
}

# probe_url <cluster-name> <url> -> echoes Verified | Insecure | AuthRejected | Unreachable
probe_url() {
  local name=$1 url=$2 code
  code=$(kubectl --context "$ARGOCD_CONTEXT" -n "$ARGOCD_NAMESPACE" exec "$PROBE_POD" -- \
    sh -c "curl -sS -o /dev/null -w '%{http_code}' --max-time 8 --cacert /tmp/${name}.ca.pem -H @/tmp/${name}.hdr '$url/version'" 2>/dev/null) || code=000
  case "$code" in
    200) echo Verified; return 0 ;;
    401|403) echo AuthRejected; return 0 ;;
  esac
  # Certificate or hostname validation failed: repeat without verification to tell a
  # bad certificate apart from a dead address.
  code=$(kubectl --context "$ARGOCD_CONTEXT" -n "$ARGOCD_NAMESPACE" exec "$PROBE_POD" -- \
    sh -c "curl -sS -o /dev/null -w '%{http_code}' --max-time 8 -k '$url/version'" 2>/dev/null) || code=000
  case "$code" in
    200|401|403) echo Insecure ;;
    *) echo Unreachable ;;
  esac
}

# --- member cluster registration ---------------------------------------------

token_ready() {
  [[ -n $(kubectl --context "$1" -n "$ARGOCD_MANAGER_NS" \
      get secret "${ARGOCD_MANAGER_SA}-token" -o jsonpath='{.data.token}' 2>/dev/null) ]]
}

register_cluster() {
  local ctx=$1 name=$2 env_label=$3 pinned=$4
  step "Registering $ctx as Argo CD cluster '$name'"

  kubectl --context "$ctx" apply -f argocd/clusters/manager-rbac.yaml >/dev/null
  ok "service account '$ARGOCD_MANAGER_SA' ready in namespace '$ARGOCD_MANAGER_NS'"

  poll "the API server to mint the service account token" 60 5 token_ready "$ctx" ||
    die "No token appeared in secret ${ARGOCD_MANAGER_NS}/${ARGOCD_MANAGER_SA}-token of $ctx."
  local token ca
  token=$(kubectl --context "$ctx" -n "$ARGOCD_MANAGER_NS" \
    get secret "${ARGOCD_MANAGER_SA}-token" -o jsonpath='{.data.token}' | base64 -d)
  ca=$(ca_data_for "$ctx")

  # Only the public file path is shared with the cluster; the kubeconfig may have
  # been generated with insecure-skip-tls-verify and carry no CA at all.
  if [[ -n $ca ]]; then
    printf '%s\n' "$ca" | base64 -d | probe_write "/tmp/${name}.ca.pem"
  else
    info "no CA data in kubeconfig for $ctx; probing will rely on certificate verification being skipped"
  fi
  printf 'Authorization: Bearer %s\n' "$token" | probe_write "/tmp/${name}.hdr"

  local urls=() u chosen="" mode=""
  while IFS= read -r u; do
    [[ -n $u ]] && urls+=("$u")
  done < <(candidate_urls "$ctx" "$pinned")
  (( ${#urls[@]} > 0 )) ||
    die "Could not work out any API address for $ctx. Set the 4th field of MANAGED_CLUSTERS in config/bootstrap.env."

  local result
  for u in "${urls[@]}"; do
    result=$(probe_url "$name" "$u")
    info "$u -> $result"
    case $result in
      Verified)   chosen=$u; mode=verified; break ;;
      Insecure)   chosen=$u; mode=insecure ;;
      AuthRejected)
        # Another address may still work, but every address on this cluster uses the
        # same token, so a rejection is an RBAC problem rather than a routing one.
        warn "$u answers but rejected the '$ARGOCD_MANAGER_SA' token; the address is fine, the RBAC is not"
        chosen=$u; mode=verified; break ;;
      Unreachable) : ;;
    esac
  done

  [[ -n $chosen ]] ||
    die "Argo CD cannot reach $ctx on any candidate address (${urls[*]}).
     Find an address for that API server that works from inside $ARGOCD_CONTEXT,
     set it as the 4th field of MANAGED_CLUSTERS in config/bootstrap.env, and re-run."

  render_cluster_secret "$name" "$chosen" "$mode" "$token" "$ca"
  if [[ $mode == insecure ]]; then
    warn "cluster '$name' registered with tlsClientConfig.insecure: the API certificate has no
     subjectAltName matching $chosen, so Argo CD cannot verify it. Fine locally, not for real clusters."
  fi
  ok "cluster '$name' registered: $chosen ($mode)"
}

render_cluster_secret() {
  local name=$1 url=$2 mode=$3 token=$4 ca=$5 tls out
  if [[ $mode == insecure ]]; then
    tls='{"insecure":true}'
  else
    tls=$(jq -nc --arg ca "$ca" '{caData:$ca}')
  fi
  mkdir -p "$WORK_DIR/clusters"
  out=$WORK_DIR/clusters/$name.json
  jq -n \
    --arg name "$name" \
    --arg ns "$ARGOCD_NAMESPACE" \
    --arg server "$url" \
    --arg token "$token" \
    --arg tls "$tls" \
    '{
      apiVersion: "v1",
      kind: "Secret",
      metadata: {
        name: $name,
        namespace: $ns,
        labels: {
          "argocd.argoproj.io/secret-type": "cluster",
          "app.kubernetes.io/part-of": "argocd"
        }
      },
      type: "Opaque",
      stringData: {
        name: $name,
        server: $server,
        config: ({bearerToken: $token, tlsClientConfig: ($tls | fromjson)} | tojson)
      }
    }' > "$out"
  chmod 600 "$out"
  kubectl --context "$ARGOCD_CONTEXT" apply -f "$out" >/dev/null
}

# --- GitOps layers -----------------------------------------------------------

install_argocd() {
  step "Installing Argo CD on $ARGOCD_CONTEXT"
  info "chart $ARGOCD_CHART version $ARGOCD_CHART_VERSION, values argocd/install/values.yaml"
  helm upgrade --install "$ARGOCD_RELEASE" "$ARGOCD_CHART" \
    --version "$ARGOCD_CHART_VERSION" \
    --namespace "$ARGOCD_NAMESPACE" \
    --kube-context "$ARGOCD_CONTEXT" \
    --create-namespace \
    --values argocd/install/values.yaml \
    --wait \
    --timeout "${ROLLOUT_TIMEOUT}s"

  kubectl --context "$ARGOCD_CONTEXT" wait \
    --for condition=established --timeout=120s \
    crd/applications.argoproj.io \
    crd/appprojects.argoproj.io \
    crd/applicationsets.argoproj.io >/dev/null
  ok "Argo CD control plane deployed and CRDs established"
}

apply_root() {
  step "Applying the GitOps bootstrap layer to $ARGOCD_CONTEXT"
  kubectl --context "$ARGOCD_CONTEXT" -n "$ARGOCD_NAMESPACE" \
    apply -f argocd/bootstrap/project-argocd-system.yaml >/dev/null
  kubectl --context "$ARGOCD_CONTEXT" -n "$ARGOCD_NAMESPACE" \
    apply -f argocd/bootstrap/root-app.yaml >/dev/null
  ok "AppProject argocd-system and Application argocd-root applied"

  poll "argocd-root to be Synced and Healthy" "$ROLLOUT_TIMEOUT" 10 root_ready ||
    die "argocd-root did not reach Synced/Healthy:
     kubectl --context $ARGOCD_CONTEXT -n $ARGOCD_NAMESPACE get application argocd-root -o yaml"
  ok "argocd-root is Synced and Healthy"

  poll "ApplicationSets to generate Applications" "$ROLLOUT_TIMEOUT" 10 apps_generated ||
    die "No Applications were generated. Check the ApplicationSets:
     kubectl --context $ARGOCD_CONTEXT -n $ARGOCD_NAMESPACE get applicationsets"
  ok "Applications generated from apps/overlays"

  poll "every Application to be Synced and Healthy" "$ROLLOUT_TIMEOUT" 10 apps_healthy || {
    warn "some Applications are not Synced/Healthy yet; Argo CD is still retrying"
    list_applications
  }
}

root_ready() {
  local s
  s=$(kubectl --context "$ARGOCD_CONTEXT" -n "$ARGOCD_NAMESPACE" \
    get application argocd-root -o jsonpath='{.status.sync.status} {.status.health.status}' 2>/dev/null) || return 1
  [[ $s == "Synced Healthy" ]]
}

# Applications other than the root app; empty when the ApplicationSets have not run yet.
child_applications() {
  kubectl --context "$ARGOCD_CONTEXT" -n "$ARGOCD_NAMESPACE" \
    get applications.argoproj.io -o jsonpath='{range .items[?(@.metadata.name!="argocd-root")]}{.metadata.name} {.status.sync.status} {.status.health.status}{"\n"}{end}' 2>/dev/null
}

apps_generated() { [[ -n "$(child_applications)" ]]; }

apps_healthy() {
  local line
  apps_generated || return 1
  while IFS= read -r line; do
    [[ $line == *" Synced Healthy" ]] || return 1
  done < <(child_applications)
  return 0
}

list_applications() {
  child_applications | sed 's/^/      /'
}

# --- reporting ---------------------------------------------------------------

preflight() {
  step "Preflight"
  require_bins kubectl helm jq base64 git
  mkdir -p "$WORK_DIR/clusters"
  require_context "$ARGOCD_CONTEXT"
  ok "deployer context: $ARGOCD_CONTEXT"

  local entry ctx name env_label pinned
  for entry in "${MANAGED_CLUSTERS[@]}"; do
    IFS='|' read -r ctx name env_label pinned <<<"$entry"
    require_context "$ctx"
    ok "member context: $ctx -> cluster name '$name' ($env_label)"
  done

  # Argo CD clones from the public HTTPS URL, so the branch must already exist.
  if ! git ls-remote --heads "$GIT_REPO" "$GIT_BRANCH" 2>/dev/null | grep -q "refs/heads/$GIT_BRANCH"; then
    die "$GIT_REPO has no '$GIT_BRANCH' branch yet. Commit and push this folder first, then re-run build.sh."
  fi
  ok "git source reachable with a '$GIT_BRANCH' branch: $GIT_REPO"
}

summary() {
  step "Result"
  printf '\n  Clusters known to Argo CD\n'
  kubectl --context "$ARGOCD_CONTEXT" -n "$ARGOCD_NAMESPACE" \
    get secret -l argocd.argoproj.io/secret-type=cluster \
    -o custom-columns='NAME:.metadata.name,SERVER:.stringData.server' --no-headers 2>/dev/null | sed 's/^/    /'

  printf '\n  Applications (name / project / destination / sync / health)\n'
  kubectl --context "$ARGOCD_CONTEXT" -n "$ARGOCD_NAMESPACE" get applications.argoproj.io \
    -o custom-columns='NAME:.metadata.name,PROJECT:.spec.project,DEST:.spec.destination.name,SYNC:.status.sync.status,HEALTH:.status.health.status' \
    --no-headers 2>/dev/null | sed 's/^/    /'

  local pass
  pass=$(kubectl --context "$ARGOCD_CONTEXT" -n "$ARGOCD_NAMESPACE" \
    get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' 2>/dev/null | base64 -d)

  cat <<EOF

  Open the UI
    kubectl --context $ARGOCD_CONTEXT -n $ARGOCD_NAMESPACE port-forward svc/argocd-server 8080:80
    URL        http://localhost:8080
    Username   admin
    Password   ${pass:-<read it from secret argocd-initial-admin-secret>}

  Adding a workload: drop a directory under apps/overlays/dev or apps/overlays/prod and push.
  Details in README.md.
EOF
}

main() {
  preflight
  $SKIP_INSTALL || install_argocd
  if $SKIP_CLUSTERS; then
    warn "skipping cluster registration (--skip-clusters)"
  else
    start_probe_pod
    local entry ctx name env_label pinned
    for entry in "${MANAGED_CLUSTERS[@]}"; do
      IFS='|' read -r ctx name env_label pinned <<<"$entry"
      register_cluster "$ctx" "$name" "$env_label" "$pinned"
    done
  fi
  $SKIP_ROOT || apply_root
  summary
  step "Done"
}

main "$@"
