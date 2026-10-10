#!/usr/bin/env bash
# Full Kuadrant e2e run on ppc64le with the established Power workarounds.
#
# Thin wrapper around run-kuadrant-e2e.sh (same pytest options, no extra deselections):
#   - non-sensitive preflight (cluster, RHCL CSV, BE wasm, dataPlane, Istio tracing, helpers, token validity)
#   - timestamped result directory outside the repo
#   - full-e2e.log / junit-full-e2e.xml / report-full-e2e.html / exit-code.txt / environment.txt
#   - summary.txt + failures.txt generated from the JUnit file after the run
#
# Usage (inside tmux):
#   tmux new -d -s kuadrant-power-full-e2e "cd /root/test/testsuite && ./scripts/run-full-e2e-power.sh; exec bash"
#
# Environment overrides:
#   RESULTS_ROOT           parent of the run directory (default: /root/test/results)
#   RUN_DIR                explicit run directory (default: $RESULTS_ROOT/full-e2e-<ts>)
#   COREDNS_PORT_OVERRIDE  DNS port for *.kuadrant.internal (default: kuadrant-coredns Service NodePort, e.g. 30554)
#   EXPECTED_WASM_SHA      sha256 prefix of the served wasm (default: v0.15.0 BE build)
#   SKIP_PREFLIGHT=1       skip the preflight checks

set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
RESULTS_ROOT="${RESULTS_ROOT:-/root/test/results}"
RUN_DIR="${RUN_DIR:-${RESULTS_ROOT}/full-e2e-$(date +%Y%m%d-%H%M%S)}"
KCFG="${KCFG:-/root/openstack-upi/auth/kubeconfig}"
# kuadrant-coredns NodePort (serves DNSRecord CRs); discovered from the Service, 30554 only as last resort
export COREDNS_PORT_OVERRIDE="${COREDNS_PORT_OVERRIDE:-$(KUBECONFIG="$KCFG" oc get svc kuadrant-coredns -n kuadrant-coredns \
    -o jsonpath='{.spec.ports[?(@.protocol=="UDP")].nodePort}' 2>/dev/null || true)}"
export COREDNS_PORT_OVERRIDE="${COREDNS_PORT_OVERRIDE:-30554}"
EXPECTED_WASM_SHA="${EXPECTED_WASM_SHA:-41e298e2}"
SETTINGS="${REPO_DIR}/config/settings.local.yaml"

mkdir -p "$RUN_DIR"
ENVF="${RUN_DIR}/environment.txt"

check() { # name, command... ; prints OK/FAIL, never the command output itself
    local name="$1"; shift
    if "$@" >/dev/null 2>&1; then echo "OK   $name"; else echo "FAIL $name"; FAILED=1; fi
}

operator_deny_body_ok() { # pod ; the official binary contains the quoted CEL literal "Too Many Requests\n"
    local needle='"Too Many Requests\n"'
    oc exec -n openshift-operators "$1" -c manager -- cat /manager | grep -aqF "$needle"
}

preflight() {
    FAILED=0
    export KUBECONFIG="$KCFG"
    local op_pod
    op_pod=$(oc get pod -n openshift-operators -o name | grep kuadrant-operator-controller | head -1)
    check "no other pytest running" bash -c '! pgrep -f "^[^ ]*python[0-9.]* -u -m pytest" >/dev/null'
    check "all nodes Ready" bash -c '! oc get nodes --no-headers | awk "\$2!=\"Ready\"" | grep -q .'
    check "cluster operators healthy" bash -c '! oc get co --no-headers | awk "\$3!=\"True\"||\$5!=\"False\"" | grep -q .'
    check "rhcl CSV Succeeded" bash -c 'oc get csv -n openshift-operators --no-headers | grep -q "rhcl-operator.*Succeeded"'
    check "Kuadrant CR Ready" bash -c '[ "$(oc get kuadrant -n kuadrant-system kuadrant -o jsonpath="{.status.conditions[?(@.type==\"Ready\")].status}")" = True ]'
    check "served wasm sha ${EXPECTED_WASM_SHA}" bash -c "oc exec -n openshift-operators $op_pod -c manager -- sha256sum /wasm/plugin.wasm | grep -q ^${EXPECTED_WASM_SHA}"
    check "Kuadrant CR dataPlane observability" bash -c 'oc get kuadrant -n kuadrant-system kuadrant -o jsonpath="{.spec.observability.dataPlane.httpHeaderIdentifier}" | grep -q x-request-id'
    check "Istio tracing (Telemetry + meshConfig)" bash -c 'oc get telemetry -n istio-system default-telemetry && [ "$(oc get istio default -o jsonpath="{.spec.values.meshConfig.enableTracing}")" = true ]'
    check "DNS helper running" pgrep -f sync-kuadrant-dns-etcd.sh
    check "operator emits quoted denyWith body (unmodified /manager)" operator_deny_body_ok "$op_pod"
    check "kuadrant-coredns NodePort ${COREDNS_PORT_OVERRIDE}" bash -c "oc get svc -n kuadrant-coredns kuadrant-coredns -o jsonpath='{.spec.ports[*].nodePort}' | grep -qw ${COREDNS_PORT_OVERRIDE}"
    check "MetalLB gateway-pool present" oc get ipaddresspool -n metallb-system gateway-pool
    check "tools pods running (keycloak/mockserver/jaeger/vault)" bash -c 'for a in keycloak mockserver jaeger vault; do oc get pods -n tools --no-headers | grep "^$a" | grep -q Running || exit 1; done'
    # settings token: validate without printing it
    check "settings control_plane token valid" bash -c "T=\$(awk '/^ *token:/{print \$2; exit}' '$SETTINGS' | tr -d '\"'); KUBECONFIG=/root/.kube/config oc --token=\"\$T\" whoami"
    return "$FAILED"
}

