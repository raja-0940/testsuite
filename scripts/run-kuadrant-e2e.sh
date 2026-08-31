#!/usr/bin/env bash
# Run the Kuadrant e2e testsuite on ppc64le.
#
# Prerequisite: ./scripts/kuadrant-pre-e2e.sh has been run (writes ENV_FILE).
#
# Usage:
#   ./scripts/run-kuadrant-e2e.sh                       # full singlecluster suite
#   ./scripts/run-kuadrant-e2e.sh <pytest paths/ids...> # selected tests / test group only
#
# Environment overrides:
#   ENV_FILE                env file written by kuadrant-pre-e2e.sh
#   RESULTS_DIR             where logs / junit / html are written
#   RUN_NAME                name used for the result files (default: kuadrant or "group")
#   COREDNS_PORT_OVERRIDE   resolve *.kuadrant.internal via the kuadrant-coredns NodePort
#                           (e.g. 30554, see setup-kuadrant-coredns.sh) - needed by dnspolicy tests

set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="${REPO_DIR:-$(dirname "$SCRIPT_DIR")}"
ENV_FILE="${ENV_FILE:-/tmp/kuadrant-ppc64le-e2e-env.sh}"
RESULTS_DIR="${RESULTS_DIR:-$HOME/kuadrant-e2e-results}"

[[ -f "$ENV_FILE" ]] || { echo "ERROR: $ENV_FILE not found - run scripts/kuadrant-pre-e2e.sh first" >&2; exit 1; }
# shellcheck source=/dev/null
source "$ENV_FILE"
[[ -n "${COREDNS_PORT_OVERRIDE:-}" ]] && export KUADRANT_COREDNS_DNS_PORT="${COREDNS_PORT_OVERRIDE}"

cd "$REPO_DIR" || exit 1
mkdir -p "$RESULTS_DIR"

if [[ $# -gt 0 ]]; then
    RUN_NAME="${RUN_NAME:-group}"
    TARGETS=("$@")
else
    RUN_NAME="${RUN_NAME:-kuadrant}"
    TARGETS=(testsuite/tests/singlecluster)
fi
TS="$(date +%Y%m%d%H%M%S)"
LOG="${RESULTS_DIR}/${RUN_NAME}-e2e-${TS}.log"
JUNIT="${RESULTS_DIR}/junit-${RUN_NAME}-${TS}.xml"
HTML="${RESULTS_DIR}/report-${RUN_NAME}-${TS}.html"

echo "============================================================"
echo "Kuadrant PPC64LE E2E (${RUN_NAME})"
echo "Start: $(date --iso-8601=seconds)"
echo "DNS zone: ${KUADRANT_COREDNS_ZONE}"
echo "DNS resolver: ${KUADRANT_COREDNS_DNS_HOST}:${KUADRANT_COREDNS_DNS_PORT}"
echo "Targets: ${TARGETS[*]}"
echo "============================================================"

WORKSPACE="$RESULTS_DIR" \
poetry run python -u -m pytest \
  --tb=short \
  --reruns 3 --reruns-delay 2 \
  -p no:cacheprovider \
  --verify-denials=true \
  --log-cli-level=INFO \
  -n0 \
  -m "not standalone_only and not disruptive and not ui" \
  --enforce -rfEs \
  --ignore=testsuite/tests/singlecluster/ui \
  --ignore=testsuite/tests/singlecluster/observability \
  --junitxml="$JUNIT" \
  -o junit_suite_name="$RUN_NAME" \
  --html="$HTML" \
  --self-contained-html \
  "${TARGETS[@]}" \
  2>&1 | tee "$LOG"

rc=${PIPESTATUS[0]}

echo
echo "============================================================"
echo "Kuadrant E2E finished (${RUN_NAME})"
echo "End: $(date --iso-8601=seconds)"
echo "pytest rc: ${rc}"
echo "Log:   ${LOG}"
echo "JUnit: ${JUNIT}"
echo "HTML:  ${HTML}"
echo "============================================================"

exit "${rc}"
