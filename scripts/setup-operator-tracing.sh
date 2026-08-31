#!/usr/bin/env bash
# setup-operator-tracing.sh (tracing/control_plane tests): enable control-plane OTEL tracing on kuadrant-operator.
# Tests require OTEL_* env vars on kuadrant-operator-controller-manager (see
# tracing/control_plane/conftest.py::require_tracing_enabled). Set via OLM Subscription
# .spec.config.env (OLM-persistent; a direct 'oc set env' on the deployment is reverted by OLM).
# Same values as upstream make/vars.mk (INSTALL_TRACING=true) and CI step kuadrant-s390x-deploy-tools.
# Pre-existing Subscription env entries are preserved. Idempotent.
set -euo pipefail
OP_NS=${OP_NS:-openshift-operators}
SUB=${SUB:-rhcl-operator}
TOOLS_NS=${TOOLS_NS:-tools}
GRPC="rpc://jaeger-collector.${TOOLS_NS}.svc.cluster.local:4317"

oc -n "$OP_NS" get sub "$SUB" -o json | jq --arg grpc "$GRPC" '
  .spec.config = (.spec.config // {})
  | .spec.config.env = (((.spec.config.env // []) | map(select(.name | startswith("OTEL_") | not)))
      + [ {"name":"OTEL_EXPORTER_OTLP_ENDPOINT","value":$grpc},
          {"name":"OTEL_EXPORTER_OTLP_INSECURE","value":"true"} ])
  | del(.metadata.resourceVersion, .metadata.managedFields, .status)' | oc replace -f -
# wait for OLM to roll the operator
for i in $(seq 1 60); do
  oc -n "$OP_NS" set env deploy/kuadrant-operator-controller-manager --list | grep -q '^OTEL_EXPORTER_OTLP_ENDPOINT' && break
  sleep 5
done
oc -n "$OP_NS" rollout status deploy/kuadrant-operator-controller-manager --timeout=300s
oc -n "$OP_NS" set env deploy/kuadrant-operator-controller-manager --list | grep '^OTEL_'
echo "operator tracing configured"