{
    echo "date: $(date --iso-8601=seconds)"
    echo "host: $(hostname) arch: $(uname -m)"
    echo "testsuite: $(git -C "$REPO_DIR" rev-parse --abbrev-ref HEAD)@$(git -C "$REPO_DIR" rev-parse --short HEAD)"
    echo "testsuite local changes:"; git -C "$REPO_DIR" status --short | sed 's/^/  /'
    KUBECONFIG="$KCFG" oc version 2>/dev/null | grep -E "Server|Kubernetes" | sed 's/^/  /'
    echo "CSVs:"; KUBECONFIG="$KCFG" oc get csv -n openshift-operators --no-headers 2>/dev/null | awk '{print "  "$1, $NF}'
    echo "wasm injector image: $(KUBECONFIG="$KCFG" oc get csv -n openshift-operators -o jsonpath='{.items[?(@.metadata.name=="rhcl-operator.v1.5.0")].spec.install.spec.deployments[0].spec.template.spec.initContainers[0].image}' 2>/dev/null)"
    echo "DNS: zone kuadrant.internal, port ${COREDNS_PORT_OVERRIDE}"
    echo "pytest options: see scripts/run-kuadrant-e2e.sh (-n0, --reruns 3, -m 'not standalone_only and not disruptive and not ui')"
    echo
    echo "preflight:"
} > "$ENVF"

if [[ "${SKIP_PREFLIGHT:-0}" != 1 ]]; then
    preflight | tee -a "$ENVF"
    rc_pf=${PIPESTATUS[0]}
    if [[ $rc_pf -ne 0 ]]; then
        echo "Preflight failed - see $ENVF (set SKIP_PREFLIGHT=1 to override)" >&2
        exit 2
    fi
fi

echo "============================================================"
echo "Run dir: $RUN_DIR"
echo "Monitor: tmux attach -t kuadrant-power-full-e2e"
echo "         tail -n 100 -f ${RUN_DIR}/full-e2e.log"
echo "============================================================"

START=$(date +%s)
RESULTS_DIR="$RUN_DIR" RUN_NAME=full-e2e \
LOG_FILE="${RUN_DIR}/full-e2e.log" JUNIT_FILE="${RUN_DIR}/junit-full-e2e.xml" HTML_FILE="${RUN_DIR}/report-full-e2e.html" \
PYTHONUNBUFFERED=1 "${SCRIPT_DIR}/run-kuadrant-e2e.sh"
rc=$?
echo "$rc" > "${RUN_DIR}/exit-code.txt"

# summary.txt / failures.txt (from the pytest summary line and the JUnit file)
{
    echo "pytest rc: $rc"
    echo "duration: $(( ($(date +%s) - START) / 60 )) min"
    echo "pytest summary: $(grep -aE '^=+ .*(passed|failed).* in [0-9.]+s' "${RUN_DIR}/full-e2e.log" | tail -1)"
    echo "collection: $(grep -aE '^collected ' "${RUN_DIR}/full-e2e.log" | tail -1)"
} > "${RUN_DIR}/summary.txt"
python3 - "${RUN_DIR}/junit-full-e2e.xml" "${RUN_DIR}/failures.txt" >> "${RUN_DIR}/summary.txt" <<'EOF'
import sys, xml.etree.ElementTree as ET
junit, out = sys.argv[1], sys.argv[2]
try:
    root = ET.parse(junit).getroot()
except Exception as exc:  # junit missing if pytest crashed
    print(f"junit not readable: {exc}")
    sys.exit(0)
counts = {"passed": 0, "failed": 0, "error": 0, "skipped": 0}
lines = []
for tc in root.iter("testcase"):
    tags = {c.tag for c in tc}
    tid = f"{tc.get('classname')}::{tc.get('name')}"
    if "failure" in tags:
        counts["failed"] += 1
        msg = tc.find("failure").get("message", "")
        lines.append(f"FAILED {tid} :: {msg[:300]}")
    elif "error" in tags:
        counts["error"] += 1
        msg = tc.find("error").get("message", "")
        lines.append(f"ERROR  {tid} :: {msg[:300]}")
    elif "skipped" in tags:
        counts["skipped"] += 1
    else:
        counts["passed"] += 1
print("junit testcase entries (rerun attempts counted as passed entries): " + ", ".join(f"{k}={v}" for k, v in counts.items()))
with open(out, "w", encoding="utf-8") as fh:
    fh.write("\n".join(lines) + ("\n" if lines else ""))
EOF

cat "${RUN_DIR}/summary.txt"
echo "Artifacts in ${RUN_DIR}"
exit "$rc"
