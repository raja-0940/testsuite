#!/usr/bin/env bash
# ==============================================================================
# automate-kuadrant-e2e.sh
#
# Unified automation entry point for Kuadrant E2E prerequisites and test execution
# on IBM Power (ppc64le) / OpenShift.
#
# Modes:
#   --check, -c, check       Inspect and report all prerequisites without changes
#   --setup, -s, setup       Idempotently create/configure all missing prerequisites
#   --test,  -t, test, run   Prepare environment and run E2E testsuite in tmux
#   --status,    status      Show status of helpers, tmux sessions, and recent runs
#   --clean,     clean       Scoped cleanup of test-created resources and helper daemons
#
# Usage examples:
#   ./scripts/automate-kuadrant-e2e.sh --check
#   ./scripts/automate-kuadrant-e2e.sh --setup
#   ./scripts/automate-kuadrant-e2e.sh --test
#   ./scripts/automate-kuadrant-e2e.sh --test testsuite/tests/singlecluster/limitador
#   ./scripts/automate-kuadrant-e2e.sh --status
#   ./scripts/automate-kuadrant-e2e.sh --clean
# ==============================================================================

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="${REPO_DIR:-$(dirname "$SCRIPT_DIR")}"
export KUBECONFIG="${KUBECONFIG:-/root/.kube/config}"

# Configuration defaults
SETTINGS_FILE="${SETTINGS_FILE:-${REPO_DIR}/config/settings.local.yaml}"
ENV_FILE="${ENV_FILE:-/tmp/kuadrant-ppc64le-e2e-env.sh}"
RESULTS_ROOT="${RESULTS_ROOT:-/root/test/results}"
TMUX_SESSION="${TMUX_SESSION:-kuadrant-power-full-e2e}"

TOOLS_NS="${TOOLS_NS:-tools}"
TEST_NS="${TEST_NS:-kuadrant}"
TEST_NS2="${TEST_NS2:-kuadrant2}"
KUADRANT_NS="${KUADRANT_NS:-kuadrant-system}"
OP_NS="${OP_NS:-openshift-operators}"
DNS_ZONE="${DNS_ZONE:-kuadrant.internal}"
EXPECTED_WASM_SHA="${EXPECTED_WASM_SHA:-41e298e2}"

DNS_SYNC_HELPER="${DNS_SYNC_HELPER:-${SCRIPT_DIR}/sync-kuadrant-dns-etcd.sh}"
DNS_HELPER_PID_FILE="${DNS_HELPER_PID_FILE:-/tmp/kuadrant-ppc64le-dns-helper.pid}"
DNS_HELPER_LOG="${DNS_HELPER_LOG:-/tmp/kuadrant-ppc64le-dns-helper.log}"

RESET_DNS="${RESET_DNS:-0}"
NO_TMUX="${NO_TMUX:-0}"
SKIP_PREFLIGHT="${SKIP_PREFLIGHT:-0}"
WITH_WASM_WORKAROUND="${WITH_WASM_WORKAROUND:-0}"

# Colors (disabled if non-interactive)
if [[ -t 1 ]]; then
    C_RESET='\033[0m'
    C_BOLD='\033[1m'
    C_GREEN='\033[32m'
    C_YELLOW='\033[33m'
    C_RED='\033[31m'
    C_CYAN='\033[36m'
    C_BLUE='\033[34m'
else
    C_RESET=''
    C_BOLD=''
    C_GREEN=''
    C_YELLOW=''
    C_RED=''
    C_CYAN=''
    C_BLUE=''
fi

log_ts()   { date --iso-8601=seconds; }
log_step() { printf "\n%b[%s] === %s ===%b\n" "$C_CYAN" "$(log_ts)" "$*" "$C_RESET"; }
log_ok()   { printf "%b[%s]   OK   %s%b\n" "$C_GREEN" "$(log_ts)" "$*" "$C_RESET"; }
log_warn() { printf "%b[%s]  WARN  %s%b\n" "$C_YELLOW" "$(log_ts)" "$*" "$C_RESET"; }
log_fail() { printf "%b[%s]  FAIL  %s%b\n" "$C_RED" "$(log_ts)" "$*" "$C_RESET"; }
log_info() { printf "%b[%s]  INFO  %s%b\n" "$C_BLUE" "$(log_ts)" "$*" "$C_RESET"; }

print_header() {
    printf "%b%s%b\n" "$C_BOLD" "================================================================================" "$C_RESET"
    printf "%b Kuadrant E2E Automation for IBM Power (ppc64le)%b\n" "$C_BOLD" "$C_RESET"
    printf "%b Mode: %s | Time: %s%b\n" "$C_CYAN" "${MODE}" "$(log_ts)" "$C_RESET"
    printf "%b%s%b\n" "$C_BOLD" "================================================================================" "$C_RESET"
}

