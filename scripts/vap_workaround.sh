#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR=$(
    cd "$(dirname "${BASH_SOURCE[0]}")" \
        && pwd -P
)

DEFAULT_REPO_DIR=$(
    cd "${SCRIPT_DIR}/.." \
        && pwd -P
)

REPO_DIR="${DEFAULT_REPO_DIR}"
TOOLS_NAMESPACE="${TOOLS_NAMESPACE:-tools}"
TEST_NAMESPACE="${TEST_NAMESPACE:-kuadrant}"
SYSTEM_NAMESPACE="${SYSTEM_NAMESPACE:-kuadrant-system}"

COREDNS_SERVICE="${COREDNS_SERVICE:-coredns-nodeport}"
COREDNS_ZONE="${KUADRANT_COREDNS_ZONE:-kuadrant.internal}"
COREDNS_HOST="${KUADRANT_COREDNS_DNS_HOST:-}"
COREDNS_PORT="${KUADRANT_COREDNS_DNS_PORT:-}"

DNS_HELPER="${DEFAULT_REPO_DIR}/scripts/sync-kuadrant-dns-etcd.sh"
MANIFEST="${DEFAULT_REPO_DIR}/block-kuadrant-wasm-envoyfilters.yaml"

OUTPUT_DIR=""
DRY_RUN=false
VERBOSE=false
KEEP_HELPER=false
REQUESTED_TEST="all"

HELPER_STARTED_BY_SCRIPT=false
HELPER_PID=""
WORKFLOW_PHASE="initialization"
FINAL_RC=0

EXECUTION_LOG=""
PYTEST_LOG=""
JUNIT_FILE=""
SUMMARY_FILE=""
FAILURES_FILE=""
REPRODUCTION_FILE=""
ENVIRONMENT_FILE=""
EXIT_CODE_FILE=""

TEST_ROUTE_RLP="testsuite/tests/singlecluster/limitador/test_basic_limit.py::test_limit[2 requests every 15 sec-route]"
TEST_GATEWAY_RLP="testsuite/tests/singlecluster/limitador/test_basic_limit.py::test_limit[2 requests every 15 sec-gateway]"
TEST_AUTHORINO="testsuite/tests/singlecluster/authorino/identity/api_key/test_auth_credentials.py::test_custom_selector[authorizationHeader]"
TEST_GATEWAY_READINESS="testsuite/tests/singlecluster/gateway/test_basic.py::test_gateway_readiness"
TEST_GATEWAY_DNS_TLS="testsuite/tests/singlecluster/gateway/test_basic.py::test_gateway_basic_dns_tls"

ALL_TESTS=(
    "${TEST_ROUTE_RLP}"
    "${TEST_GATEWAY_RLP}"
    "${TEST_AUTHORINO}"
    "${TEST_GATEWAY_READINESS}"
    "${TEST_GATEWAY_DNS_TLS}"
)

SELECTED_TESTS=()

usage() {
    cat <<'USAGE'
Usage:
  scripts/vap_workaround.sh [options]

Automates validation and execution of the five validated Kuadrant ppc64le
smoke tests with the existing VAP and native RLP workaround.

Options:
  --help
      Display this help text.

  --dry-run
      Print planned commands without changing cluster resources, starting or
      stopping the DNS helper, or running pytest.

  --verbose
      Enable verbose diagnostic logging.

  --output-dir PATH
      Directory for logs and test artifacts.
      Default: /tmp/kuadrant-vap-smoke-<timestamp>

  --coredns-host ADDRESS
      Reachable node or DNS server address. If omitted, discover a reachable
      node InternalIP for the tools/coredns-nodeport Service.

  --coredns-port PORT
      Reachable CoreDNS port. If omitted, discover the NodePort from the
      tools/coredns-nodeport Service.

  --dns-helper PATH
      DNS synchronization helper.
      Default: <repository>/scripts/sync-kuadrant-dns-etcd.sh

  --manifest PATH
      Existing read-only VAP manifest.
      Default: <repository>/block-kuadrant-wasm-envoyfilters.yaml

  --keep-helper
      Leave the DNS helper running only when this invocation started it.

  --test NAME
      Run one test or all tests. Supported names:
        all
        route-rlp
        gateway-rlp
        authorino
        gateway-readiness
        gateway-dns-tls

Environment variables:
  KUBECONFIG
  TOOLS_NAMESPACE
  TEST_NAMESPACE
  SYSTEM_NAMESPACE
  KUADRANT_COREDNS_ZONE
  KUADRANT_COREDNS_DNS_HOST
  KUADRANT_COREDNS_DNS_PORT

Examples:
  scripts/vap_workaround.sh --help

  scripts/vap_workaround.sh \
    --dry-run \
    --verbose

  scripts/vap_workaround.sh \
    --output-dir /tmp/kuadrant-smoke

  scripts/vap_workaround.sh \
    --test route-rlp \
    --verbose
USAGE
}

