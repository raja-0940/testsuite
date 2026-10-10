#!/usr/bin/env bash
# setup-dataplane-observability.sh (tracing/data_plane_tracing tests):
# enable wasm-shim dataplane tracing on the Kuadrant CR.
#
# The data_plane_tracing tests look up Jaeger traces for service "kuadrant-filter"
# (wasm-shim >= 0.15) by request_id. Without spec.observability.dataPlane the wasm
# filter does not emit spans with the request_id tag and every trace lookup 404s.
# Same values as CI step kuadrant-s390x-deploy-tools (openshift/release).
#
# Merges into the existing spec.observability: keeps enable/tracing.defaultEndpoint.
# Idempotent. Revert: ./setup-dataplane-observability.sh --revert
set -euo pipefail
KUADRANT_NS=${KUADRANT_NS:-kuadrant-system}
KUADRANT_NAME=${KUADRANT_NAME:-kuadrant}

if [[ "${1:-}" == "--revert" ]]; then
  oc -n "$KUADRANT_NS" patch kuadrant "$KUADRANT_NAME" --type json \
    -p '[{"op":"remove","path":"/spec/observability/dataPlane"}]' \
    || echo "dataPlane not set; nothing to revert"
else
  oc -n "$KUADRANT_NS" patch kuadrant "$KUADRANT_NAME" --type merge -p '{
    "spec": {"observability": {"dataPlane": {
      "defaultLevels": [{"debug": "true"}],
      "httpHeaderIdentifier": "x-request-id"
    }}}}'
fi
oc -n "$KUADRANT_NS" wait kuadrant "$KUADRANT_NAME" --for=condition=Ready --timeout=120s
oc -n "$KUADRANT_NS" get kuadrant "$KUADRANT_NAME" -o jsonpath='{.spec.observability}'; echo
