#!/usr/bin/env bash
# setup-cluster-prereqs.sh - cluster-level prerequisites that the other setup scripts assume already exist:
#   (a) ClusterIssuer "kuadrant-qe-issuer" (CA-backed; the CA is generated locally, never copied from another cluster)
#   (b) MetalLB IPAddressPool "gateway-pool" + L2Advertisement "l2" (addresses supplied by the operator)
# Idempotent. Existing objects are left untouched. Backups of anything modified go outside the repository.
#
# Usage:
#   METALLB_POOL_ADDRESSES="10.20.176.200/32,10.20.176.202/32" ./scripts/setup-cluster-prereqs.sh
#   ./scripts/setup-cluster-prereqs.sh --revert       # removes only objects this script created (see markers)
#
# Environment:
#   METALLB_POOL_ADDRESSES  comma separated CIDRs/ranges for gateway LoadBalancers (REQUIRED unless pool exists).
#                           Must be unused on the L2 segment: the script arping-probes each /32 and refuses on a reply
#                           (override with FORCE_POOL=1 only if you know the address is reserved for this cluster).
#   KUBECONFIG / OC_CONTEXT explicit cluster selection (OC_CONTEXT is passed as --context when set)
#   CM_NS                   cert-manager cluster-resource namespace (default cert-manager)
#   BACKUP_DIR              default /root/test/backup/prereqs-<ts>
set -euo pipefail

CM_NS=${CM_NS:-cert-manager}
ISSUER=${ISSUER:-kuadrant-qe-issuer}
CA_SECRET=${CA_SECRET:-kuadrant-qe-ca-secret}
POOL=${POOL:-gateway-pool}
MLB_NS=${MLB_NS:-metallb-system}
MARK='kuadrant-e2e.local/created-by=setup-cluster-prereqs'
OC=(oc)
[[ -n "${OC_CONTEXT:-}" ]] && OC=(oc --context "$OC_CONTEXT")

revert() {
  for r in "clusterissuer/${ISSUER}" "secret/${CA_SECRET} -n ${CM_NS}" "ipaddresspool/${POOL} -n ${MLB_NS}" "l2advertisement/l2 -n ${MLB_NS}"; do
    # shellcheck disable=SC2086
    if "${OC[@]}" get $r -o jsonpath='{.metadata.annotations}' 2>/dev/null | grep -q 'setup-cluster-prereqs'; then
      # shellcheck disable=SC2086
      "${OC[@]}" delete $r --ignore-not-found
    else
      echo "skip (not created by this script or absent): $r"
    fi
  done
}
[[ "${1:-}" == "--revert" ]] && { revert; exit 0; }

"${OC[@]}" whoami >/dev/null || { echo "not logged in" >&2; exit 1; }
echo "cluster: $("${OC[@]}" whoami --show-server)"

# ---- (a) CA-backed ClusterIssuer -------------------------------------------------------------
if "${OC[@]}" get clusterissuer "$ISSUER" >/dev/null 2>&1; then
  echo "ClusterIssuer ${ISSUER} exists - unchanged"
else
  if ! "${OC[@]}" -n "$CM_NS" get secret "$CA_SECRET" >/dev/null 2>&1; then
    T=$(mktemp -d); trap 'rm -rf "$T"' EXIT; umask 077
    openssl req -x509 -newkey rsa:4096 -sha256 -nodes -days 3650 -subj "/CN=kuadrant-qe-ca-$(oc whoami --show-server | sed 's#https://api\.##; s#:.*##' | cut -d. -f1)" \
      -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign,cRLSign" \
      -keyout "$T/tls.key" -out "$T/tls.crt" 2>/dev/null
    "${OC[@]}" -n "$CM_NS" create secret tls "$CA_SECRET" --cert="$T/tls.crt" --key="$T/tls.key"
    "${OC[@]}" -n "$CM_NS" annotate secret "$CA_SECRET" "${MARK%%=*}=${MARK##*=}" --overwrite >/dev/null
    echo "generated target-local CA secret ${CM_NS}/${CA_SECRET}"
  fi
  "${OC[@]}" apply -f - <<YAML
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: ${ISSUER}
  annotations: {"${MARK%%=*}": "${MARK##*=}"}
spec:
  ca:
    secretName: ${CA_SECRET}
YAML
  "${OC[@]}" wait clusterissuer "$ISSUER" --for=condition=Ready --timeout=60s
fi

# ---- (b) MetalLB pool ------------------------------------------------------------------------
if "${OC[@]}" -n "$MLB_NS" get ipaddresspool "$POOL" >/dev/null 2>&1; then
  echo "IPAddressPool ${POOL} exists - unchanged: $("${OC[@]}" -n "$MLB_NS" get ipaddresspool "$POOL" -o jsonpath='{.spec.addresses[*]}')"
else
  : "${METALLB_POOL_ADDRESSES:?set METALLB_POOL_ADDRESSES (comma separated, unused addresses on this L2 segment)}"
  IFS=',' read -r -a ADDRS <<<"$METALLB_POOL_ADDRESSES"
  IFACE=${POOL_IFACE:-$(ip -o route get "${ADDRS[0]%%/*}" | sed -n 's/.* dev \([^ ]*\).*/\1/p')}
  for a in "${ADDRS[@]}"; do
    ip=${a%%/*}
    if [[ "$a" == */32 || "$a" != */* ]]; then
      if arping -I "$IFACE" -c 2 -w 2 "$ip" 2>&1 | grep -q 'Unicast reply'; then
        [[ "${FORCE_POOL:-0}" == 1 ]] || { echo "REFUSING: $ip answers ARP on $IFACE (in use)" >&2; exit 1; }
      fi
    fi
  done
  YAMLADDR=$(printf '  - %s\n' "${ADDRS[@]}")
  "${OC[@]}" apply -f - <<YAML
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: ${POOL}
  namespace: ${MLB_NS}
  annotations: {"${MARK%%=*}": "${MARK##*=}"}
spec:
  autoAssign: true
  addresses:
${YAMLADDR}
YAML
fi
if ! "${OC[@]}" -n "$MLB_NS" get l2advertisement l2 >/dev/null 2>&1; then
  "${OC[@]}" apply -f - <<YAML
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: l2
  namespace: ${MLB_NS}
  annotations: {"${MARK%%=*}": "${MARK##*=}"}
spec:
  ipAddressPools: [${POOL}]
YAML
fi
echo "cluster prerequisites ready"