timestamp() {
    date --iso-8601=seconds
}

log_line() {
    local level="$1"
    shift

    local message
    message="$*"

    printf '%s level=%s phase=%s message=%q\n' \
        "$(timestamp)" \
        "${level}" \
        "${WORKFLOW_PHASE}" \
        "${message}" \
        | tee -a "${EXECUTION_LOG:-/dev/null}" >&2
}

log_info() {
    log_line "INFO" "$@"
}

log_warn() {
    log_line "WARNING" "$@"
}

log_error() {
    log_line "ERROR" "$@"
}

log_debug() {
    if [ "${VERBOSE}" = true ]; then
        log_line "DEBUG" "$@"
    fi
}

die() {
    local category="$1"
    shift

    log_error "classification=${category} $*"
    FINAL_RC=1
    exit 1
}

shell_join() {
    local output=""
    local value
    local quoted

    for value in "$@"; do
        printf -v quoted '%q' "${value}"
        output+="${quoted} "
    done

    printf '%s' "${output% }"
}

run_command() {
    local command_text

    command_text=$(shell_join "$@")
    log_info "command=${command_text}"

    if [ "${DRY_RUN}" = true ]; then
        printf 'DRY-RUN: %s\n' "${command_text}" \
            | tee -a "${EXECUTION_LOG}"
        return 0
    fi

    "$@"
}

require_command() {
    local command_name="$1"

    command -v "${command_name}" >/dev/null 2>&1 \
        || die \
            "prerequisite/infrastructure failure" \
            "Required command is missing: ${command_name}"
}

require_file() {
    local file="$1"
    local description="$2"

    [ -f "${file}" ] \
        || die \
            "prerequisite/infrastructure failure" \
            "${description} is missing: ${file}"
}

require_executable() {
    local file="$1"
    local description="$2"

    [ -x "${file}" ] \
        || die \
            "prerequisite/infrastructure failure" \
            "${description} is not executable: ${file}"
}

on_error() {
    local rc=$?
    local line="${BASH_LINENO-unknown}"
    local command="${BASH_COMMAND:-unknown}"

    log_error \
        "classification=prerequisite/infrastructure failure rc=${rc} line=${line} command=$(printf '%q' "${command}")"

    FINAL_RC="${rc}"
    exit "${rc}"
}

write_exit_code() {
    if [ -n "${EXIT_CODE_FILE}" ]; then
        printf '%s\n' "${FINAL_RC}" > "${EXIT_CODE_FILE}"
    fi
}

stop_owned_helper() {
    if [ "${HELPER_STARTED_BY_SCRIPT}" != true ]; then
        return 0
    fi

    if [ "${KEEP_HELPER}" = true ]; then
        log_info "Keeping script-owned DNS helper running with PID ${HELPER_PID}"
        return 0
    fi

    if [ -z "${HELPER_PID}" ]; then
        return 0
    fi

    if ! kill -0 "${HELPER_PID}" 2>/dev/null; then
        log_debug "Script-owned DNS helper is already stopped"
        return 0
    fi

    log_info "Stopping script-owned DNS helper PID ${HELPER_PID}"

    kill "${HELPER_PID}" 2>/dev/null || true

    local attempt

    for attempt in $(seq 1 15); do
        if ! kill -0 "${HELPER_PID}" 2>/dev/null; then
            log_info "Script-owned DNS helper stopped cleanly"
            return 0
        fi

        sleep 1
    done

    log_warn \
        "Script-owned DNS helper did not stop in 15 seconds; sending SIGKILL"

    kill -9 "${HELPER_PID}" 2>/dev/null || true
}

