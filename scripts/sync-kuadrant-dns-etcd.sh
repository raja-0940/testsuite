#!/usr/bin/env bash

set -u
set -o pipefail

TOOLS_NAMESPACE="tools"
ETCD_SELECTOR="app=etcd"
ETCD_ENDPOINT="http://127.0.0.1:2379"

WATCH_NAMESPACES=(
    "kuadrant"
    "kuadrant2"
)

STATE_FILE="/tmp/kuadrant-dns-sync-state.tsv"
LOCK_FILE="/tmp/kuadrant-dns-sync.lock"
SLEEP_SECONDS=1

LOCK_FD=9
CLEANUP_STARTED=false

log_message() {
    printf '%s %s\n' \
        "$(date --iso-8601=seconds)" \
        "$1"
}

require_command() {
    local command_name="$1"

    if ! command -v "${command_name}" >/dev/null 2>&1; then
        log_message "ERROR: Required command not found: ${command_name}"
        exit 1
    fi
}

get_etcd_pod() {
    oc get pod \
        -n "${TOOLS_NAMESPACE}" \
        -l "${ETCD_SELECTOR}" \
        -o json \
        2>/dev/null \
        | jq -r '
            [
                .items[]
                | select(.status.phase == "Running")
                | select(
                    any(
                        .status.containerStatuses[]?;
                        .ready == true
                    )
                )
            ]
            | first
            | .metadata.name // empty
        '
}

etcd_get_value() {
    local etcd_pod="$1"
    local key="$2"

    oc exec \
        -n "${TOOLS_NAMESPACE}" \
        "${etcd_pod}" \
        -- etcdctl \
        --endpoints="${ETCD_ENDPOINT}" \
        get "${key}" \
        --print-value-only \
        2>/dev/null || true
}

etcd_put_value() {
    local etcd_pod="$1"
    local key="$2"
    local value="$3"

    oc exec \
        -n "${TOOLS_NAMESPACE}" \
        "${etcd_pod}" \
        -- etcdctl \
        --endpoints="${ETCD_ENDPOINT}" \
        put "${key}" "${value}" \
        >/dev/null 2>&1
}

etcd_delete_key() {
    local etcd_pod="$1"
    local key="$2"

    oc exec \
        -n "${TOOLS_NAMESPACE}" \
        "${etcd_pod}" \
        -- etcdctl \
        --endpoints="${ETCD_ENDPOINT}" \
        del "${key}" \
        >/dev/null 2>&1
}

encode_state_value() {
    local value="$1"

    if [ -z "${value}" ]; then
        printf '%s' '-'
    else
        printf '%s' "${value}" \
            | base64 \
            | tr -d '\n'
    fi
}

decode_state_value() {
    local encoded_value="$1"

    if [ "${encoded_value}" = "-" ]; then
        printf '%s' ''
    else
        printf '%s' "${encoded_value}" \
            | base64 -d 2>/dev/null || true
    fi
}

state_contains_key() {
    local key="$1"

    awk -F '\t' \
        -v expected_key="${key}" \
        '$1 == expected_key { found = 1 }
         END { exit(found ? 0 : 1) }' \
        "${STATE_FILE}"
}

record_original_value() {
    local key="$1"
    local original_value="$2"
    local encoded_value

    if state_contains_key "${key}"; then
        return 0
    fi

    encoded_value=$(encode_state_value "${original_value}")

    printf '%s\t%s\n' \
        "${key}" \
        "${encoded_value}" \
        >> "${STATE_FILE}"
}