print_cluster_context() {
    log_info "KUBECONFIG: ${KUBECONFIG}"
    local whoami_str
    if whoami_str=$(oc whoami 2>&1); then
        log_info "Cluster User: ${whoami_str}"
    else
        log_fail "Cannot connect to OpenShift: ${whoami_str}"
        return 1
    fi
    local server_url
    server_url=$(oc whoami --show-server 2>/dev/null || echo "unknown")
    log_info "Server: ${server_url}"

    local arch
    arch=$(uname -m)
    log_info "Bastion Host: $(hostname) (${arch})"

    if [[ -d "${REPO_DIR}/.git" ]]; then
        local git_branch git_rev
        git_branch=$(git -C "${REPO_DIR}" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
        git_rev=$(git -C "${REPO_DIR}" rev-parse --short HEAD 2>/dev/null || echo "unknown")
        log_info "Repository: ${REPO_DIR} (${git_branch}@${git_rev})"
    fi
}

# ──────────────────────────────────────────────────────────────────────────────
# Diagnostic / Check Functions
# ──────────────────────────────────────────────────────────────────────────────

CHECK_FAILURES=0

check_cmd() {
    local cmd="$1"
    if command -v "$cmd" >/dev/null 2>&1; then
        log_ok "Command found: $cmd"
    else
        log_fail "Required command missing: $cmd"
        CHECK_FAILURES=$((CHECK_FAILURES + 1))
    fi
}

check_all_tools() {
    log_step "1. Checking Bastion CLI Tools"
    for tool in oc kubectl python3 poetry yq jq tmux curl dig; do
        check_cmd "$tool"
    done
    if command -v cfssl >/dev/null 2>&1; then
        log_ok "Optional tool found: cfssl"
    else
        log_warn "Optional tool cfssl not in PATH (some TLS certificate fixtures use cfssl fallback)"
    fi
}

check_cluster_state() {
    log_step "2. Checking Cluster & Node Health"
    if ! oc whoami >/dev/null 2>&1; then
        log_fail "Not logged into OpenShift cluster (check KUBECONFIG)"
        CHECK_FAILURES=$((CHECK_FAILURES + 1))
        return
    fi
    log_ok "Logged in as $(oc whoami)"

    local unready_nodes
    unready_nodes=$(oc get nodes --no-headers 2>/dev/null | awk '$2!="Ready" {print $1}' || true)
    if [[ -z "$unready_nodes" ]]; then
        local node_cnt
        node_cnt=$(oc get nodes --no-headers 2>/dev/null | wc -l)
        log_ok "All $node_cnt cluster nodes are Ready"
    else
        log_fail "Nodes not Ready: $unready_nodes"
        CHECK_FAILURES=$((CHECK_FAILURES + 1))
    fi

    local degraded_cos
    degraded_cos=$(oc get co --no-headers 2>/dev/null | awk '$3!="True"||$5!="False" {print $1}' || true)
    if [[ -z "$degraded_cos" ]]; then
        log_ok "All ClusterOperators are healthy"
    else
        log_fail "Degraded ClusterOperators: $degraded_cos"
        CHECK_FAILURES=$((CHECK_FAILURES + 1))
    fi
}

check_operators_and_crds() {
    log_step "3. Checking Required Operators and CRDs"

    local csv_json
    csv_json=$(oc get csv -n "${OP_NS}" -o json 2>/dev/null || echo "{}")

    # RHCL operator
    local rhcl_csv rhcl_name
    rhcl_csv=$(echo "$csv_json" | jq -r '.items[]? | select(.metadata.name | test("rhcl-operator")) | .status.phase' | head -1 || echo "missing")
    rhcl_name=$(echo "$csv_json" | jq -r '.items[]? | select(.metadata.name | test("rhcl-operator")) | .metadata.name' | head -1 || echo "unknown")
    if [[ "$rhcl_csv" == "Succeeded" ]]; then
        log_ok "RHCL Operator CSV Succeeded: ${rhcl_name}"
    else
        log_fail "RHCL Operator CSV not Succeeded (status: $rhcl_csv)"
        CHECK_FAILURES=$((CHECK_FAILURES + 1))
    fi

    # Service Mesh 3 / Sail
    local sm_csv sm_name
    sm_csv=$(echo "$csv_json" | jq -r '.items[]? | select(.metadata.name | test("servicemeshoperator3")) | .status.phase' | head -1 || echo "missing")
    sm_name=$(echo "$csv_json" | jq -r '.items[]? | select(.metadata.name | test("servicemeshoperator3")) | .metadata.name' | head -1 || echo "unknown")
    if [[ "$sm_csv" == "Succeeded" ]]; then
        log_ok "ServiceMesh 3 Operator CSV Succeeded: ${sm_name}"
    else
        log_fail "ServiceMesh 3 Operator CSV not Succeeded (status: $sm_csv)"
        CHECK_FAILURES=$((CHECK_FAILURES + 1))
    fi

    # cert-manager
    local cm_csv cm_name
    cm_csv=$(echo "$csv_json" | jq -r '.items[]? | select(.metadata.name | test("cert-manager-operator")) | .status.phase' | head -1 || echo "missing")
    cm_name=$(echo "$csv_json" | jq -r '.items[]? | select(.metadata.name | test("cert-manager-operator")) | .metadata.name' | head -1 || echo "unknown")
    if [[ "$cm_csv" == "Succeeded" ]]; then
        log_ok "cert-manager Operator CSV Succeeded: ${cm_name}"
    else
        log_fail "cert-manager Operator CSV not Succeeded (status: $cm_csv)"
        CHECK_FAILURES=$((CHECK_FAILURES + 1))
    fi

    # MetalLB
    local metallb_csv metallb_name
    metallb_csv=$(echo "$csv_json" | jq -r '.items[]? | select(.metadata.name | test("metallb-operator")) | .status.phase' | head -1 || echo "missing")
    metallb_name=$(echo "$csv_json" | jq -r '.items[]? | select(.metadata.name | test("metallb-operator")) | .metadata.name' | head -1 || echo "unknown")
    if [[ "$metallb_csv" == "Succeeded" ]]; then
        log_ok "MetalLB Operator CSV Succeeded: ${metallb_name}"
    else
        log_fail "MetalLB Operator CSV not Succeeded (status: $metallb_csv)"
        CHECK_FAILURES=$((CHECK_FAILURES + 1))
    fi

    # MetalLB IPAddressPool
    if oc get ipaddresspool -n metallb-system gateway-pool >/dev/null 2>&1; then
        local pool_ips
        pool_ips=$(oc get ipaddresspool -n metallb-system gateway-pool -o jsonpath='{.spec.addresses[*]}' 2>/dev/null)
        log_ok "MetalLB gateway-pool present: ${pool_ips}"
    else
        log_fail "MetalLB gateway-pool missing in metallb-system"
        CHECK_FAILURES=$((CHECK_FAILURES + 1))
    fi

    # GatewayClass istio
    if oc get gatewayclass istio >/dev/null 2>&1; then
        log_ok "GatewayClass istio present and accepted"
    else
        log_fail "GatewayClass istio missing"
        CHECK_FAILURES=$((CHECK_FAILURES + 1))
    fi

    # ClusterIssuer kuadrant-qe-issuer
    if oc get clusterissuer kuadrant-qe-issuer >/dev/null 2>&1; then
        local ci_ready
        ci_ready=$(oc get clusterissuer kuadrant-qe-issuer -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "unknown")
        if [[ "$ci_ready" == "True" ]]; then
            log_ok "ClusterIssuer kuadrant-qe-issuer Ready"
        else
            log_warn "ClusterIssuer kuadrant-qe-issuer present but Ready=$ci_ready"
        fi
    else
        log_fail "ClusterIssuer kuadrant-qe-issuer missing"
        CHECK_FAILURES=$((CHECK_FAILURES + 1))
    fi
}

check_kuadrant_and_components() {
    log_step "4. Checking Kuadrant CR, Authorino, Limitador, and Tracing"

    # Kuadrant CR
    local kd_ready
    kd_ready=$(oc get kuadrant kuadrant -n "${KUADRANT_NS}" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "missing")
    if [[ "$kd_ready" == "True" ]]; then
        log_ok "Kuadrant CR 'kuadrant' in ${KUADRANT_NS} is Ready"
    else
        log_fail "Kuadrant CR 'kuadrant' not Ready (status: $kd_ready)"
        CHECK_FAILURES=$((CHECK_FAILURES + 1))
    fi

    # dataPlane observability
    local dp_header
    dp_header=$(oc get kuadrant kuadrant -n "${KUADRANT_NS}" -o jsonpath='{.spec.observability.dataPlane.httpHeaderIdentifier}' 2>/dev/null || echo "")
    if [[ "$dp_header" == "x-request-id" ]]; then
        log_ok "Kuadrant CR dataPlane observability configured (httpHeaderIdentifier: x-request-id)"
    else
        log_fail "Kuadrant CR dataPlane observability missing or incorrect (got: '$dp_header')"
        CHECK_FAILURES=$((CHECK_FAILURES + 1))
    fi

    # Authorino deployment and cluster-trust-bundle
    local auth_ready
    auth_ready=$(oc get deployment authorino -n "${KUADRANT_NS}" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
    if [[ "${auth_ready:-0}" -ge 1 ]]; then
        log_ok "Authorino deployment ready in ${KUADRANT_NS} (${auth_ready} replicas)"
    else
        log_fail "Authorino deployment not ready in ${KUADRANT_NS}"
        CHECK_FAILURES=$((CHECK_FAILURES + 1))
    fi

    local auth_vols
    auth_vols=$(oc get authorino authorino -n "${KUADRANT_NS}" -o jsonpath='{.spec.volumes.items[?(@.name=="cluster-trust-bundle")].name}' 2>/dev/null || echo "")
    if [[ "$auth_vols" == "cluster-trust-bundle" ]]; then
        log_ok "Authorino CR has cluster-trust-bundle volume configured"
    else
        log_fail "Authorino CR missing cluster-trust-bundle volume (needed for egress tests)"
        CHECK_FAILURES=$((CHECK_FAILURES + 1))
    fi

    # Limitador deployment
    local lim_ready
    lim_ready=$(oc get deployment limitador-limitador -n "${KUADRANT_NS}" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
    if [[ "${lim_ready:-0}" -ge 1 ]]; then
        log_ok "Limitador deployment ready in ${KUADRANT_NS}"
    else
        log_fail "Limitador deployment not ready in ${KUADRANT_NS}"
        CHECK_FAILURES=$((CHECK_FAILURES + 1))
    fi

    # Operator OTEL tracing Subscription env
    local op_sub_env
    op_sub_env=$(oc get sub -n "${OP_NS}" rhcl-operator -o jsonpath='{.spec.config.env[?(@.name=="OTEL_EXPORTER_OTLP_ENDPOINT")].value}' 2>/dev/null || echo "")
    if [[ -n "$op_sub_env" ]]; then
        log_ok "Operator Subscription has OTEL tracing configured ($op_sub_env)"
    else
        log_fail "Operator Subscription missing OTEL_EXPORTER_OTLP_ENDPOINT"
        CHECK_FAILURES=$((CHECK_FAILURES + 1))
    fi

    # Istio tracing (meshConfig + Telemetry)
    local istio_tracing
    istio_tracing=$(oc get istio default -n istio-system -o jsonpath='{.spec.values.meshConfig.enableTracing}' 2>/dev/null || echo "false")
    if [[ "$istio_tracing" == "true" ]]; then
        log_ok "Istio default CR has enableTracing: true"
    else
        log_fail "Istio default CR enableTracing is not true"
        CHECK_FAILURES=$((CHECK_FAILURES + 1))
    fi

    if oc get telemetry -n istio-system default-telemetry >/dev/null 2>&1; then
        log_ok "Telemetry 'default-telemetry' present in istio-system"
    else
        log_fail "Telemetry 'default-telemetry' missing in istio-system"
        CHECK_FAILURES=$((CHECK_FAILURES + 1))
    fi

    # Served Wasm binary SHA
    local op_pod
    op_pod=$(oc get pod -n "${OP_NS}" -o name 2>/dev/null | grep kuadrant-operator-controller | head -1)
    if [[ -n "$op_pod" ]]; then
        local served_sha
        served_sha=$(oc exec -n "${OP_NS}" "$op_pod" -c manager -- sha256sum /wasm/plugin.wasm 2>/dev/null | awk '{print $1}' || echo "error")
        if [[ "$served_sha" =~ ^${EXPECTED_WASM_SHA} ]]; then
            log_ok "Served wasm plugin matches expected SHA prefix (${served_sha:0:12})"
        else
            log_warn "Served wasm sha ($served_sha) does not match expected prefix (${EXPECTED_WASM_SHA})"
        fi
    fi
}

check_tools_and_dependencies() {
    log_step "5. Checking Tools Namespace and Endpoints"

    for app in etcd coredns keycloak mockserver jaeger vault; do
        local r_rep
        r_rep=$(oc get deployment "$app" -n "${TOOLS_NS}" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
        if [[ "${r_rep:-0}" -ge 1 ]]; then
            log_ok "Tool '$app' ready in ${TOOLS_NS}"
        else
            log_fail "Tool '$app' not ready in ${TOOLS_NS}"
            CHECK_FAILURES=$((CHECK_FAILURES + 1))
        fi
    done

    # Routes functional check
    local kc_host mock_host vault_host jaeger_host
    kc_host=$(oc get route keycloak -n "${TOOLS_NS}" -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
    mock_host=$(oc get route mockserver -n "${TOOLS_NS}" -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
    vault_host=$(oc get route vault -n "${TOOLS_NS}" -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
    jaeger_host=$(oc get route jaeger-query -n "${TOOLS_NS}" -o jsonpath='{.spec.host}' 2>/dev/null || echo "")

    if [[ -n "$mock_host" ]]; then
        local mock_status
        mock_status=$(curl -s -X PUT "http://${mock_host}/mockserver/status" 2>/dev/null | jq -r '.version' 2>/dev/null || echo "")
        if [[ -n "$mock_status" ]]; then
            log_ok "MockServer API responsive (version: $mock_status, http://${mock_host})"
        else
            log_fail "MockServer endpoint unresponsive at http://${mock_host}"
            CHECK_FAILURES=$((CHECK_FAILURES + 1))
        fi
    fi

    if [[ -n "$kc_host" ]]; then
        local kc_status
        kc_status=$(curl -s "http://${kc_host}/realms/master/.well-known/openid-configuration" 2>/dev/null | jq -r '.issuer' 2>/dev/null || echo "")
        if [[ -n "$kc_status" ]]; then
            log_ok "Keycloak master realm responsive ($kc_status)"
        else
            log_fail "Keycloak endpoint unresponsive at http://${kc_host}"
            CHECK_FAILURES=$((CHECK_FAILURES + 1))
        fi
    fi

    if [[ -n "$vault_host" ]]; then
        local vault_health
        vault_health=$(curl -sf -o /dev/null -w "%{http_code}" "http://${vault_host}/v1/sys/health" 2>/dev/null || echo "000")
        if [[ "$vault_health" == "200" || "$vault_health" == "429" || "$vault_health" == "472" || "$vault_health" == "473" ]]; then
            log_ok "Vault sys/health responsive (code: $vault_health, http://${vault_host})"
        else
            log_fail "Vault sys/health unresponsive (code: $vault_health)"
            CHECK_FAILURES=$((CHECK_FAILURES + 1))
        fi
    fi

    if [[ -n "$jaeger_host" ]]; then
        local jaeger_services
        jaeger_services=$(curl -sf "http://${jaeger_host}/api/services" 2>/dev/null | jq -r '.data | length' 2>/dev/null || echo "-1")
        if [[ "$jaeger_services" -ge 0 ]]; then
            log_ok "Jaeger query API responsive ($jaeger_services services reported, http://${jaeger_host})"
        else
            log_fail "Jaeger query endpoint unresponsive at http://${jaeger_host}"
            CHECK_FAILURES=$((CHECK_FAILURES + 1))
        fi
    fi

    # Thanos Querier / Prometheus check
    local thanos_host
    thanos_host=$(oc get route thanos-querier -n openshift-monitoring -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
    if [[ -n "$thanos_host" ]]; then
        local token
        token=$(oc whoami --show-token 2>/dev/null || echo "")
        if [[ -n "$token" ]]; then
            local prom_status
            prom_status=$(curl -k -s -H "Authorization: Bearer $token" "https://${thanos_host}/api/v1/query?query=up" 2>/dev/null | jq -r '.status' 2>/dev/null || echo "")
            if [[ "$prom_status" == "success" ]]; then
                log_ok "Thanos Querier Prometheus API responsive with current OCP token"
            else
                log_fail "Thanos Querier returned status '$prom_status' (check token/permissions)"
                CHECK_FAILURES=$((CHECK_FAILURES + 1))
            fi
        fi
    fi

    # Vault kubernetes auth method
    local v_k8s_auth
    v_k8s_auth=$(oc exec -n "${TOOLS_NS}" deploy/vault -- sh -c 'export VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=${VAULT_DEV_ROOT_TOKEN_ID}; vault auth list' 2>/dev/null | grep "^kubernetes/" || echo "")
    if [[ -n "$v_k8s_auth" ]]; then
        log_ok "Vault has 'kubernetes/' auth method enabled"
    else
        log_fail "Vault missing 'kubernetes/' auth method (needed by egress tests)"
        CHECK_FAILURES=$((CHECK_FAILURES + 1))
    fi
}

check_dns_and_settings() {
    log_step "6. Checking DNS Infrastructure, Settings, and Helper Daemon"

    # kuadrant-coredns NodePort
    local kd_np
    kd_np=$(oc get svc kuadrant-coredns -n kuadrant-coredns -o jsonpath='{.spec.ports[?(@.protocol=="UDP")].nodePort}' 2>/dev/null || echo "")
    if [[ -n "$kd_np" ]]; then
        log_ok "kuadrant-coredns NodePort service present (port: $kd_np)"
    else
        log_fail "kuadrant-coredns NodePort service missing in kuadrant-coredns namespace"
        CHECK_FAILURES=$((CHECK_FAILURES + 1))
    fi

    # coredns-credentials secrets
    for ns in "${TEST_NS}" "${TEST_NS2}"; do
        if oc get secret coredns-credentials -n "$ns" >/dev/null 2>&1; then
            log_ok "coredns-credentials secret exists in $ns"
        else
            log_fail "coredns-credentials secret missing in $ns"
            CHECK_FAILURES=$((CHECK_FAILURES + 1))
        fi
    done

    # Settings file
    if [[ -f "$SETTINGS_FILE" ]]; then
        local perms
        perms=$(stat -c "%a" "$SETTINGS_FILE" 2>/dev/null || stat -f "%Lp" "$SETTINGS_FILE" 2>/dev/null || echo "unknown")
        log_ok "Settings file exists: $SETTINGS_FILE (permissions: $perms)"
        if [[ "$perms" != "600" && "$perms" != "0600" ]]; then
            log_warn "Settings file contains sensitive credentials but permissions are $perms (should be 0600)"
        fi

        # Validate token in settings
        local token_in_file
        token_in_file=$(yq '.default.control_plane.cluster.token // ""' "$SETTINGS_FILE" 2>/dev/null || echo "")
        if [[ -n "$token_in_file" && "$token_in_file" != "null" ]]; then
            if oc --token="$token_in_file" whoami >/dev/null 2>&1; then
                log_ok "Control plane cluster token in settings.local.yaml is valid"
            else
                log_fail "Control plane cluster token in settings.local.yaml is expired/invalid (re-run setup to refresh)"
                CHECK_FAILURES=$((CHECK_FAILURES + 1))
            fi
        else
            log_warn "No control_plane.cluster.token in settings.local.yaml"
        fi
    else
        log_fail "Settings file missing: $SETTINGS_FILE (run --setup to generate)"
        CHECK_FAILURES=$((CHECK_FAILURES + 1))
    fi

    # DNS helper daemon
    if pgrep -f sync-kuadrant-dns-etcd.sh >/dev/null 2>&1; then
        local pid
        pid=$(pgrep -f sync-kuadrant-dns-etcd.sh | head -1)
        log_ok "DNS sync helper daemon is running (PID: $pid)"
    else
        log_warn "DNS sync helper daemon is NOT running (run --setup to start)"
    fi
}

run_check_mode() {
    print_header
    print_cluster_context || exit 1

    check_all_tools
    check_cluster_state
    check_operators_and_crds
    check_kuadrant_and_components
    check_tools_and_dependencies
    check_dns_and_settings

    log_step "Diagnostic Summary"
    if [[ $CHECK_FAILURES -eq 0 ]]; then
        log_ok "All prerequisite checks PASSED! Environment is ready for Kuadrant E2E."
        return 0
    else
        log_fail "Total prerequisite check failures: $CHECK_FAILURES"
        log_info "Run './scripts/automate-kuadrant-e2e.sh --setup' to automatically resolve prerequisites."
        return 1
    fi
}

# ──────────────────────────────────────────────────────────────────────────────
# Setup / Remediation Functions
# ──────────────────────────────────────────────────────────────────────────────

run_setup_mode() {
    print_header
    print_cluster_context || exit 1

    log_step "1. Validating Essential Cluster Prerequisites"
    if ! oc whoami >/dev/null 2>&1; then
        log_fail "Cannot connect to OpenShift cluster. Please check KUBECONFIG."
        exit 1
    fi

    log_step "2. Ensuring Test and Infrastructure Namespaces"
    for ns in "${TOOLS_NS}" "${TEST_NS}" "${TEST_NS2}" "kuadrant-coredns"; do
        if ! oc get namespace "$ns" >/dev/null 2>&1; then
            log_info "Creating namespace: $ns"
            oc create namespace "$ns" >/dev/null
            log_ok "Namespace created: $ns"
        else
            log_ok "Namespace exists: $ns"
        fi
    done

    log_step "3. Applying Authorino & Vault Egress Prerequisites"
    if [[ -x "${SCRIPT_DIR}/setup-egress-vault-authorino.sh" ]]; then
        "${SCRIPT_DIR}/setup-egress-vault-authorino.sh"
        log_ok "setup-egress-vault-authorino.sh applied successfully"
    else
        log_fail "Executable missing: ${SCRIPT_DIR}/setup-egress-vault-authorino.sh"
        exit 1
    fi

    log_step "4. Applying Operator OTEL Tracing Subscription Configuration"
    if [[ -x "${SCRIPT_DIR}/setup-operator-tracing.sh" ]]; then
        "${SCRIPT_DIR}/setup-operator-tracing.sh"
        log_ok "setup-operator-tracing.sh applied successfully"
    else
        log_fail "Executable missing: ${SCRIPT_DIR}/setup-operator-tracing.sh"
        exit 1
    fi

    log_step "5. Applying Kuadrant CR dataPlane Observability Configuration"
    if [[ -x "${SCRIPT_DIR}/setup-dataplane-observability.sh" ]]; then
        "${SCRIPT_DIR}/setup-dataplane-observability.sh"
        log_ok "setup-dataplane-observability.sh applied successfully"
    else
        log_fail "Executable missing: ${SCRIPT_DIR}/setup-dataplane-observability.sh"
        exit 1
    fi

    log_step "6. Configuring Istio Distributed Tracing and Telemetry"
    if oc get istio default -n istio-system >/dev/null 2>&1; then
        make -C "${REPO_DIR}" configure-istio-tracing TOOLS_NAMESPACE="${TOOLS_NS}"
        log_ok "Istio tracing and Telemetry CR configured"
    else
        log_warn "Istio default CR not found in istio-system, skipping Istio tracing patch"
    fi

    log_step "7. Deploying Kuadrant-CoreDNS Service (DNSRecords plugin)"
    if [[ -x "${SCRIPT_DIR}/setup-kuadrant-coredns.sh" ]]; then
        "${SCRIPT_DIR}/setup-kuadrant-coredns.sh"
        log_ok "setup-kuadrant-coredns.sh applied successfully"
    else
        log_fail "Executable missing: ${SCRIPT_DIR}/setup-kuadrant-coredns.sh"
        exit 1
    fi

    log_step "8. Optional Wasm Workaround Check"
    if [[ "$WITH_WASM_WORKAROUND" == "1" ]]; then
        if [[ -x "${SCRIPT_DIR}/apply-wasm-be-fix.sh" ]]; then
            log_info "Executing apply-wasm-be-fix.sh (--with-wasm-workaround specified)"
            "${SCRIPT_DIR}/apply-wasm-be-fix.sh"
            log_ok "apply-wasm-be-fix.sh applied"
        else
            log_warn "apply-wasm-be-fix.sh not found or not executable"
        fi
    else
        log_info "Standard setup: Preserving existing served wasm binary (opt-in via --with-wasm-workaround)"
    fi

    log_step "9. Executing Core Pre-E2E Setup and DNS Discovery"
    if [[ -x "${SCRIPT_DIR}/kuadrant-pre-e2e.sh" ]]; then
        RESET_DNS="${RESET_DNS}" "${SCRIPT_DIR}/kuadrant-pre-e2e.sh"
        log_ok "kuadrant-pre-e2e.sh executed successfully"
    else
        log_fail "Executable missing: ${SCRIPT_DIR}/kuadrant-pre-e2e.sh"
        exit 1
    fi

    # Secure permissions on settings file
    if [[ -f "$SETTINGS_FILE" ]]; then
        chmod 0600 "$SETTINGS_FILE"
        log_ok "Secured file permissions (0600) on $SETTINGS_FILE"
    fi

    log_step "10. Setup Verification"
    log_info "Verifying resulting environment..."
    run_check_mode
}

# ──────────────────────────────────────────────────────────────────────────────
# Test Execution Functions
# ──────────────────────────────────────────────────────────────────────────────

run_test_mode() {
    local -a test_targets=("$@")

    print_header
    print_cluster_context || exit 1

    log_step "1. Running Environment Pre-Setup and Checks"
    run_setup_mode

    log_step "2. Checking for Overlapping Pytest Runs"
    if pgrep -f "^[^ ]*python[0-9.]* -u -m pytest" >/dev/null 2>&1; then
        log_fail "Another pytest execution is currently active! Please wait or terminate it before starting a new run."
        exit 1
    fi
    log_ok "No conflicting pytest processes detected"

    local ts run_dir
    ts="$(date +%Y%m%d-%H%M%S)"
    run_dir="${RESULTS_ROOT}/full-e2e-${ts}"
    mkdir -p "$run_dir"

    log_info "Results directory: $run_dir"

    # Export configuration into runner environment
    export RESULTS_ROOT="${RESULTS_ROOT}"
    export RUN_DIR="${run_dir}"
    export KCFG="${KUBECONFIG}"

    if [[ ${#test_targets[@]} -gt 0 ]]; then
        log_info "Custom test targets: ${test_targets[*]}"
    else
        log_info "Running full Kuadrant singlecluster test suite"
    fi

    if [[ "$NO_TMUX" == "1" ]]; then
        log_step "3. Executing E2E in Foreground"
        if [[ ${#test_targets[@]} -gt 0 ]]; then
            RESULTS_DIR="$run_dir" RUN_NAME="group" "${SCRIPT_DIR}/run-kuadrant-e2e.sh" "${test_targets[@]}"
        else
            "${SCRIPT_DIR}/run-full-e2e-power.sh"
        fi
    else
        log_step "3. Launching E2E in Dedicated tmux Session (${TMUX_SESSION})"
        if tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
            log_warn "tmux session '${TMUX_SESSION}' already exists. Killing existing session."
            tmux kill-session -t "$TMUX_SESSION" 2>/dev/null || true
            sleep 1
        fi

        local run_cmd
        if [[ ${#test_targets[@]} -gt 0 ]]; then
            run_cmd="cd ${REPO_DIR} && RESULTS_DIR=${run_dir} RUN_NAME=group ${SCRIPT_DIR}/run-kuadrant-e2e.sh ${test_targets[*]}; exec bash"
        else
            run_cmd="cd ${REPO_DIR} && RUN_DIR=${run_dir} ${SCRIPT_DIR}/run-full-e2e-power.sh; exec bash"
        fi

        tmux new -d -s "$TMUX_SESSION" "$run_cmd"
        log_ok "tmux session started: $TMUX_SESSION"

        printf "\n%b%s%b\n" "$C_BOLD" "================================================================================" "$C_RESET"
        printf "%b  Kuadrant E2E Execution Started in tmux%b\n" "$C_GREEN" "$C_RESET"
        printf "  Session Name   : %b%s%b\n" "$C_CYAN" "$TMUX_SESSION" "$C_RESET"
        printf "  Artifacts Dir  : %s\n" "$run_dir"
        printf "  Log File       : %s/full-e2e.log\n" "$run_dir"
        printf "\n%b  Monitor Commands:%b\n" "$C_BOLD" "$C_RESET"
        printf "    %b$ tmux attach -t %s%b        (detach: Ctrl-b d)\n" "$C_CYAN" "$TMUX_SESSION" "$C_RESET"
        printf "    %b$ tail -n 100 -f %s/full-e2e.log%b\n" "$C_CYAN" "$run_dir" "$C_RESET"
        printf "%b%s%b\n\n" "$C_BOLD" "================================================================================" "$C_RESET"
    fi
}

# ──────────────────────────────────────────────────────────────────────────────
# Status & Scoped Cleanup Functions
# ──────────────────────────────────────────────────────────────────────────────

run_status_mode() {
    print_header
    print_cluster_context || true

    log_step "1. tmux Sessions"
    if tmux list-sessions 2>/dev/null; then
        log_ok "tmux server active"
    else
        log_info "No active tmux sessions"
    fi

    log_step "2. Active Pytest / E2E Processes"
    local py_pids
    py_pids=$(pgrep -f "pytest" || true)
    if [[ -n "$py_pids" ]]; then
        log_warn "Active pytest PID(s): $py_pids"
        ps -f -p $py_pids 2>/dev/null || true
    else
        log_ok "No active pytest processes"
    fi

    log_step "3. DNS Helper Daemon"
    if pgrep -f sync-kuadrant-dns-etcd.sh >/dev/null 2>&1; then
        local dns_pid
        dns_pid=$(pgrep -f sync-kuadrant-dns-etcd.sh | head -1)
        log_ok "DNS helper running (PID: $dns_pid, log: $DNS_HELPER_LOG)"
    else
        log_info "DNS helper is not running"
    fi

    log_step "4. Latest Test Results"
    if [[ -d "$RESULTS_ROOT" ]]; then
        local latest_dir
        latest_dir=$(ls -td "${RESULTS_ROOT}"/full-e2e-* 2>/dev/null | head -1 || true)
        if [[ -n "$latest_dir" && -d "$latest_dir" ]]; then
            log_info "Latest run directory: $latest_dir"
            if [[ -f "${latest_dir}/summary.txt" ]]; then
                printf '\n%s\n' "--- Summary ---"
                cat "${latest_dir}/summary.txt"
                printf '%s\n' "----------------"
            fi
            if [[ -f "${latest_dir}/failures.txt" ]]; then
                local fail_cnt
                fail_cnt=$(wc -l < "${latest_dir}/failures.txt")
                log_info "Failures recorded in run: $fail_cnt"
            fi
        fi
    fi
}

run_clean_mode() {
    print_header
    print_cluster_context || true

    log_step "1. Stopping DNS Helper Daemon"
    if [[ -f "$DNS_HELPER_PID_FILE" ]]; then
        local pid
        pid=$(cat "$DNS_HELPER_PID_FILE" 2>/dev/null || true)
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null || true
            log_ok "Killed DNS helper daemon (PID: $pid)"
        fi
        rm -f "$DNS_HELPER_PID_FILE"
    fi
    pkill -f sync-kuadrant-dns-etcd.sh 2>/dev/null || true
    log_ok "DNS helper daemon stopped"

    log_step "2. Cleaning Orphaned Test-Created Cluster Resources"
    log_info "Cleaning leftover test objects in namespace ${TEST_NS} (USER=root)..."
    make -C "${REPO_DIR}" clean USER=root 2>/dev/null || true

    # Clean leftover gateways in kuadrant / kuadrant2 if any
    for ns in "${TEST_NS}" "${TEST_NS2}"; do
        local gws
        gws=$(oc get gateway -n "$ns" --no-headers 2>/dev/null | awk '{print $1}' || true)
        if [[ -n "$gws" ]]; then
            log_info "Deleting test gateways in $ns: $gws"
            oc delete gateway $gws -n "$ns" --ignore-not-found 2>/dev/null || true
        fi
    done
    log_ok "Scoped cleanup finished (persistent infrastructure and tools preserved)"
}

print_usage() {
    cat <<EOF
Usage: $0 [MODE] [OPTIONS] [TARGETS...]

Modes:
  -c, --check, check         Inspect all Kuadrant E2E prerequisites without making changes.
  -s, --setup, setup         Idempotently configure/reconcile all missing prerequisites.
  -t, --test,  test, run     Run setup and execute the E2E test suite in a tmux session.
  --status,    status        Display status of tmux sessions, active tests, and helpers.
  --clean,     clean         Scoped cleanup of test-created gateways/resources & daemons.
  -h, --help                 Display this help message.

Options:
  --target <path>            Specify pytest target path/file (e.g. testsuite/tests/singlecluster/limitador)
  --session-name <name>      Name of the tmux session (default: kuadrant-power-full-e2e)
  --no-tmux                  Run tests directly in foreground instead of detached tmux
  --results-root <path>      Directory where timestamped test runs are saved (default: /root/test/results)
  --reset-dns                Force restart of the DNS sync helper daemon
  --with-wasm-workaround     Explicitly execute apply-wasm-be-fix.sh during setup
  --skip-preflight           Skip preflight checks before running tests

Examples:
  $0 --check
  $0 --setup
  $0 --test
  $0 --test testsuite/tests/singlecluster/limitador
  $0 --test testsuite/tests/singlecluster/authorino/identity/keycloak
  $0 --status
  $0 --clean
EOF
}

# ──────────────────────────────────────────────────────────────────────────────
# Main Dispatcher
# ──────────────────────────────────────────────────────────────────────────────

MODE="test"
TARGETS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        -c|--check|check)
            MODE="check"
            shift
            ;;
        -s|--setup|setup)
            MODE="setup"
            shift
            ;;
        -t|--test|test|--run|run|--setup-and-test)
            MODE="test"
            shift
            ;;
        --status|status)
            MODE="status"
            shift
            ;;
        --clean|clean)
            MODE="clean"
            shift
            ;;
        --no-tmux)
            NO_TMUX=1
            shift
            ;;
        --reset-dns)
            RESET_DNS=1
            shift
            ;;
        --with-wasm-workaround)
            WITH_WASM_WORKAROUND=1
            shift
            ;;
        --skip-preflight)
            SKIP_PREFLIGHT=1
            shift
            ;;
        --session-name)
            TMUX_SESSION="$2"
            shift 2
            ;;
        --results-root)
            RESULTS_ROOT="$2"
            shift 2
            ;;
        --target|--targets)
            TARGETS+=("$2")
            shift 2
            ;;
        -h|--help|help)
            print_usage
            exit 0
            ;;
        *)
            TARGETS+=("$1")
            shift
            ;;
    esac
done

case "$MODE" in
    check)
        run_check_mode
        ;;
    setup)
        run_setup_mode
        ;;
    test)
        run_test_mode "${TARGETS[@]}"
        ;;
    status)
        run_status_mode
        ;;
    clean)
        run_clean_mode
        ;;
    *)
        log_fail "Unknown mode: $MODE"
        print_usage
        exit 1
        ;;
esac
