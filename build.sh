#!/usr/bin/env bash
#
# Bootstrap Argo CD on the deployer cluster and connect the dev + orbstack clusters.
#
#   ./build.sh                 full run (install, register clusters, apply root app)
#   ./build.sh --skip-install  reuse the existing Argo CD release
#   ./build.sh --skip-clusters only re-register the member clusters
#   ./build.sh --skip-root     leave the GitOps root app alone
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
SKIP_INSTALL=false
SKIP_CLUSTERS=false
SKIP_ROOT=false

while (( $# > 0 )); do
  case $1 in
    --skip-install)  SKIP_INSTALL=true ;;
    --skip-clusters) SKIP_CLUSTERS=true ;;
    --skip-root)     SKIP_ROOT=true ;;
    -h|--help)
      sed -n '3,14p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) die "Unknown option: $1 (try --help)" ;;
  esac
  shift
done

# --- helpers specific to this script -----------------------------------------

# kubeconfig server URL for a context's cluster, e.g. https://127.0.0.1:26443
kube_server_for() {
  local ctx=$1 cname
  cname=$(kubectl config view --raw -o jsonpath="{.contexts[?(@.name=='${ctx}')].context.cluster}")
  kubectl config view --raw -o jsonpath="{.clusters[?(@.name=='${cname}')].cluster.server}"
}

# Same URL, but addressed the way a pod inside the deployer cluster must reach it.
# Local clusters publish their API on 127.0.0.1 on the laptop, which is worthless
# to Argo CD, so the node's own internal IP is substituted.
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

ca_data_for() {
  local ctx=$1 cname
  cname=$(kubectl config view --raw -o jsonpath="{.contexts[?(@.name=='${ctx}')].context.cluster}")
  kubectl config view --raw -o jsonpath="{.clusters[?(@.name=='${cname}')].cluster.certificate-authority-data}"
}

token_ready() {
  [[ -n $(kubectl --context "$1" -n "$ARGOCD_MANAGER_NS" \
      get secret "${ARGOCD_MANAGER_SA}-token" -o jsonpath='{.data.token}' 2>/dev/null) ]]
}

# What Argo CD last reported about a registered cluster: status and message.
# The application-controller writes its connection attempt back into the secret.
cluster_state() {
  local decoded
  decoded=$(kubectl --context "$ARGOCD_CONTEXT" -n "$ARGOCD_NAMESPACE" \
    get secret "$1" -o json 2>/dev/null | jq -r '.data // {} | to_entries[] | .value | @base64d') || return 1
  local status message
  status=$(printf '%s\n' "$decoded" | grep -o '"status":"[A-Za-z]*"' | tail -1 | cut -d'"' -f4)
  message=$(printf '%s\n' "$decoded" | grep -o '"message":"[^"]*"' | tail -1 | cut -d'"' -f4)
  printf '%s|%s' "${status:-Unknown}" "${message:-}"
}

wait_cluster_connected() {
  local name=$1 timeout=$2 waited=0 status message
  while true; do
    IFS='|' read -r status message <<<"$(cluster_state "$name")"
    case $status in
      Successful) return 0 ;;
      Failed) info "$name not ready yet: ${message:0:150}" ;;
      *) info "$name connection state not published yet" ;;
    esac
    waited=$((waited + 5))
    (( waited >= timeout )) && return 1
    sleep 5
  done
}