cleanup() {
    local rc=$?

    trap - EXIT ERR INT TERM

    if [ "${FINAL_RC}" -eq 0 ] && [ "${rc}" -ne 0 ]; then
        FINAL_RC="${rc}"
    fi

    stop_owned_helper
    write_exit_code

    if [ -n "${OUTPUT_DIR}" ]; then
        log_info "Artifacts directory: ${OUTPUT_DIR}"
    fi

    exit "${FINAL_RC}"
}

parse_arguments() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --help)
                usage
                exit 0
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --verbose)
                VERBOSE=true
                shift
                ;;
            --output-dir)
                [ "$#" -ge 2 ] \
                    || {
                        echo "ERROR: --output-dir requires a value" >&2
                        exit 2
                    }

                OUTPUT_DIR="$2"
                shift 2
                ;;
            --coredns-host)
                [ "$#" -ge 2 ] \
                    || {
                        echo "ERROR: --coredns-host requires a value" >&2
                        exit 2
                    }

                COREDNS_HOST="$2"
                shift 2
                ;;
            --coredns-port)
                [ "$#" -ge 2 ] \
                    || {
                        echo "ERROR: --coredns-port requires a value" >&2
                        exit 2
                    }

                COREDNS_PORT="$2"
                shift 2
                ;;
            --dns-helper)
                [ "$#" -ge 2 ] \
                    || {
                        echo "ERROR: --dns-helper requires a value" >&2
                        exit 2
                    }

                DNS_HELPER="$2"
                shift 2
                ;;
            --manifest)
                [ "$#" -ge 2 ] \
                    || {
                        echo "ERROR: --manifest requires a value" >&2
                        exit 2
                    }

                MANIFEST="$2"
                shift 2
                ;;
            --keep-helper)
                KEEP_HELPER=true
                shift
                ;;
            --test)
                [ "$#" -ge 2 ] \
                    || {
                        echo "ERROR: --test requires a value" >&2
                        exit 2
                    }

                REQUESTED_TEST="$2"
                shift 2
                ;;
            --)
                shift
                break
                ;;
            *)
                echo "ERROR: Unsupported option: $1" >&2
                usage >&2
                exit 2
                ;;
        esac
    done
}

initialize_output() {
    if [ -z "${OUTPUT_DIR}" ]; then
        OUTPUT_DIR="/tmp/kuadrant-vap-smoke-$(date +%Y%m%d-%H%M%S)"
    fi

    mkdir -p "${OUTPUT_DIR}"

    OUTPUT_DIR=$(
        cd "${OUTPUT_DIR}" \
            && pwd -P
    )

    EXECUTION_LOG="${OUTPUT_DIR}/execution.log"
    PYTEST_LOG="${OUTPUT_DIR}/pytest.log"
    JUNIT_FILE="${OUTPUT_DIR}/junit.xml"
    SUMMARY_FILE="${OUTPUT_DIR}/summary.txt"
    FAILURES_FILE="${OUTPUT_DIR}/failures.txt"
    REPRODUCTION_FILE="${OUTPUT_DIR}/reproduction-commands.txt"
    ENVIRONMENT_FILE="${OUTPUT_DIR}/environment.txt"
    EXIT_CODE_FILE="${OUTPUT_DIR}/exit-code.txt"

    : > "${EXECUTION_LOG}"
    : > "${PYTEST_LOG}"
    : > "${SUMMARY_FILE}"
    : > "${FAILURES_FILE}"
    : > "${REPRODUCTION_FILE}"
    : > "${ENVIRONMENT_FILE}"
    : > "${EXIT_CODE_FILE}"
}