hostname_to_skydns_key() {
    local hostname="$1"
    local hostname_without_dot
    local reversed_path

    hostname_without_dot="${hostname%.}"

    reversed_path=$(printf '%s\n' "${hostname_without_dot}" \
        | awk -F '.' '
            {
                for (i = NF; i >= 1; i--) {
                    printf "/%s", $i
                }
                printf "\n"
            }
        ')

    printf '/skydns%s\n' "${reversed_path}"
}

get_gateway_address() {
    local namespace="$1"
    local gateway_name="$2"
    local gateway_address

    gateway_address=$(oc get gateway \
        "${gateway_name}" \
        -n "${namespace}" \
        -o json \
        2>/dev/null \
        | jq -r '
            [
                .status.addresses[]?
                | select(
                    (.type // "IPAddress") == "IPAddress"
                )
                | .value
            ]
            | first // empty
        ')

    if [ -z "${gateway_address}" ]; then
        gateway_address=$(oc get gateway \
            "${gateway_name}" \
            -n "${namespace}" \
            -o json \
            2>/dev/null \
            | jq -r '
                .status.addresses[0].value // empty
            ')
    fi

    printf '%s\n' "${gateway_address}"
}

gateway_is_programmed() {
    local namespace="$1"
    local gateway_name="$2"

    oc get gateway \
        "${gateway_name}" \
        -n "${namespace}" \
        -o json \
        2>/dev/null \
        | jq -e '
            any(
                .status.conditions[]?;
                .type == "Programmed"
                and
                .status == "True"
            )
        ' \
        >/dev/null 2>&1
}

route_is_accepted() {
    local namespace="$1"
    local route_name="$2"
    local gateway_name="$3"

    oc get httproute \
        "${route_name}" \
        -n "${namespace}" \
        -o json \
        2>/dev/null \
        | jq -e \
            --arg gateway "${gateway_name}" '
                any(
                    .status.parents[]?;
                    .parentRef.name == $gateway
                    and
                    any(
                        .conditions[]?;
                        .type == "Accepted"
                        and
                        .status == "True"
                    )
                    and
                    any(
                        .conditions[]?;
                        .type == "ResolvedRefs"
                        and
                        .status == "True"
                    )
                )
            ' \
        >/dev/null 2>&1
}

flush_hostname_cache() {
    local hostname="$1"

    if command -v rndc >/dev/null 2>&1; then
        rndc flushname "${hostname}" \
            >/dev/null 2>&1 || true
    fi

    if command -v resolvectl >/dev/null 2>&1; then
        resolvectl flush-caches \
            >/dev/null 2>&1 || true
    fi
}

get_resolved_ip() {
    local hostname="$1"

    if command -v dig >/dev/null 2>&1; then
        dig "${hostname}" \
            A \
            +short \
            2>/dev/null \
            | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' \
            | head -n 1
    else
        getent ahostsv4 "${hostname}" \
            2>/dev/null \
            | awk 'NR == 1 { print $1 }'
    fi
}

tcp_port_is_reachable() {
    local address="$1"
    local port="$2"

    timeout 2 \
        bash -c \
        "cat < /dev/null > /dev/tcp/${address}/${port}" \
        >/dev/null 2>&1
}

cleanup() {
    local etcd_pod
    local key
    local encoded_original_value
    local original_value

    if [ "${CLEANUP_STARTED}" = true ]; then
        return 0
    fi

    CLEANUP_STARTED=true

    log_message "Cleaning up synchronized SkyDNS records"

    etcd_pod=$(get_etcd_pod)

    if [ -z "${etcd_pod}" ]; then
        log_message \
            "WARNING: No ready etcd Pod found. State retained at ${STATE_FILE}"
        return 0
    fi

    if [ ! -s "${STATE_FILE}" ]; then
        log_message "No synchronized SkyDNS records require cleanup"
        rm -f "${STATE_FILE}"
        return 0
    fi

    while IFS=$'\t' read -r key encoded_original_value; do
        [ -n "${key}" ] || continue
        [ -n "${encoded_original_value}" ] || continue

        original_value=$(decode_state_value "${encoded_original_value}")

        if [ -n "${original_value}" ]; then
            if etcd_put_value \
                "${etcd_pod}" \
                "${key}" \
                "${original_value}"; then

                log_message \
                    "Restored previous value for ${key}"
            else
                log_message \
                    "WARNING: Failed to restore previous value for ${key}"
            fi
        else
            if etcd_delete_key \
                "${etcd_pod}" \
                "${key}"; then

                log_message \
                    "Deleted helper-created key ${key}"
            else
                log_message \
                    "WARNING: Failed to delete ${key}"
            fi
        fi
    done < "${STATE_FILE}"

    rm -f "${STATE_FILE}"

    if command -v rndc >/dev/null 2>&1; then
        rndc flush >/dev/null 2>&1 || true
    fi

    log_message "SkyDNS cleanup completed"
}

process_namespace() {
    local namespace="$1"
    local route_entries
    local route_name
    local gateway_name
    local gateway_namespace
    local hostname
    local gateway_ip
    local key
    local desired_value
    local current_value
    local resolved_ip
    local etcd_pod

    if ! oc get namespace \
        "${namespace}" \
        >/dev/null 2>&1; then
        return 0
    fi

    route_entries=$(oc get httproute \
        -n "${namespace}" \
        -o json \
        2>/dev/null \
        | jq -r '
            .items[]?
            | . as $route
            | .spec.parentRefs[]?
              as $parent
            | select(
                ($parent.group // "gateway.networking.k8s.io")
                == "gateway.networking.k8s.io"
              )
            | select(
                ($parent.kind // "Gateway")
                == "Gateway"
              )
            | $route.spec.hostnames[]?
              as $hostname
            | select(
                $hostname
                | endswith(".kuadrant.internal")
              )
            | [
                $route.metadata.name,
                $parent.name,
                ($parent.namespace // $route.metadata.namespace),
                $hostname
              ]
            | @tsv
          ' \
        2>/dev/null || true)

    [ -n "${route_entries}" ] || return 0

    while IFS=$'\t' read -r \
        route_name \
        gateway_name \
        gateway_namespace \
        hostname; do

        [ -n "${route_name}" ] || continue
        [ -n "${gateway_name}" ] || continue
        [ -n "${gateway_namespace}" ] || continue
        [ -n "${hostname}" ] || continue

        hostname="${hostname%.}"

        case "${hostname}" in
            *.kuadrant.internal)
                ;;
            *)
                continue
                ;;
        esac

        if ! route_is_accepted \
            "${namespace}" \
            "${route_name}" \
            "${gateway_name}"; then

            log_message \
                "WAITING ${namespace}/${route_name}: route not yet Accepted and ResolvedRefs for Gateway ${gateway_name}"
            continue
        fi

        if ! gateway_is_programmed \
            "${gateway_namespace}" \
            "${gateway_name}"; then

            log_message \
                "WAITING ${gateway_namespace}/${gateway_name}: Gateway is not yet Programmed"
            continue
        fi

        gateway_ip=$(get_gateway_address \
            "${gateway_namespace}" \
            "${gateway_name}")

        if [ -z "${gateway_ip}" ]; then
            log_message \
                "WAITING ${gateway_namespace}/${gateway_name}: no Gateway address for ${hostname}"
            continue
        fi

        if ! printf '%s\n' "${gateway_ip}" \
            | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then

            log_message \
                "WARNING: Gateway ${gateway_namespace}/${gateway_name} address is not IPv4: ${gateway_ip}"
            continue
        fi

        key=$(hostname_to_skydns_key "${hostname}")

        desired_value=$(printf \
            '{"host":"%s","ttl":60}' \
            "${gateway_ip}")

        etcd_pod=$(get_etcd_pod)

        if [ -z "${etcd_pod}" ]; then
            log_message \
                "WAITING: no ready etcd Pod in ${TOOLS_NAMESPACE}"
            continue
        fi

        current_value=$(etcd_get_value \
            "${etcd_pod}" \
            "${key}")

        record_original_value \
            "${key}" \
            "${current_value}"

        if [ "${current_value}" != "${desired_value}" ]; then
            if etcd_put_value \
                "${etcd_pod}" \
                "${key}" \
                "${desired_value}"; then

                log_message \
                    "Created ${hostname} -> ${gateway_ip} using Gateway ${gateway_namespace}/${gateway_name} and HTTPRoute ${namespace}/${route_name} at ${key}"
            else
                log_message \
                    "ERROR: Failed to create ${key}"
                continue
            fi
        else
            log_message \
                "Verified ${hostname} -> ${gateway_ip} using Gateway ${gateway_namespace}/${gateway_name} and HTTPRoute ${namespace}/${route_name}"
        fi

        flush_hostname_cache "${hostname}"

        resolved_ip=$(get_resolved_ip "${hostname}")

        if [ "${resolved_ip}" = "${gateway_ip}" ]; then
            if tcp_port_is_reachable "${gateway_ip}" 443; then
                log_message \
                    "READY ${hostname} -> ${resolved_ip}; Gateway ${gateway_namespace}/${gateway_name}; TCP 443 reachable"
            else
                log_message \
                    "WAITING ${hostname}: DNS is correct at ${resolved_ip}, but TCP 443 is not yet reachable"
            fi
        else
            log_message \
                "WAITING ${hostname}: resolved=${resolved_ip:-none} expected=${gateway_ip}"
        fi

    done <<< "${route_entries}"
}

require_command oc
require_command jq
require_command awk
require_command base64
require_command timeout
require_command grep

exec {LOCK_FD}> "${LOCK_FILE}"

if ! flock -n "${LOCK_FD}"; then
    log_message \
        "ERROR: Another Kuadrant DNS synchronization helper is already running"
    exit 1
fi

touch "${STATE_FILE}"
chmod 0600 "${STATE_FILE}"

trap cleanup EXIT
trap 'exit 0' INT TERM

log_message "Kuadrant exact DNS synchronization started"
log_message "Watching namespaces: ${WATCH_NAMESPACES[*]}"

while true; do
    for namespace in "${WATCH_NAMESPACES[@]}"; do
        process_namespace "${namespace}"
    done

    sleep "${SLEEP_SECONDS}"
done
