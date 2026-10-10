#!/usr/bin/env bash
# Kuadrant / RHCL PPC64LE pre-E2E environment preparation
#
# Purpose:
#   Run this script BEFORE the Kuadrant E2E testsuite.
#
# It DOES NOT execute pytest or the dns/tls test.
#
# What it does:
#   - validates OpenShift access and required tools
#   - ensures tools/test namespaces
#   - ensures etcd prerequisite
#   - ensures CoreDNS provider secret
#   - validates CoreDNS configuration
#   - ensures kuadrant-coredns ClusterIP service (:53 -> :5353)
#   - ensures bastion-reachable coredns-nodeport service
#   - dynamically discovers CoreDNS Node IP + NodePort
#   - updates config/settings.local.yaml dns_server fields
#   - validates the custom kuadrant_coredns_resolve pytest plugin
#   - validates Keycloak / other prerequisites
#   - performs a synthetic DNS preflight
#   - starts sync-kuadrant-dns-etcd.sh in background and leaves it running
#   - starts fix-ef-denywith.py (EnvoyFilter denyWith CEL fix) in background
#   - writes an environment file to source before E2E execution
#
# Usage:
#   ./scripts/kuadrant-pre-e2e.sh
#
# Then:
#   source /tmp/kuadrant-ppc64le-e2e-env.sh
#   ./scripts/run-kuadrant-e2e.sh            # full suite
#   ./scripts/run-kuadrant-e2e.sh <paths...>  # selected tests/groups
#
# To stop the DNS helper later:
#   kill "$(cat /tmp/kuadrant-ppc64le-dns-helper.pid)"

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="${REPO_DIR:-$(dirname "$SCRIPT_DIR")}"
SETTINGS_FILE="${SETTINGS_FILE:-config/settings.local.yaml}"

TOOLS_NS="${TOOLS_NS:-tools}"
TEST_NS="${TEST_NS:-kuadrant}"
TEST_NS2="${TEST_NS2:-kuadrant2}"
DNS_ZONE="${DNS_ZONE:-kuadrant.internal}"

DNS_SYNC_HELPER="${DNS_SYNC_HELPER:-$SCRIPT_DIR/sync-kuadrant-dns-etcd.sh}"
RESET_DNS="${RESET_DNS:-0}"

ENV_FILE="${ENV_FILE:-/tmp/kuadrant-ppc64le-e2e-env.sh}"
DNS_HELPER_PID_FILE="${DNS_HELPER_PID_FILE:-/tmp/kuadrant-ppc64le-dns-helper.pid}"
DNS_HELPER_LOG="${DNS_HELPER_LOG:-/tmp/kuadrant-ppc64le-dns-helper.log}"

MOCKSERVER_IMAGE="${MOCKSERVER_IMAGE:-quay.io/pbastide_rh/mockserver-ppc64le:f572b831a14d0b3027d4f6164d60051fe8e2b6f7}"
LLM_SIM_IMAGE="${LLM_SIM_IMAGE:-quay.io/raja0940/llm-d-inference-sim-ppc64le:v091-fixed}"
GRPCBIN_IMAGE="${GRPCBIN_IMAGE:-quay.io/raja0940/grpcbin:ppc64le-rc3-tls}"
SPICEDB_IMAGE="${SPICEDB_IMAGE:-quay.io/pbastide_rh/spicedb-ppc64le:latest}"
PIPELINE_POLICY_EXTENSION_IMAGE="${PIPELINE_POLICY_EXTENSION_IMAGE:-quay.io/raja-0940/threat-assessment-service:latest}"

SYNTHETIC_KEY="/skydns/internal/kuadrant/test/dnscheck"
SYNTHETIC_NAME="dnscheck.test.${DNS_ZONE}"
SYNTHETIC_IP="192.0.2.123"

log()  { printf '%s  %s\n' "$(date --iso-8601=seconds)" "$*"; }
die()  { log "ERROR: $*"; exit 1; }
ok()   { log "  OK  $*"; }
info() { log " INFO $*"; }