select_tests() {
    case "${REQUESTED_TEST}" in
        all)
            SELECTED_TESTS=("${ALL_TESTS[@]}")
            ;;
        route-rlp)
            SELECTED_TESTS=("${TEST_ROUTE_RLP}")
            ;;
        gateway-rlp)
            SELECTED_TESTS=("${TEST_GATEWAY_RLP}")
            ;;
        authorino)
            SELECTED_TESTS=("${TEST_AUTHORINO}")
            ;;
        gateway-readiness)
            SELECTED_TESTS=("${TEST_GATEWAY_READINESS}")
            ;;
        gateway-dns-tls)
            SELECTED_TESTS=("${TEST_GATEWAY_DNS_TLS}")
            ;;
        *)
            die \
                "prerequisite/infrastructure failure" \
                "Unsupported test selection: ${REQUESTED_TEST}"
            ;;
    esac
}

validate_repository() {
    WORKFLOW_PHASE="repository-validation"

    [ -d "${REPO_DIR}/.git" ] \
        || die \
            "prerequisite/infrastructure failure" \
            "Repository root is invalid: ${REPO_DIR}"

    require_file \
        "${REPO_DIR}/config/settings.local.yaml" \
        "Testsuite settings file"

    require_file \
        "${REPO_DIR}/testsuite/kubernetes/envoy_filter.py" \
        "EnvoyFilter implementation"

    require_file \
        "${REPO_DIR}/testsuite/tests/singlecluster/limitador/conftest.py" \
        "Limitador fixture"

    require_file \
        "${MANIFEST}" \
        "VAP manifest"

    require_executable \
        "${DNS_HELPER}" \
        "DNS synchronization helper"

    (
        cd "${REPO_DIR}"
        bash -n "${DNS_HELPER}"
    )

    grep -q \
        'PPC64LE_NATIVE_RLP_WORKAROUND' \
        "${REPO_DIR}/testsuite/tests/singlecluster/limitador/conftest.py" \
        || die \
            "DNS-helper/workaround failure" \
            "PPC64LE_NATIVE_RLP_WORKAROUND support was not found"

    grep -q \
        'create_native_ratelimit_workaround' \
        "${REPO_DIR}/testsuite/tests/singlecluster/limitador/conftest.py" \
        || die \
            "DNS-helper/workaround failure" \
            "Native RLP workaround fixture was not found"

    grep -q \
        'envoy.filters.http.ratelimit' \
        "${REPO_DIR}/testsuite/kubernetes/envoy_filter.py" \
        || die \
            "DNS-helper/workaround failure" \
            "Native Envoy rate-limit filter implementation was not found"

    grep -q \
        'name: block-kuadrant-wasm-envoyfilters' \
        "${MANIFEST}" \
        || die \
            "DNS-helper/workaround failure" \
            "Unexpected VAP manifest policy name"

    grep -q \
        'validationActions:' \
        "${MANIFEST}" \
        || die \
            "DNS-helper/workaround failure" \
            "VAP manifest has no validationActions"

    grep -q \
        'kubernetes.io/metadata.name: kuadrant' \
        "${MANIFEST}" \
        || die \
            "DNS-helper/workaround failure" \
            "VAP manifest is not scoped to namespace kuadrant"

    (
        cd "${REPO_DIR}"

        poetry run python -m py_compile \
            testsuite/kubernetes/envoy_filter.py \
            testsuite/tests/singlecluster/limitador/conftest.py
    )

    log_info "Repository and read-only workaround prerequisites validated"
}

validate_architecture() {
    WORKFLOW_PHASE="architecture-validation"

    local architecture
    architecture=$(uname -m)

    printf 'architecture=%s\n' "${architecture}" \
        >> "${ENVIRONMENT_FILE}"

    if [ "${architecture}" != "ppc64le" ]; then
        log_warn \
            "Architecture is ${architecture}; workaround was validated on ppc64le"
    else
        log_info "Architecture is ppc64le"
    fi
}