# --- phases ------------------------------------------------------------------

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
  ok "git source reachable with a $GIT_BRANCH branch: $GIT_REPO"
}

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
  if [[ -n $ca ]]; then
    ok "token and CA bundle collected"
  else
    warn "no CA data in kubeconfig for $ctx; registration will use tlsClientConfig.insecure"
  fi

  local urls=() u
  while IFS= read -r u; do
    [[ -n $u ]] && urls+=("$u")
  done < <(candidate_urls "$ctx" "$pinned")
  (( ${#urls[@]} > 0 )) ||
    die "Could not work out any API address for $ctx. Set the 4th field of MANAGED_CLUSTERS in config/bootstrap.env."
  info "candidate API URLs from inside the deployer cluster: ${urls[*]}"

  # Try every address with certificate verification first, then fall back to
  # insecure, since a local API certificate often lacks the node-IP SAN.
  local mode url host i
  for mode in verified insecure; do
    [[ $mode == verified && -z $ca ]] && continue
    for url in "${urls[@]}"; do
      host=${url#*://}; host=${host%%:*}
      info "attempt: $url ($mode)"
      render_cluster_secret "$name" "$url" "$mode" "$token" "$ca"
      if wait_cluster_connected "$name" "$CLUSTER_CONNECT_TIMEOUT"; then
        ok "cluster '$name' connected via $url ($mode)"
        return 0
      fi
    done
  done

  local parts status message
  IFS='|' read -r status message <<<"$(cluster_state "$name")"
  die "Argo CD could not reach $ctx on any candidate (${urls[*]}). Last state: ${message:-$status}.
     Find an address for that API server that works from inside $ARGOCD_CONTEXT,
     put it in MANAGED_CLUSTERS as the 4th field of config/bootstrap.env, and re-run."
}

render_cluster_secret() {
  local name=$1 url=$2 mode=$3 token=$4 ca=$5 tls out
  if [[ $mode == insecure ]]; then
    tls='{"insecure":true}'
  else
    tls=$(jq -nc --arg ca "$ca" '{caData:$ca}')
  fi
  out=$WORK_DIR/clusters/$name.$mode.json
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
        labels: {"argocd.argoproj.io/secret-type": "cluster"}
      },
      type: "Opaque",
      stringData: {
        name: $name,
        server: $server,
        config: ({bearerToken: $token, tlsClientConfig: ($tls | fromjson)} | tojson)
      }
    }' > "$out"
  kubectl --context "$ARGOCD_CONTEXT" apply -f "$out" >/dev/null
}

apply_root() {
  step "Applying the GitOps bootstrap layer to $ARGOCD_CONTEXT"
  kubectl --context "$ARGOCD_CONTEXT" -n "$ARGOCD_NAMESPACE" \
    apply -f argocd/bootstrap/project-argocd-system.yaml >/dev/null
  kubectl --context "$ARGOCD_CONTEXT" -n "$ARGOCD_NAMESPACE" \
    apply -f argocd/bootstrap/root-app.yaml >/dev/null
  ok "AppProject argocd-system and Application argocd-root applied"

  poll "argocd-root to be Synced and Healthy" "$ROLLOUT_TIMEOUT" 10 root_ready ||
    die "argocd-root did not reach Synced/Healthy. Inspect with:
     kubectl --context $ARGOCD_CONTEXT -n $ARGOCD_NAMESPACE get app argocd-root -o yaml"
  ok "argocd-root is Synced and Healthy"

  poll "ApplicationSets to generate their Applications" "$ROLLOUT_TIMEOUT" 10 apps_generated ||
    warn "no Applications generated yet; check the ApplicationSets in the UI"
}

root_ready() {
  local s
  s=$(kubectl --context "$ARGOCD_CONTEXT" -n "$ARGOCD_NAMESPACE" \
    get application argocd-root -o jsonpath='{.status.sync.status} {.status.health.status}' 2>/dev/null) || return 1
  [[ $s == "Synced Healthy" ]]
}

apps_generated() {
  (( $(kubectl --context "$ARGOCD_CONTEXT" -n "$ARGOCD_NAMESPACE" \
        get applications.argoproj.io --no-headers 2>/dev/null | grep -vc '^argocd-root' ) > 0 ))
}

summary() {
  step "Result"
  printf '\n  Clusters known to Argo CD\n'
  kubectl --context "$ARGOCD_CONTEXT" -n "$ARGOCD_NAMESPACE" \
    get secret -l argocd.argoproj.io/secret-type=cluster \
    -o custom-columns='NAME:.metadata.name,SERVER:.stringData.server' --no-headers 2>/dev/null | sed 's/^/    /'

  printf '\n  Applications\n'
  kubectl --context "$ARGOCD_CONTEXT" -n "$ARGOCD_NAMESPACE" \
    get applications.argoproj.io \
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

  Next steps are in README.md (adding an app, promotion, troubleshooting).
EOF
}

main() {
  preflight
  $SKIP_INSTALL || install_argocd
  if $SKIP_CLUSTERS; then
    warn "skipping cluster registration (--skip-clusters)"
  else
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
