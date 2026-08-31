#!/usr/bin/env bash
# setup-egress-vault-authorino.sh (egress tests): environment-only prerequisites for testsuite/tests/singlecluster/egress
#  (a) Vault Kubernetes auth method (tests call auth/kubernetes/role/* and auth/kubernetes/login)
#  (b) Authorino 'cluster-trust-bundle' volume (system CA + cluster CA) so metadata.http can call
#      https://kubernetes.default.svc. Mounted over /etc/ssl/certs with the image bundle included,
#      so public-CA trust is preserved (no impact on other tests).
# Same approach as CI step kuadrant-s390x-deploy-tools. Idempotent.
set -euo pipefail
KUADRANT_NS=${KUADRANT_NS:-kuadrant-system}
TOOLS_NS=${TOOLS_NS:-tools}

echo "=== (a) Vault: SA + auth-delegator + kubernetes auth ==="
oc -n "$TOOLS_NS" create sa vault --dry-run=client -o yaml | oc apply -f -
oc create clusterrolebinding kuadrant-vault-auth-delegator --clusterrole=system:auth-delegator \
  --serviceaccount="${TOOLS_NS}:vault" --dry-run=client -o yaml | oc apply -f -
if [[ "$(oc -n "$TOOLS_NS" get deploy vault -o jsonpath='{.spec.template.spec.serviceAccountName}')" != "vault" ]]; then
  # dev-mode Vault is in-memory: changing SA restarts the pod and resets state; auth is (re)configured below
  oc -n "$TOOLS_NS" patch deploy vault --type merge -p '{"spec":{"template":{"spec":{"serviceAccountName":"vault"}}}}'
fi
oc -n "$TOOLS_NS" rollout status deploy/vault --timeout=300s
oc -n "$TOOLS_NS" exec deploy/vault -- sh -c '
  export VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=${VAULT_DEV_ROOT_TOKEN_ID}
  vault auth list | grep -q "^kubernetes/" || vault auth enable kubernetes
  vault write auth/kubernetes/config \
    kubernetes_host="https://${KUBERNETES_SERVICE_HOST}:${KUBERNETES_SERVICE_PORT}" \
    kubernetes_ca_cert=@/var/run/secrets/kubernetes.io/serviceaccount/ca.crt \
    token_reviewer_jwt=@/var/run/secrets/kubernetes.io/serviceaccount/token \
    disable_iss_validation=true
  vault secrets list | grep -q "^secret/" || vault secrets enable -path=secret kv-v2
  vault auth list'

echo "=== (b) Authorino cluster-trust-bundle ==="
POD=$(oc -n "$KUADRANT_NS" get pod -l authorino-resource=authorino -o jsonpath='{.items[0].metadata.name}')
TMP=$(mktemp)
oc -n "$KUADRANT_NS" exec "$POD" -- sh -c 'cat /etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem /var/run/secrets/kubernetes.io/serviceaccount/ca.crt /var/run/secrets/kubernetes.io/serviceaccount/service-ca.crt 2>/dev/null' > "$TMP"
[[ -s "$TMP" ]] || { echo "empty CA bundle" >&2; exit 1; }
oc -n "$KUADRANT_NS" delete cm authorino-cluster-trust-ca-bundle --ignore-not-found
oc -n "$KUADRANT_NS" create cm authorino-cluster-trust-ca-bundle \
  --from-file=ca-bundle.crt="$TMP" --from-file=ca-certificates.crt="$TMP"
rm -f "$TMP"
oc -n "$KUADRANT_NS" patch authorino authorino --type merge -p '{"spec":{"volumes":{"items":[
  {"name":"cluster-trust-bundle","mountPath":"/etc/ssl/certs","configMaps":["authorino-cluster-trust-ca-bundle"]}]}}}'
sleep 10
oc -n "$KUADRANT_NS" rollout status deploy/authorino --timeout=300s
oc -n "$KUADRANT_NS" get authorino authorino -o jsonpath='{.spec.volumes}{"\n"}'
echo "egress prerequisites applied"