validate_cluster() {
    WORKFLOW_PHASE="cluster-validation"

    if [ "${DRY_RUN}" = true ]; then
        log_info "Dry-run: would validate cluster access and required components"
        return 0
    fi

    oc whoami >/dev/null 2>&1 \
        || die \
            "prerequisite/infrastructure failure" \
            "Unable to access the OpenShift cluster"

    local unready_nodes

    unready_nodes=$(oc get nodes \
        -o json \
        | jq -r '
            .items[]
            | select(
                (
                    [
                        .status.conditions[]?
                        | select(
                            .type == "Ready"
                            and
                            .status == "True"
                        )
                    ]
                    | length
                ) == 0
              )
            | .metadata.name
          ')

    [ -z "${unready_nodes}" ] \
        || die \
            "prerequisite/infrastructure failure" \
            "Unready nodes: ${unready_nodes}"

    local kuadrant_ready

    kuadrant_ready=$(oc get kuadrant \
        -A \
        -o json \
        | jq -r '
            [
                .items[]?
                | .status.conditions[]?
                | select(
                    .type == "Ready"
                    and
                    .status == "True"
                )
            ]
            | length
          ')

    [ "${kuadrant_ready}" -gt 0 ] \
        || die \
            "prerequisite/infrastructure failure" \
            "No Kuadrant resource reports Ready=True"

    local gatewayclass_accepted

    gatewayclass_accepted=$(oc get gatewayclass \
        istio \
        -o json \
        | jq -r '
            any(
                .status.conditions[]?;
                .type == "Accepted"
                and
                .status == "True"
            )
          ')

    [ "${gatewayclass_accepted}" = "true" ] \
        || die \
            "prerequisite/infrastructure failure" \
            "GatewayClass istio is not Accepted=True"

    local unready_operands

    unready_operands=$(oc get pods \
        -n "${SYSTEM_NAMESPACE}" \
        -o json \
        | jq -r '
            .items[]
            | select(
                (
                    .metadata.name
                    | test("authorino|limitador")
                )
                and
                (
                    .status.phase != "Running"
                    or
                    any(
                        .status.containerStatuses[]?;
                        .ready != true
                    )
                )
              )
            | .metadata.name
          ')

    [ -z "${unready_operands}" ] \
        || die \
            "prerequisite/infrastructure failure" \
            "Unready Authorino or Limitador Pods: ${unready_operands}"

    printf 'cluster_user=%s\n' "$(oc whoami)" \
        >> "${ENVIRONMENT_FILE}"

    printf 'test_namespace=%s\n' "${TEST_NAMESPACE}" \
        >> "${ENVIRONMENT_FILE}"

    printf 'tools_namespace=%s\n' "${TOOLS_NAMESPACE}" \
        >> "${ENVIRONMENT_FILE}"

    log_info "Cluster prerequisites validated"
}

discover_coredns_port() {
    if [ -n "${COREDNS_PORT}" ]; then
        return 0
    fi

    if [ "${DRY_RUN}" = true ]; then
        COREDNS_PORT="<discovered-coredns-nodeport>"
        return 0
    fi

    COREDNS_PORT=$(oc get service \
        "${COREDNS_SERVICE}" \
        -n "${TOOLS_NAMESPACE}" \
        -o json \
        | jq -r '
            [
                .spec.ports[]?
                | select(
                    .protocol == "UDP"
                    or
                    .protocol == "TCP"
                )
                | .nodePort
            ]
            | map(select(. != null))
            | first // empty
          ')

    [ -n "${COREDNS_PORT}" ] \
        || die \
            "prerequisite/infrastructure failure" \
            "Unable to discover NodePort from ${TOOLS_NAMESPACE}/${COREDNS_SERVICE}"
}

tcp_is_reachable() {
    local host="$1"
    local port="$2"

    timeout 3 \
        bash -c \
        "cat < /dev/null > /dev/tcp/${host}/${port}" \
        >/dev/null 2>&1
}

discover_coredns_host() {
    if [ -n "${COREDNS_HOST}" ]; then
        return 0
    fi

    if [ "${DRY_RUN}" = true ]; then
        COREDNS_HOST="<discovered-reachable-node-ip>"
        return 0
    fi

    local node_ip

    while IFS= read -r node_ip; do
        [ -n "${node_ip}" ] || continue

        log_debug \
            "Testing CoreDNS NodePort ${node_ip}:${COREDNS_PORT}"

        if tcp_is_reachable \
            "${node_ip}" \
            "${COREDNS_PORT}"; then

            COREDNS_HOST="${node_ip}"
            return 0
        fi
    done < <(
        oc get nodes \
            -o json \
            | jq -r '
                .items[]
                | .status.addresses[]?
                | select(.type == "InternalIP")
                | .address
              '
    )

    die \
        "prerequisite/infrastructure failure" \
        "No reachable node InternalIP found for CoreDNS NodePort ${COREDNS_PORT}"
}

configure_coredns() {
    WORKFLOW_PHASE="coredns-discovery"

    discover_coredns_port
    discover_coredns_host

    export KUADRANT_COREDNS_ZONE="${COREDNS_ZONE}"
    export KUADRANT_COREDNS_DNS_HOST="${COREDNS_HOST}"
    export KUADRANT_COREDNS_DNS_PORT="${COREDNS_PORT}"

    printf 'coredns_zone=%s\n' "${COREDNS_ZONE}" \
        >> "${ENVIRONMENT_FILE}"

    printf 'coredns_host=%s\n' "${COREDNS_HOST}" \
        >> "${ENVIRONMENT_FILE}"

    printf 'coredns_port=%s\n' "${COREDNS_PORT}" \
        >> "${ENVIRONMENT_FILE}"

    if [ "${DRY_RUN}" = true ]; then
        log_info \
            "Dry-run: would use CoreDNS endpoint ${COREDNS_HOST}:${COREDNS_PORT}"
        return 0
    fi

    tcp_is_reachable \
        "${COREDNS_HOST}" \
        "${COREDNS_PORT}" \
        || die \
            "prerequisite/infrastructure failure" \
            "CoreDNS endpoint is unreachable: ${COREDNS_HOST}:${COREDNS_PORT}"

    (
        cd "${REPO_DIR}"

        poetry run python - <<'PY'
import os
import kuadrant_coredns_resolve as resolver

expected_zone = os.environ["KUADRANT_COREDNS_ZONE"]
expected_host = os.environ["KUADRANT_COREDNS_DNS_HOST"]
expected_port = int(os.environ["KUADRANT_COREDNS_DNS_PORT"])

assert resolver._ZONE == expected_zone
assert resolver._DNS_HOST == expected_host
assert resolver._DNS_PORT == expected_port

print(
    "PASS: resolver endpoint="
    f"{resolver._DNS_HOST}:{resolver._DNS_PORT}"
)
PY
    ) >> "${EXECUTION_LOG}" 2>&1

    log_info \
        "CoreDNS resolver configured for ${COREDNS_HOST}:${COREDNS_PORT}"
}

find_existing_helper() {
    pgrep -f \
        "${DNS_HELPER}" \
        | head -n 1 \
        || true
}

start_dns_helper() {
    WORKFLOW_PHASE="dns-helper"

    local existing_pid
    existing_pid=$(find_existing_helper)

    if [ -n "${existing_pid}" ]; then
        log_info \
            "Preserving existing DNS helper PID ${existing_pid}; ownership remains external"
        return 0
    fi

    if [ "${DRY_RUN}" = true ]; then
        log_info \
            "Dry-run: would start DNS helper $(printf '%q' "${DNS_HELPER}")"
        return 0
    fi

    local helper_log
    helper_log="${OUTPUT_DIR}/dns-helper.log"

    nohup "${DNS_HELPER}" \
        > "${helper_log}" \
        2>&1 &

    HELPER_PID=$!
    HELPER_STARTED_BY_SCRIPT=true

    log_info \
        "Started script-owned DNS helper PID ${HELPER_PID}"

    sleep 3

    kill -0 "${HELPER_PID}" 2>/dev/null \
        || {
            cat "${helper_log}" >> "${EXECUTION_LOG}" || true

            die \
                "DNS-helper/workaround failure" \
                "DNS helper exited during startup"
        }

    grep -q \
        'Kuadrant exact DNS synchronization started' \
        "${helper_log}" \
        || die \
            "DNS-helper/workaround failure" \
            "DNS helper startup message was not found"
}

write_reproduction_commands() {
    {
        printf '# Reproduction commands\n\n'

        printf 'cd %q\n' "${REPO_DIR}"

        printf 'export KUADRANT_COREDNS_ZONE=%q\n' \
            "${COREDNS_ZONE}"

        printf 'export KUADRANT_COREDNS_DNS_HOST=%q\n' \
            "${COREDNS_HOST}"

        printf 'export KUADRANT_COREDNS_DNS_PORT=%q\n\n' \
            "${COREDNS_PORT}"

        local node_id

        for node_id in "${SELECTED_TESTS[@]}"; do
            printf 'PPC64LE_NATIVE_RLP_WORKAROUND=true poetry run pytest '
            printf '%q ' \
                --tb=long \
                -p \
                no:rerunfailures \
                --log-cli-level=INFO \
                -n0 \
                -v \
                -s \
                "${node_id}"
            printf '\n\n'
        done
    } > "${REPRODUCTION_FILE}"
}

validate_collection() {
    WORKFLOW_PHASE="test-collection"

    if [ "${DRY_RUN}" = true ]; then
        log_info \
            "Dry-run: would collect ${#SELECTED_TESTS[@]} selected smoke test(s)"
        return 0
    fi

    local collection_log
    collection_log="${OUTPUT_DIR}/collection.log"

    set +e

    (
        cd "${REPO_DIR}"

        poetry run pytest \
            --collect-only \
            -q \
            "${SELECTED_TESTS[@]}"
    ) 2>&1 \
        | tee "${collection_log}" \
        | tee -a "${EXECUTION_LOG}"

    local collection_rc=${PIPESTATUS[0]}

    set -e

    [ "${collection_rc}" -eq 0 ] \
        || die \
            "prerequisite/infrastructure failure" \
            "Pytest collection failed with return code ${collection_rc}"

    log_info \
        "Collected ${#SELECTED_TESTS[@]} selected smoke test(s)"
}

parse_junit() {
    if [ ! -s "${JUNIT_FILE}" ]; then
        {
            echo "classification=test failure"
            echo "junit_status=missing"
        } > "${SUMMARY_FILE}"

        return 1
    fi

    JUNIT_FILE="${JUNIT_FILE}" \
    SUMMARY_FILE="${SUMMARY_FILE}" \
    FAILURES_FILE="${FAILURES_FILE}" \
    python3 - <<'PY'
from pathlib import Path
import os
import xml.etree.ElementTree as ET

junit_path = Path(os.environ["JUNIT_FILE"])
summary_path = Path(os.environ["SUMMARY_FILE"])
failures_path = Path(os.environ["FAILURES_FILE"])

root = ET.parse(junit_path).getroot()

if root.tag == "testsuites":
    suites = list(root.findall("testsuite"))
else:
    suites = [root]

tests = sum(int(s.attrib.get("tests", 0)) for s in suites)
failures = sum(int(s.attrib.get("failures", 0)) for s in suites)
errors = sum(int(s.attrib.get("errors", 0)) for s in suites)
skipped = sum(
    int(s.attrib.get("skipped", s.attrib.get("disabled", 0)))
    for s in suites
)
passed = tests - failures - errors - skipped

with summary_path.open("w", encoding="utf-8") as stream:
    stream.write(f"tests={tests}\n")
    stream.write(f"passed={passed}\n")
    stream.write(f"failed={failures}\n")
    stream.write(f"errors={errors}\n")
    stream.write(f"skipped={skipped}\n")

failure_lines = []

for case in root.iter("testcase"):
    failure = case.find("failure")
    error = case.find("error")

    if failure is None and error is None:
        continue

    node = (
        f"{case.attrib.get('classname', '')}::"
        f"{case.attrib.get('name', '')}"
    )

    detail = failure if failure is not None else error
    message = detail.attrib.get("message", "")
    text = (detail.text or "").strip()

    failure_lines.append(node)
    failure_lines.append(f"message={message}")
    failure_lines.append(text)
    failure_lines.append("")

failures_path.write_text(
    "\n".join(failure_lines),
    encoding="utf-8",
)
PY
}

classify_failure() {
    if grep -qiE \
        'Name or service not known|NO ANSWER|DNS helper|CoreDNS' \
        "${PYTEST_LOG}"; then

        printf '%s\n' \
            "classification=DNS-helper/workaround failure" \
            >> "${SUMMARY_FILE}"

        return 0
    fi

    if grep -qiE \
        'Unable to connect|connection refused|timed out|Forbidden|Unauthorized|No route to host' \
        "${PYTEST_LOG}"; then

        printf '%s\n' \
            "classification=prerequisite/infrastructure failure" \
            >> "${SUMMARY_FILE}"

        return 0
    fi

    printf '%s\n' \
        "classification=test failure" \
        >> "${SUMMARY_FILE}"
}

run_tests() {
    WORKFLOW_PHASE="smoke-tests"

    write_reproduction_commands

    if [ "${DRY_RUN}" = true ]; then
        local command=(
            poetry run pytest
            --tb=short
            -p no:rerunfailures
            --log-cli-level=INFO
            -n0
            --ignore=testsuite/tests/singlecluster/ui
            -v
            -s
            "--junitxml=${JUNIT_FILE}"
        )

        command+=("${SELECTED_TESTS[@]}")

        log_info \
            "Dry-run: would execute PPC64LE_NATIVE_RLP_WORKAROUND=true $(shell_join "${command[@]}")"

        {
            echo "dry_run=true"
            echo "tests_selected=${#SELECTED_TESTS[@]}"
            echo "passed=not-executed"
            echo "failed=not-executed"
            echo "errors=not-executed"
            echo "skipped=not-executed"
        } > "${SUMMARY_FILE}"

        return 0
    fi

    set +e

    (
        cd "${REPO_DIR}"

        PPC64LE_NATIVE_RLP_WORKAROUND=true \
        poetry run pytest \
            --tb=short \
            -p no:rerunfailures \
            --log-cli-level=INFO \
            -n0 \
            --ignore=testsuite/tests/singlecluster/ui \
            -v \
            -s \
            --junitxml="${JUNIT_FILE}" \
            "${SELECTED_TESTS[@]}"
    ) 2>&1 \
        | tee "${PYTEST_LOG}" \
        | tee -a "${EXECUTION_LOG}"

    local pytest_rc=${PIPESTATUS[0]}

    set -e

    printf '%s\n' "${pytest_rc}" > "${EXIT_CODE_FILE}"

    parse_junit || true

    if [ "${pytest_rc}" -ne 0 ]; then
        classify_failure

        FINAL_RC="${pytest_rc}"

        log_error \
            "Smoke tests failed with return code ${pytest_rc}"

        return "${pytest_rc}"
    fi

    printf '%s\n' \
        "classification=success" \
        >> "${SUMMARY_FILE}"

    log_info "Smoke tests completed successfully"
}

write_environment_metadata() {
    {
        printf 'repository=%s\n' "${REPO_DIR}"
        printf 'branch=%s\n' "$(git -C "${REPO_DIR}" branch --show-current)"
        printf 'head=%s\n' "$(git -C "${REPO_DIR}" rev-parse HEAD)"
        printf 'architecture=%s\n' "$(uname -m)"
        printf 'dry_run=%s\n' "${DRY_RUN}"
        printf 'test_selection=%s\n' "${REQUESTED_TEST}"
        printf 'tools_namespace=%s\n' "${TOOLS_NAMESPACE}"
        printf 'test_namespace=%s\n' "${TEST_NAMESPACE}"
        printf 'system_namespace=%s\n' "${SYSTEM_NAMESPACE}"
        printf 'dns_helper=%s\n' "${DNS_HELPER}"
        printf 'manifest=%s\n' "${MANIFEST}"
    } > "${ENVIRONMENT_FILE}"
}

main() {
    parse_arguments "$@"
    initialize_output

    trap on_error ERR
    trap cleanup EXIT INT TERM

    WORKFLOW_PHASE="prerequisites"

    require_command bash
    require_command date
    require_command git
    require_command grep
    require_command jq
    require_command oc
    require_command pgrep
    require_command poetry
    require_command python3
    require_command tee
    require_command timeout

    select_tests
    write_environment_metadata
    validate_repository
    validate_architecture
    validate_cluster
    configure_coredns
    start_dns_helper
    validate_collection

    set +e
    run_tests
    FINAL_RC=$?
    set -e

    if [ "${FINAL_RC}" -eq 0 ]; then
        log_info "Workflow completed successfully"
    else
        log_error \
            "Workflow failed; review ${SUMMARY_FILE}, ${FAILURES_FILE}, and ${PYTEST_LOG}"
    fi

    return "${FINAL_RC}"
}

main "$@"