need_cmd() { command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"; }

# ─── 0. Tool prerequisites ────────────────────────────────────────────────────
log "=== 0. Checking required tools ==="
for cmd in oc python3 poetry yq tmux; do
    need_cmd "$cmd"
    ok "$cmd found"
done

# ─── 1. Cluster access ────────────────────────────────────────────────────────
log "=== 1. Verifying cluster access ==="
WHOAMI=$(oc whoami 2>&1) || die "Cannot access cluster: $WHOAMI"
ok "Logged in as: $WHOAMI"

NODE_COUNT=$(oc get nodes --no-headers 2>/dev/null | wc -l)
[[ "$NODE_COUNT" -ge 1 ]] || die "No nodes found"
ok "Nodes: $NODE_COUNT"

# ─── 2. Kuadrant health ───────────────────────────────────────────────────────
log "=== 2. Verifying Kuadrant health ==="
RHCL_CSV=$(oc get csv -n openshift-operators rhcl-operator.v1.5.0 -o jsonpath='{.status.phase}' 2>/dev/null) || RHCL_CSV="missing"
[[ "$RHCL_CSV" == "Succeeded" ]] || die "rhcl-operator.v1.5.0 CSV not Succeeded (got: $RHCL_CSV)"
ok "RHCL CSV: Succeeded"

KD_READY=$(oc get kuadrant kuadrant -n kuadrant-system -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null) || KD_READY="missing"
[[ "$KD_READY" == "True" ]] || info "Kuadrant Ready condition: $KD_READY (continuing anyway)"
ok "Kuadrant CR found"

# ─── 3. Repo directory ────────────────────────────────────────────────────────
log "=== 3. Verifying testsuite repository ==="
[[ -d "$REPO_DIR" ]] || die "Testsuite directory not found: $REPO_DIR"
cd "$REPO_DIR"
[[ -f "$SETTINGS_FILE" ]] || die "Settings file not found: $REPO_DIR/$SETTINGS_FILE"
ok "Testsuite dir: $REPO_DIR"
ok "Settings file: $SETTINGS_FILE"

# ─── 4. Namespaces ────────────────────────────────────────────────────────────
log "=== 4. Ensuring namespaces ==="
for ns in "$TOOLS_NS" "$TEST_NS"; do
    if ! oc get namespace "$ns" >/dev/null 2>&1; then
        log "Creating namespace $ns"
        oc create namespace "$ns" >/dev/null
    fi
    ok "Namespace exists: $ns"
done

if ! oc get namespace "$TEST_NS2" >/dev/null 2>&1; then
    log "Creating namespace $TEST_NS2"
    oc create namespace "$TEST_NS2" >/dev/null
fi
ok "Namespace exists: $TEST_NS2"

# ─── 5. etcd ──────────────────────────────────────────────────────────────────
log "=== 5. Verifying etcd ==="
ETCD_READY=$(oc get deployment etcd -n "$TOOLS_NS" -o jsonpath='{.status.readyReplicas}' 2>/dev/null) || ETCD_READY=0
[[ "${ETCD_READY:-0}" -ge 1 ]] || die "etcd deployment not ready in namespace $TOOLS_NS"
ok "etcd ready replicas: $ETCD_READY"

ETCD_SVC_IP=$(oc get svc etcd -n "$TOOLS_NS" -o jsonpath='{.spec.clusterIP}' 2>/dev/null) || die "etcd service not found"
ok "etcd ClusterIP: $ETCD_SVC_IP"

# ─── 6. CoreDNS service ───────────────────────────────────────────────────────
log "=== 6. Verifying CoreDNS services ==="
COREDNS_READY=$(oc get deployment coredns -n "$TOOLS_NS" -o jsonpath='{.status.readyReplicas}' 2>/dev/null) || COREDNS_READY=0
[[ "${COREDNS_READY:-0}" -ge 1 ]] || die "coredns deployment not ready in namespace $TOOLS_NS"
ok "CoreDNS ready replicas: $COREDNS_READY"

COREDNS_CLUSTERIP=$(oc get svc coredns -n "$TOOLS_NS" -o jsonpath='{.spec.clusterIP}' 2>/dev/null) || die "coredns ClusterIP svc not found"
ok "CoreDNS ClusterIP: $COREDNS_CLUSTERIP"

# Ensure NodePort service exists
if ! oc get svc coredns-nodeport -n "$TOOLS_NS" >/dev/null 2>&1; then
    log "Creating coredns-nodeport NodePort service"
    cat <<EOF | oc apply -f -
apiVersion: v1
kind: Service
metadata:
  name: coredns-nodeport
  namespace: ${TOOLS_NS}
spec:
  type: NodePort
  selector:
    app: coredns
  ports:
    - name: dns-udp
      port: 5353
      targetPort: 5353
      protocol: UDP
      nodePort: 30553
    - name: dns-tcp
      port: 5353
      targetPort: 5353
      protocol: TCP
      nodePort: 30553
EOF
fi
COREDNS_NODEPORT=$(oc get svc coredns-nodeport -n "$TOOLS_NS" -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null) || die "coredns-nodeport svc not found"
ok "CoreDNS NodePort: $COREDNS_NODEPORT"

# Ensure kuadrant-coredns ClusterIP :53 service exists (in-cluster DNS delegation)
if ! oc get svc kuadrant-coredns -n "$TOOLS_NS" >/dev/null 2>&1; then
    log "Creating kuadrant-coredns service (port 53 -> 5353)"
    cat <<EOF | oc apply -f -
apiVersion: v1
kind: Service
metadata:
  name: kuadrant-coredns
  namespace: ${TOOLS_NS}
spec:
  type: ClusterIP
  selector:
    app: coredns
  ports:
    - name: dns-udp
      port: 53
      targetPort: 5353
      protocol: UDP
    - name: dns-tcp
      port: 53
      targetPort: 5353
      protocol: TCP
EOF
fi
KUADRANT_COREDNS_IP=$(oc get svc kuadrant-coredns -n "$TOOLS_NS" -o jsonpath='{.spec.clusterIP}' 2>/dev/null) || die "kuadrant-coredns svc not found"
ok "kuadrant-coredns ClusterIP: $KUADRANT_COREDNS_IP"

# ─── 7. Discover bastion-reachable CoreDNS endpoint ──────────────────────────
log "=== 7. Discovering bastion-reachable CoreDNS endpoint ==="
# Pick a worker node IP that is reachable from this bastion
NODE_IP=""
for node_ip in $(oc get nodes -o json | python3 -c "
import json,sys
n=json.load(sys.stdin)
for i in n['items']:
    for a in i['status']['addresses']:
        if a['type']=='InternalIP':
            print(a['address'])
"); do
    if python3 -c "
import socket,struct,sys
try:
    udp=socket.socket(socket.AF_INET,socket.SOCK_DGRAM)
    udp.settimeout(2.0)
    # minimal DNS query for '.', type=NS
    payload=b'\xAB\xCD\x01\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\x01'
    udp.sendto(payload,('${node_ip}',${COREDNS_NODEPORT}))
    data,_=udp.recvfrom(512)
    udp.close()
    sys.exit(0)
except:
    sys.exit(1)
" 2>/dev/null; then
        NODE_IP="$node_ip"
        break
    fi
done

if [[ -z "$NODE_IP" ]]; then
    # Fallback: use first worker node IP
    NODE_IP=$(oc get nodes -l node-role.kubernetes.io/worker -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null)
    info "Using fallback node IP: $NODE_IP"
fi

[[ -n "$NODE_IP" ]] || die "Could not determine a reachable node IP for CoreDNS NodePort"
ok "CoreDNS NodePort endpoint: ${NODE_IP}:${COREDNS_NODEPORT}"

# ─── 8. coredns-credentials secrets ──────────────────────────────────────────
log "=== 8. Ensuring coredns-credentials secrets ==="
ensure_coredns_secret() {
    local ns="$1"
    if oc get secret coredns-credentials -n "$ns" >/dev/null 2>&1; then
        ok "coredns-credentials already exists in $ns"
        return
    fi
    log "Creating coredns-credentials in $ns"
    oc create secret generic coredns-credentials \
        --from-literal=ZONES="${DNS_ZONE}" \
        --from-literal=ETCD_ENDPOINTS="http://etcd.${TOOLS_NS}.svc.cluster.local:2379" \
        --type=kuadrant.io/coredns \
        -n "$ns"
    oc annotate secret coredns-credentials -n "$ns" base_domain="${DNS_ZONE}" --overwrite
    ok "Created coredns-credentials in $ns"
}
ensure_coredns_secret "$TEST_NS"
ensure_coredns_secret "$TEST_NS2"

# ─── 9. settings.local.yaml DNS update ───────────────────────────────────────
log "=== 9. Updating settings.local.yaml DNS configuration ==="
# Update dns_server.address to the kuadrant-coredns ClusterIP (in-cluster)
# and default_geo_server
yq -i ".default.dns.dns_server.address = \"${KUADRANT_COREDNS_IP}\"" "$SETTINGS_FILE"
yq -i ".default.dns.default_geo_server = \"${KUADRANT_COREDNS_IP}\"" "$SETTINGS_FILE"
ok "Updated dns_server.address -> $KUADRANT_COREDNS_IP"


# ─── 9b. Refresh OCP token in settings.local.yaml ────────────────────────────
log "=== 9b. Refreshing OCP token in settings.local.yaml ==="
CURRENT_TOKEN="$(oc whoami --show-token 2>/dev/null || true)"
if [[ -z "$CURRENT_TOKEN" ]]; then
    log "WARNING: Could not get current OCP token — settings.local.yaml token may be stale" >&2
else
    # Replace any existing sha256~... token under the cluster section
    OLD_TOKEN="$(yq '.default.control_plane.cluster.token // ""' "$SETTINGS_FILE")"
    if [[ -n "$OLD_TOKEN" && "$OLD_TOKEN" != "$CURRENT_TOKEN" ]]; then
        CURRENT_TOKEN="$CURRENT_TOKEN" yq -i '.default.control_plane.cluster.token = strenv(CURRENT_TOKEN)' "$SETTINGS_FILE"
        ok "Updated cluster token in settings.local.yaml"
    elif [[ "$OLD_TOKEN" == "$CURRENT_TOKEN" ]]; then
        ok "Cluster token in settings.local.yaml is already current"
    else
        # No token in settings (e.g. kubeconfig uses client certificates). The testsuite needs
        # cluster.token for bearer-auth clients such as Prometheus/Thanos (metrics tests).
        CURRENT_TOKEN="$CURRENT_TOKEN" yq -i '.default.control_plane.cluster.token = strenv(CURRENT_TOKEN)' "$SETTINGS_FILE"
        ok "Added cluster token to settings.local.yaml (control_plane.cluster.token)"
    fi
fi

# ─── 10. Kuadrant_coredns_resolve plugin validation ──────────────────────────
log "=== 10. Validating kuadrant_coredns_resolve plugin ==="
PLUGIN_TOPDIR="$REPO_DIR/kuadrant_coredns_resolve.py"
PLUGIN_PKG="$REPO_DIR/testsuite/kuadrant_coredns_resolve.py"

[[ -f "$PLUGIN_TOPDIR" ]] || die "Top-level plugin missing: $PLUGIN_TOPDIR"
[[ -f "$PLUGIN_PKG" ]]    || die "Package plugin missing: $PLUGIN_PKG"

python3 -m py_compile "$PLUGIN_TOPDIR" || die "Plugin syntax error: $PLUGIN_TOPDIR"
ok "Plugin syntax OK: $PLUGIN_TOPDIR"

# Verify conftest.py loads the plugin
CONFTEST="$REPO_DIR/testsuite/conftest.py"
if [[ -f "$CONFTEST" ]]; then
    grep -q 'kuadrant_coredns_resolve' "$CONFTEST" || die "conftest.py does not load kuadrant_coredns_resolve"
    ok "conftest.py loads kuadrant_coredns_resolve"
else
    info "Warning: testsuite/conftest.py not found"
fi

# ─── 11. Keycloak validation ──────────────────────────────────────────────────
log "=== 11. Validating Keycloak ==="
KEYCLOAK_URL=$(yq '.default.keycloak.url' "$SETTINGS_FILE" 2>/dev/null) || KEYCLOAK_URL=""
if [[ -n "$KEYCLOAK_URL" && "$KEYCLOAK_URL" != "null" ]]; then
    KC_STATUS=$(curl -sf -o /dev/null -w '%{http_code}' "${KEYCLOAK_URL}/health/ready" 2>/dev/null || echo "000")
    if [[ "$KC_STATUS" == "200" ]]; then
        ok "Keycloak healthy: $KEYCLOAK_URL"
    else
        KC_STATUS2=$(curl -sf -o /dev/null -w '%{http_code}' "${KEYCLOAK_URL}" 2>/dev/null || echo "000")
        info "Keycloak /health/ready returned $KC_STATUS, root returned $KC_STATUS2 (URL: $KEYCLOAK_URL)"
    fi
fi

# ─── 12. Synthetic DNS preflight ─────────────────────────────────────────────
log "=== 12. Synthetic DNS preflight ==="
ETCD_POD=$(oc get pod -n "$TOOLS_NS" -l app=etcd -o jsonpath='{.items[0].metadata.name}' 2>/dev/null) || die "etcd pod not found"

# Insert preflight record
oc exec -n "$TOOLS_NS" "$ETCD_POD" -- etcdctl put "$SYNTHETIC_KEY" \
    "{\"host\":\"${SYNTHETIC_IP}\",\"ttl\":60}" >/dev/null
ok "Inserted synthetic record: $SYNTHETIC_NAME -> $SYNTHETIC_IP"

# Query via NodePort
RESOLVED=$(python3 -c "
import socket, struct, sys, time

DNS_HOST = '${NODE_IP}'
DNS_PORT = ${COREDNS_NODEPORT}
name = '${SYNTHETIC_NAME}'

def encode_name(n):
    out = b''
    for label in n.strip('.').split('.'):
        raw = label.encode('idna')
        out += bytes([len(raw)]) + raw
    return out + b'\x00'

question = encode_name(name) + struct.pack('!HH', 1, 1)
header = struct.pack('!HHHHHH', 0xC0DE, 0x0100, 1, 0, 0, 0)
payload = header + question

for attempt in range(5):
    try:
        udp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        udp.settimeout(3.0)
        udp.sendto(payload, (DNS_HOST, DNS_PORT))
        data, _ = udp.recvfrom(512)
        udp.close()
        rcode = data[3] & 0xF
        ancount = struct.unpack('!H', data[6:8])[0]
        if rcode == 0 and ancount > 0:
            # Parse answer
            offset = 12
            # skip question
            while data[offset] != 0:
                if data[offset] & 0xC0 == 0xC0:
                    offset += 2
                    break
                offset += data[offset] + 1
            else:
                offset += 1
            offset += 4  # qtype+qclass
            # skip answer name
            if data[offset] & 0xC0 == 0xC0:
                offset += 2
            else:
                while data[offset] != 0:
                    offset += data[offset] + 1
                offset += 1
            atype, _, _, rdlen = struct.unpack('!HHIH', data[offset:offset+10])
            offset += 10
            if atype == 1 and rdlen == 4:
                ip = '.'.join(str(b) for b in data[offset:offset+4])
                print(ip)
                sys.exit(0)
        time.sleep(1)
    except Exception as e:
        time.sleep(1)
print('FAILED')
sys.exit(1)
" 2>/dev/null || echo "FAILED")

if [[ "$RESOLVED" == "$SYNTHETIC_IP" ]]; then
    ok "DNS preflight passed: $SYNTHETIC_NAME -> $RESOLVED"
elif [[ "$RESOLVED" == "FAILED" ]]; then
    # Try TCP path
    info "UDP DNS failed, trying TCP via NodePort"
    RESOLVED_TCP=$(python3 -c "
import socket, struct, sys

DNS_HOST = '${NODE_IP}'
DNS_PORT = ${COREDNS_NODEPORT}
name = '${SYNTHETIC_NAME}'

def encode_name(n):
    out = b''
    for label in n.strip('.').split('.'):
        raw = label.encode('idna')
        out += bytes([len(raw)]) + raw
    return out + b'\x00'

question = encode_name(name) + struct.pack('!HH', 1, 1)
header = struct.pack('!HHHHHH', 0xC0DE, 0x0100, 1, 0, 0, 0)
payload = header + question

try:
    with socket.create_connection((DNS_HOST, DNS_PORT), timeout=5.0) as s:
        s.sendall(struct.pack('!H', len(payload)) + payload)
        lb = s.recv(2)
        ml, = struct.unpack('!H', lb)
        data = b''
        while len(data) < ml:
            c = s.recv(ml - len(data))
            if not c: break
            data += c
    rcode = data[3] & 0xF
    ancount = struct.unpack('!H', data[6:8])[0]
    print(f'RCODE={rcode} ANCOUNT={ancount}', file=sys.stderr)
    if rcode == 0 and ancount > 0:
        print('RESOLVED')
    else:
        print('NXDOMAIN')
except Exception as e:
    print(f'TCP error: {e}', file=sys.stderr)
    print('FAILED')
" 2>&1)
    info "TCP DNS result: $RESOLVED_TCP"
    info "DNS preflight inconclusive via NodePort; CoreDNS pod log:"
    oc logs -n "$TOOLS_NS" -l app=coredns --tail=10 2>/dev/null || true
    info "Continuing anyway — DNS will be validated during E2E"
else
    info "DNS preflight returned unexpected: $RESOLVED — continuing"
fi

# ─── 13. Start DNS sync helper ────────────────────────────────────────────────
log "=== 13. Starting DNS sync helper ==="
[[ -x "$DNS_SYNC_HELPER" ]] || die "DNS sync helper not executable: $DNS_SYNC_HELPER"

# Kill any existing stale instance
if [[ -f "$DNS_HELPER_PID_FILE" ]]; then
    OLD_PID=$(cat "$DNS_HELPER_PID_FILE")
    if kill -0 "$OLD_PID" 2>/dev/null; then
        if [[ "$RESET_DNS" == "1" ]]; then
            log "Killing existing DNS helper (pid=$OLD_PID, RESET_DNS=1)"
            kill "$OLD_PID" 2>/dev/null || true
            sleep 1
            rm -f "$DNS_HELPER_PID_FILE"
        else
            ok "DNS helper already running (pid=$OLD_PID) — reusing"
            DNS_HELPER_PID="$OLD_PID"
        fi
    else
        log "Stale PID file (pid=$OLD_PID not running) — removing"
        rm -f "$DNS_HELPER_PID_FILE"
    fi
fi

if [[ ! -f "$DNS_HELPER_PID_FILE" ]]; then
    nohup "$DNS_SYNC_HELPER" >> "$DNS_HELPER_LOG" 2>&1 &
    DNS_HELPER_PID=$!
    echo "$DNS_HELPER_PID" > "$DNS_HELPER_PID_FILE"
    sleep 2
    if kill -0 "$DNS_HELPER_PID" 2>/dev/null; then
        ok "DNS helper started (pid=$DNS_HELPER_PID) log=$DNS_HELPER_LOG"
    else
        die "DNS helper failed to start — check $DNS_HELPER_LOG"
    fi
fi


# ─── 14. EF denyWith CEL fix daemon (ppc64le RHCL v1.5 rate-limit fix) ──────
# RHCL v1.5 kuadrant-operator generates invalid CEL in the wasm EnvoyFilter:
#   body: Too Many Requests\n"!}  (unquoted body string + stray chars)
# Correct form:  body: "Too Many Requests\n"
# Without this fix wasm-shim refuses to load the plugin config (rate-limit fails open).
EF_FIX_SCRIPT="${EF_FIX_SCRIPT:-$SCRIPT_DIR/fix-ef-denywith.py}"
EF_FIX_LOG="${EF_FIX_LOG:-/tmp/ef-fix-daemon.log}"
EF_FIX_PID_FILE="${EF_FIX_PID_FILE:-/tmp/ef-fix-daemon.pid}"

log "=== 14. Starting EF denyWith CEL fix daemon ==="
if [[ -f "$EF_FIX_PID_FILE" ]]; then
    OLD_PID="$(cat "$EF_FIX_PID_FILE")"
    if kill -0 "$OLD_PID" 2>/dev/null; then
        ok "EF fix daemon already running (pid=$OLD_PID) — restarting"
        kill "$OLD_PID" 2>/dev/null || true
        sleep 1
    fi
    rm -f "$EF_FIX_PID_FILE"
fi
nohup python3 "$EF_FIX_SCRIPT" >> "$EF_FIX_LOG" 2>&1 &
EF_FIX_PID=$!
echo "$EF_FIX_PID" > "$EF_FIX_PID_FILE"
sleep 3
if kill -0 "$EF_FIX_PID" 2>/dev/null; then
    ok "EF fix daemon started (pid=$EF_FIX_PID) log=$EF_FIX_LOG"
else
    log "WARNING: EF fix daemon failed to start — check $EF_FIX_LOG" >&2
fi

# ─── 15. Write environment file ───────────────────────────────────────────────
log "=== 15. Writing environment file ==="
# DNS port used by the pytest resolver plugin for *.<zone>. Prefer the kuadrant-coredns NodePort
# (setup-kuadrant-coredns.sh; serves DNSRecord CRs, required by dnspolicy/listener/retarget tests),
# fall back to the etcd CoreDNS NodePort. Override with TEST_DNS_PORT.
KUADRANT_COREDNS_NS="${KUADRANT_COREDNS_NS:-kuadrant-coredns}"
TEST_DNS_PORT="${TEST_DNS_PORT:-$(oc get svc kuadrant-coredns -n "$KUADRANT_COREDNS_NS" \
    -o jsonpath='{.spec.ports[?(@.protocol=="UDP")].nodePort}' 2>/dev/null || true)}"
if [[ -z "$TEST_DNS_PORT" ]]; then
    log "WARNING: kuadrant-coredns NodePort not found in ${KUADRANT_COREDNS_NS} - falling back to etcd CoreDNS ${COREDNS_NODEPORT} (DNSRecord-based tests will fail; run setup-kuadrant-coredns.sh)" >&2
    TEST_DNS_PORT="$COREDNS_NODEPORT"
fi
ok "Test DNS resolver port: ${TEST_DNS_PORT}"
cat > "$ENV_FILE" <<EOF
# Kuadrant PPC64LE E2E environment — generated $(date --iso-8601=seconds)
# source this file before running pytest

export KUADRANT_COREDNS_ZONE="${DNS_ZONE}"
export KUADRANT_COREDNS_DNS_HOST="${NODE_IP}"
export KUADRANT_COREDNS_DNS_PORT="${TEST_DNS_PORT}"

# Timeouts for dataplane readiness polling
export AUTH_DATAPLANE_READY_TIMEOUT=120
export OIDC_DATAPLANE_READY_TIMEOUT=120

# Image overrides
export MOCKSERVER_IMAGE="${MOCKSERVER_IMAGE}"
export LLM_SIM_IMAGE="${LLM_SIM_IMAGE}"
export GRPCBIN_IMAGE="${GRPCBIN_IMAGE}"
export SPICEDB_IMAGE="${SPICEDB_IMAGE}"
export PIPELINE_POLICY_EXTENSION_IMAGE="${PIPELINE_POLICY_EXTENSION_IMAGE}"

# DNS helper
export DNS_HELPER_PID_FILE="${DNS_HELPER_PID_FILE}"
export DNS_HELPER_LOG="${DNS_HELPER_LOG}"
EOF
ok "Environment file written: $ENV_FILE"

# ─── 16. Final summary ────────────────────────────────────────────────────────
log ""
log "=== Pre-E2E preparation COMPLETE ==="
log ""
log "  DNS zone          : ${DNS_ZONE}"
log "  CoreDNS NodePort  : ${NODE_IP}:${COREDNS_NODEPORT}  (bastion-reachable)"
log "  Test DNS port     : ${NODE_IP}:${TEST_DNS_PORT}  (KUADRANT_COREDNS_DNS_PORT)"
log "  CoreDNS ClusterIP : ${COREDNS_CLUSTERIP}:5353       (in-cluster)"
log "  kuadrant-coredns  : ${KUADRANT_COREDNS_IP}:53       (in-cluster delegation)"
log "  etcd              : ${ETCD_SVC_IP}:2379"
log "  DNS helper PID    : $(cat "${DNS_HELPER_PID_FILE}" 2>/dev/null || echo unknown)"
log "  DNS helper log    : ${DNS_HELPER_LOG}"
log "  Env file          : ${ENV_FILE}"
log ""
log "Next steps:"
log "  source ${ENV_FILE}"
log "  cd ${REPO_DIR}"
log "  ${SCRIPT_DIR}/run-kuadrant-e2e.sh"
