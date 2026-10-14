#!/usr/bin/env bash
# PipelinePolicy extension setup (from the Kuadrant helm-charts-olm repo) + PipelinePolicy e2e run.
#
# What it does
#   - Fetches Kuadrant/helm-charts-olm at a pinned revision into a scratch checkout (never modified).
#   - Renders ONLY the standalone-extension templates (templates/extensions/01..04: Namespace, CRD,
#     ServiceAccount/ClusterRole/ClusterRoleBinding, Deployment) with `helm template`, using
#     example-extensionCRD.yaml as the values file (it is a Helm values file, not a CRD manifest).
#   - Applies them with `oc apply`. It does NOT run the repo's install.sh (that script also installs
#     operators, Subscriptions, OperatorGroups, a second Kuadrant CR, Istio and the test tools, which would
#     collide with an existing RHCL install).
#   - Never touches the RHCL CSV, Subscription, OperatorGroup, operator Deployment or Kuadrant CR; it
#     snapshots them before/after the install and fails if the CSV or operator Deployment changed.
#   - Runs the PipelinePolicy e2e tests via run-kuadrant-e2e.sh, only after the extension has completed its
#     handshake with the operator (a CRD alone makes the tests fail instead of skip).
#
# Usage (run from anywhere; default is read-only help):
#   ./scripts/pipeline-policy-e2e.sh --check                  # read-only status of CRD/extension/handshake
#   ./scripts/pipeline-policy-e2e.sh --render                 # render + dry-run validate, apply nothing
#   ./scripts/pipeline-policy-e2e.sh --install                # apply the extension (idempotent)
#   ./scripts/pipeline-policy-e2e.sh --test                   # run pipeline_policy tests (needs extension ready)
#   ./scripts/pipeline-policy-e2e.sh --all                    # --install then --test
#   ./scripts/pipeline-policy-e2e.sh --test -- <pytest paths/ids...>   # selected tests only
#   ./scripts/pipeline-policy-e2e.sh --uninstall [--delete-crd] [--yes]
#
# Options:
#   --force-crd        re-apply the CRD even if it already exists (default: an existing CRD is left alone)
#   --pre              run kuadrant-pre-e2e.sh first when the e2e env file is missing
#   --results-dir DIR  output directory (default: $RESULTS_ROOT/pipelinepolicy-<timestamp>)
#   --yes              do not prompt (needed for --delete-crd when PipelinePolicy objects exist)
#
# Environment overrides:
#   KUBECONFIG          default: current env, else /root/openstack-upi/auth/kubeconfig
#   HELM_REPO_URL       default: https://github.com/Kuadrant/helm-charts-olm.git
#   HELM_REPO_REF       default: 55df600e7febb9b011518513894cf6447866e733 (pinned; verified revision)
#   HELM_REPO_DIR       scratch checkout (default: /root/scratch/helm-charts-olm)
#   EXTENSION_CRD_FILE  helm values file with the extensionCRD list (default: <repo>/example-extensionCRD.yaml)
#   EXT_IMAGE           default: quay.io/kuadrant/internal-extensions@sha256:a80b7b6f... (multi-arch index
#                       incl. ppc64le; the :v1.0.x tags are amd64 only, :latest is mutable)
#   EXT_NAMESPACE       default: kuadrant-extensions
#   OPERATOR_NAMESPACE  default: auto-detected from the kuadrant-operator-extensions Service
#   RESULTS_ROOT        default: /root/test/results
#   ENV_FILE            default: /tmp/kuadrant-ppc64le-e2e-env.sh (written by kuadrant-pre-e2e.sh)
#   HANDSHAKE_TIMEOUT   seconds to wait for the extension handshake (default: 180)
#
# Exit codes: 0 ok, 1 error / test failures, 2 prerequisite failed, 3 existing RHCL objects changed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="${REPO_DIR:-$(dirname "$SCRIPT_DIR")}"

HELM_REPO_URL="${HELM_REPO_URL:-https://github.com/Kuadrant/helm-charts-olm.git}"
HELM_REPO_REF="${HELM_REPO_REF:-55df600e7febb9b011518513894cf6447866e733}"
HELM_REPO_DIR="${HELM_REPO_DIR:-/root/scratch/helm-charts-olm}"
EXT_IMAGE="${EXT_IMAGE:-quay.io/kuadrant/internal-extensions@sha256:a80b7b6f73fe3ebf725f8d6777a360672e54dccf24a0d7f1fa5d567b1368f93b}"
EXT_NAMESPACE="${EXT_NAMESPACE:-kuadrant-extensions}"
EXT_NAME="pipeline-policy"                    # chart value kuadrant.extensionsName
CRD_NAME="pipelinepolicies.extensions.kuadrant.io"
RESULTS_ROOT="${RESULTS_ROOT:-/root/test/results}"
ENV_FILE="${ENV_FILE:-/tmp/kuadrant-ppc64le-e2e-env.sh}"
HANDSHAKE_TIMEOUT="${HANDSHAKE_TIMEOUT:-180}"
TEST_PATH_DEFAULT="testsuite/tests/singlecluster/extensions/pipeline_policy/"

if [[ -z "${KUBECONFIG:-}" && -f /root/openstack-upi/auth/kubeconfig ]]; then
    export KUBECONFIG=/root/openstack-upi/auth/kubeconfig
fi

ACTION=""; FORCE_CRD=0; RUN_PRE=0; ASSUME_YES=0; DELETE_CRD=0; RUN_DIR=""; TEST_ARGS=()

log()  { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
ok()   { log "OK    $*"; }
warn() { log "WARN  $*" >&2; }
die()  { local rc="${2:-1}"; log "ERROR $1" >&2; exit "$rc"; }

usage() { sed -n '2,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --check|--render|--install|--test|--all|--uninstall) ACTION="${1#--}" ;;
        --force-crd)   FORCE_CRD=1 ;;
        --pre)         RUN_PRE=1 ;;
        --delete-crd)  DELETE_CRD=1 ;;
        --yes)         ASSUME_YES=1 ;;
        --results-dir) RUN_DIR="${2:?--results-dir needs a value}"; shift ;;
        -h|--help)     usage 0 ;;
        --)            shift; TEST_ARGS=("$@"); break ;;
        *)             echo "Unknown option: $1" >&2; usage 2 ;;
    esac
    shift
done
[[ -n "$ACTION" ]] || usage 2
RUN_DIR="${RUN_DIR:-${RESULTS_ROOT}/pipelinepolicy-$(date +%Y%m%d-%H%M%S)}"

# ---------------------------------------------------------------- prerequisites (read-only)
OP_NS=""; CSV_NS=""; CSV_NAME=""

prereqs() {
    local t
    for t in oc helm git python3; do command -v "$t" >/dev/null 2>&1 || die "required tool not found: $t" 2; done
    oc whoami >/dev/null 2>&1 || die "oc is not logged in (KUBECONFIG=${KUBECONFIG:-unset})" 2
    ok "cluster: $(oc whoami --show-server) as $(oc whoami)"

    local arch
    arch="$(oc get nodes -o jsonpath='{range .items[*]}{.status.nodeInfo.architecture}{"\n"}{end}' | sort -u | paste -sd, -)"
    log "node architectures: ${arch}"
    if [[ "$arch" == *ppc64le* && "$EXT_IMAGE" != *@sha256:* ]]; then
        warn "EXT_IMAGE is not digest-pinned; only the multi-arch :latest index has ppc64le (v1.0.x tags are amd64 only)"
    fi

    # Namespace of the operator = namespace of the Service that serves the extension API.
    OP_NS="${OPERATOR_NAMESPACE:-$(oc get svc -A --field-selector metadata.name=kuadrant-operator-extensions \
        -o jsonpath='{.items[0].metadata.namespace}' 2>/dev/null)}"
    [[ -n "$OP_NS" ]] || die "Service kuadrant-operator-extensions not found: this operator build does not serve the extension API" 2
    ok "operator extension service: kuadrant-operator-extensions.${OP_NS}.svc:50052"

    # Installed RHCL / Kuadrant operator CSV (OLM): detected, never modified.
    # Look only in the operator namespace: with a global OperatorGroup OLM copies the CSV into every namespace.
    CSV_NS="$OP_NS"
    CSV_NAME="$(oc get csv -n "$CSV_NS" --no-headers 2>/dev/null \
        | awk '$1 ~ /^(rhcl|kuadrant)-operator/ && $NF=="Succeeded" {print $1; exit}')"
    [[ -n "$CSV_NAME" ]] || die "no succeeded rhcl-operator/kuadrant-operator CSV in ${CSV_NS}; install RHCL first" 2
    ok "operator CSV: ${CSV_NS}/${CSV_NAME}"

    local ready
    ready="$(oc get kuadrant -A -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)"
    [[ "$ready" == "True" ]] || die "Kuadrant CR is not Ready (got '${ready:-none}')" 2
    ok "Kuadrant CR Ready"
}

# Snapshot of the objects this script must never change
snapshot_rhcl() { # outfile
    {
        echo "csv.generation=$(oc get csv -n "$CSV_NS" "$CSV_NAME" -o jsonpath='{.metadata.generation}')"
        echo "csv.phase=$(oc get csv -n "$CSV_NS" "$CSV_NAME" -o jsonpath='{.status.phase}')"
        echo "csv.resourceVersion=$(oc get csv -n "$CSV_NS" "$CSV_NAME" -o jsonpath='{.metadata.resourceVersion}')"
        echo "operator.deploy.generation=$(oc get deploy -n "$OP_NS" kuadrant-operator-controller-manager -o jsonpath='{.metadata.generation}' 2>/dev/null)"
        echo "operator.pod=$(oc get pod -n "$OP_NS" --no-headers 2>/dev/null | awk '/^kuadrant-operator-controller-manager/ {print $1"/"$4; exit}')"
        echo "subscriptions=$(oc get subscription -n "$CSV_NS" -o jsonpath='{range .items[*]}{.metadata.name}:{.metadata.generation};{end}')"
        echo "kuadrant.generation=$(oc get kuadrant -A -o jsonpath='{.items[0].metadata.generation}' 2>/dev/null)"
    } > "$1"
}

compare_snapshots() { # before after
    local rc=0 k b a
    for k in csv.generation csv.phase operator.deploy.generation operator.pod subscriptions kuadrant.generation; do
        b="$(grep "^${k}=" "$1" | cut -d= -f2-)"; a="$(grep "^${k}=" "$2" | cut -d= -f2-)"
        if [[ "$b" != "$a" ]]; then warn "RHCL object changed: ${k}: '${b}' -> '${a}'"; rc=3; fi
    done
    if [[ "$(grep '^csv.resourceVersion=' "$1")" != "$(grep '^csv.resourceVersion=' "$2")" ]]; then
        warn "CSV resourceVersion changed (status update by OLM/another actor?): review ${1} vs ${2}"
    fi
    [[ $rc -eq 0 ]] && ok "CSV, Subscriptions, operator Deployment/pod and Kuadrant CR unchanged"
    return $rc
}

# ---------------------------------------------------------------- helm repo + render
fetch_chart() {
    if [[ ! -d "$HELM_REPO_DIR/.git" ]]; then
        log "cloning $HELM_REPO_URL -> $HELM_REPO_DIR"
        mkdir -p "$(dirname "$HELM_REPO_DIR")"
        git clone --quiet "$HELM_REPO_URL" "$HELM_REPO_DIR" || die "git clone failed"
    fi
    if ! git -C "$HELM_REPO_DIR" cat-file -e "${HELM_REPO_REF}^{commit}" 2>/dev/null; then
        git -C "$HELM_REPO_DIR" fetch --quiet origin || die "git fetch failed"
    fi
    if [[ -n "$(git -C "$HELM_REPO_DIR" status --porcelain)" ]]; then
        warn "$HELM_REPO_DIR has local changes; using it as-is (not checking out ${HELM_REPO_REF})"
    else
        git -C "$HELM_REPO_DIR" checkout --quiet --detach "$HELM_REPO_REF" || die "cannot check out ${HELM_REPO_REF}"
    fi
    ok "helm-charts-olm @ $(git -C "$HELM_REPO_DIR" rev-parse HEAD)"
}

RENDER_DIR=""
render() {
    fetch_chart
    RENDER_DIR="${RUN_DIR}/rendered"; mkdir -p "$RENDER_DIR"
    local values="${EXTENSION_CRD_FILE:-$HELM_REPO_DIR/example-extensionCRD.yaml}"
    [[ -f "$values" ]] || die "extension values file not found: $values"
    # Copy: the checkout stays untouched (the repo expects the file to be named extensionCRD.yaml)
    cp "$values" "$RENDER_DIR/extensionCRD.yaml"

    local chart="$HELM_REPO_DIR/charts/kuadrant-operators" t
    [[ -d "$chart/templates/extensions" ]] || die "chart has no templates/extensions: this revision does not support extensions"
    for t in 01-namespace 02-crd 03-rbac 04-deployment; do
        helm template "$EXT_NAME" "$chart" -f "$RENDER_DIR/extensionCRD.yaml" \
            --set "kuadrant.namespace=${OP_NS}" \
            --set "kuadrant.extensionsImage=${EXT_IMAGE}" \
            --set "kuadrant.extensionsNamespace=${EXT_NAMESPACE}" \
            --show-only "templates/extensions/${t}.yaml" > "$RENDER_DIR/${t}.yaml" 2> "$RENDER_DIR/${t}.err" \
            || { cat "$RENDER_DIR/${t}.err" >&2; die "helm template failed for ${t}"; }
        [[ -s "$RENDER_DIR/${t}.yaml" ]] || die "template ${t} rendered empty (extensionsImage/extensionCRD not set?)"
    done
    # Guard: the rendered set must stay inside the isolated-extension scope
    if cat "$RENDER_DIR"/0?-*.yaml | grep -qE '^kind: (Subscription|OperatorGroup|CatalogSource|ClusterServiceVersion|Kuadrant|Istio|IstioCNI|ClusterIssuer|NetworkPolicy)$'; then
        die "rendered manifests contain operator/OLM/mesh kinds; refusing (chart revision changed?)"
    fi
    grep -q "kuadrant-operator-extensions.${OP_NS}.svc:50052" "$RENDER_DIR/04-deployment.yaml" \
        || die "extension address does not point at ${OP_NS}"
    grep -q "image: ${EXT_IMAGE}\$" "$RENDER_DIR/04-deployment.yaml" || die "rendered image differs from EXT_IMAGE"
    ok "rendered to ${RENDER_DIR}: $(cat "$RENDER_DIR"/0?-*.yaml | grep -E '^kind:' | sort | uniq -c | awk '{printf "%s×%s ", $1, $3}')"
    if ! grep -q 'exportToHost' "$RENDER_DIR/02-crd.yaml"; then
        warn "CRD from the example file lacks the 'store' action fields (exportToHost/path/value); no current test uses 'store'"
    fi
}

dry_run() {
    local f
    for f in 01-namespace 02-crd; do
        oc apply --dry-run=server --validate=strict -f "$RENDER_DIR/${f}.yaml" >/dev/null \
            || die "server dry-run failed for ${f}"
        ok "server dry-run ${f}"
    done
    if oc get ns "$EXT_NAMESPACE" >/dev/null 2>&1; then
        for f in 03-rbac 04-deployment; do
            oc apply --dry-run=server --validate=strict -f "$RENDER_DIR/${f}.yaml" >/dev/null \
                || die "server dry-run failed for ${f}"
            ok "server dry-run ${f}"
        done
    else
        for f in 03-rbac 04-deployment; do
            oc apply --dry-run=client -f "$RENDER_DIR/${f}.yaml" >/dev/null || die "client dry-run failed for ${f}"
            ok "client dry-run ${f} (namespace ${EXT_NAMESPACE} does not exist yet, server dry-run not possible)"
        done
    fi
}

# ---------------------------------------------------------------- install
extension_ready() { # returns 0 when pod is Ready and handshake accepted
    oc -n "$EXT_NAMESPACE" get deploy "${EXT_NAME}-extension" >/dev/null 2>&1 || return 1
    [[ "$(oc -n "$EXT_NAMESPACE" get deploy "${EXT_NAME}-extension" -o jsonpath='{.status.availableReplicas}')" -ge 1 ]] 2>/dev/null || return 1
    # grep -c (not -q): -q exits early, SIGPIPEs `oc logs` and fails the pipeline under pipefail
    [[ "$(oc -n "$EXT_NAMESPACE" logs "deploy/${EXT_NAME}-extension" 2>/dev/null \
        | grep -c '"handshake accepted".*"policyKind":"PipelinePolicy"')" -ge 1 ]]
}

wait_ready() {
    log "waiting up to ${HANDSHAKE_TIMEOUT}s for rollout and extension handshake"
    oc -n "$EXT_NAMESPACE" rollout status "deploy/${EXT_NAME}-extension" --timeout="${HANDSHAKE_TIMEOUT}s" >/dev/null \
        || { oc -n "$EXT_NAMESPACE" get pod; die "extension rollout did not finish (check SCC/image pull/events)"; }
    local end=$((SECONDS + HANDSHAKE_TIMEOUT))
    until extension_ready; do
        (( SECONDS < end )) || { oc -n "$EXT_NAMESPACE" logs "deploy/${EXT_NAME}-extension" --tail=20 >&2; \
            die "no 'handshake accepted' from the operator within ${HANDSHAKE_TIMEOUT}s (RBAC, network or protocol mismatch?)"; }
        sleep 3
    done
    ok "extension handshake accepted by the operator"
    if [[ "$(oc -n "$OP_NS" logs deploy/kuadrant-operator-controller-manager -c manager --since=30m 2>/dev/null \
        | grep -c "handshake accepted.*system:serviceaccount:${EXT_NAMESPACE}:${EXT_NAME}-extension")" -ge 1 ]]; then
        ok "operator log confirms handshake for serviceaccount ${EXT_NAMESPACE}/${EXT_NAME}-extension"
    else
        warn "operator log (last 30m) has no matching handshake line; extension-side handshake was accepted"
    fi
}

do_install() {
    mkdir -p "$RUN_DIR"
    render; dry_run
    snapshot_rhcl "$RUN_DIR/rhcl-before.txt"

    oc apply -f "$RENDER_DIR/01-namespace.yaml" >/dev/null || die "namespace apply failed"
    ok "namespace ${EXT_NAMESPACE}"

    if oc get crd "$CRD_NAME" >/dev/null 2>&1 && [[ $FORCE_CRD -eq 0 ]]; then
        ok "CRD ${CRD_NAME} already exists: left unchanged (use --force-crd to re-apply)"
    else
        oc apply -f "$RENDER_DIR/02-crd.yaml" >/dev/null || die "CRD apply failed"
        oc wait "crd/${CRD_NAME}" --for=condition=Established --timeout=60s >/dev/null || die "CRD not Established"
        ok "CRD ${CRD_NAME} Established"
    fi
    oc apply -f "$RENDER_DIR/03-rbac.yaml" >/dev/null || die "RBAC apply failed"
    ok "ServiceAccount/ClusterRole/ClusterRoleBinding"
    oc apply -f "$RENDER_DIR/04-deployment.yaml" >/dev/null || die "Deployment apply failed"
    ok "Deployment ${EXT_NAME}-extension (image ${EXT_IMAGE##*/})"

    wait_ready
    snapshot_rhcl "$RUN_DIR/rhcl-after.txt"
    compare_snapshots "$RUN_DIR/rhcl-before.txt" "$RUN_DIR/rhcl-after.txt" || exit 3
}

# ---------------------------------------------------------------- check (read only)
do_check() {
    local rc=0
    if oc get crd "$CRD_NAME" >/dev/null 2>&1; then
        ok "CRD ${CRD_NAME} present (olm.managed label: $(oc get crd "$CRD_NAME" -o jsonpath='{.metadata.labels.olm\.managed}' 2>/dev/null || true))"
    else warn "CRD ${CRD_NAME} missing: pipeline_policy tests will SKIP"; rc=1; fi
    if oc -n "$EXT_NAMESPACE" get deploy "${EXT_NAME}-extension" >/dev/null 2>&1; then
        ok "Deployment ${EXT_NAMESPACE}/${EXT_NAME}-extension: available=$(oc -n "$EXT_NAMESPACE" get deploy "${EXT_NAME}-extension" -o jsonpath='{.status.availableReplicas}') image=$(oc -n "$EXT_NAMESPACE" get deploy "${EXT_NAME}-extension" -o jsonpath='{.spec.template.spec.containers[0].image}')"
    else warn "extension Deployment missing: a CRD alone makes the tests FAIL, not pass"; rc=1; fi
    if extension_ready; then ok "extension handshake accepted (PipelinePolicy, protocol 0.1.0)"; else warn "no accepted handshake in extension logs"; rc=1; fi
    log "existing PipelinePolicy objects: $(oc get pipelinepolicies -A --no-headers 2>/dev/null | wc -l)"
    return $rc
}

# ---------------------------------------------------------------- tests
do_test() {
    mkdir -p "$RUN_DIR"
    oc get crd "$CRD_NAME" >/dev/null 2>&1 || die "CRD missing: run --install first" 2
    extension_ready || die "extension is not ready/handshaken: run --install first (refusing to run tests that would fail on missing enforcement)" 2
    if [[ ! -f "$ENV_FILE" ]]; then
        if [[ $RUN_PRE -eq 1 ]]; then
            log "env file missing, running kuadrant-pre-e2e.sh"
            "$SCRIPT_DIR/kuadrant-pre-e2e.sh" || die "kuadrant-pre-e2e.sh failed" 2
        else
            die "$ENV_FILE not found: run scripts/kuadrant-pre-e2e.sh first (or pass --pre)" 2
        fi
    fi
    pgrep -f "^[^ ]*python[0-9.]* -u -m pytest" >/dev/null && die "another pytest run is active" 2

    [[ -f "$RUN_DIR/rhcl-before.txt" ]] || snapshot_rhcl "$RUN_DIR/rhcl-before.txt"
    local targets=("${TEST_ARGS[@]}"); [[ ${#targets[@]} -gt 0 ]] || targets=("$TEST_PATH_DEFAULT")
    log "running: ${targets[*]}"
    log "results: $RUN_DIR"
    ( cd "$REPO_DIR" && RESULTS_DIR="$RUN_DIR" RUN_NAME=pipeline-policy ENV_FILE="$ENV_FILE" PYTHONUNBUFFERED=1 \
        LOG_FILE="$RUN_DIR/pipeline-policy-e2e.log" JUNIT_FILE="$RUN_DIR/junit-pipeline-policy.xml" \
        HTML_FILE="$RUN_DIR/report-pipeline-policy.html" \
        "$SCRIPT_DIR/run-kuadrant-e2e.sh" "${targets[@]}" ) 2>&1 | tee "$RUN_DIR/pipeline-policy.console"
    local rc=${PIPESTATUS[0]}
    echo "$rc" > "$RUN_DIR/exit-code.txt"

    local summary skipped
    summary="$(grep -aE '^=+ .*(passed|failed|skipped|error).* in [0-9.]+s' "$RUN_DIR/pipeline-policy-e2e.log" 2>/dev/null | tail -1)"
    { echo "pytest rc: $rc"; echo "pytest summary: ${summary:-n/a}"; echo "targets: ${targets[*]}"; \
      echo "extension image: $EXT_IMAGE"; echo "helm-charts-olm: $(git -C "$HELM_REPO_DIR" rev-parse HEAD 2>/dev/null)"; } > "$RUN_DIR/summary.txt"
    skipped="$(grep -aoE '[0-9]+ skipped' <<<"$summary" | head -1)"
    [[ -z "$skipped" ]] || warn "some tests were skipped ($skipped): inspect $RUN_DIR/pipeline-policy-e2e.log (-rs section)"
    log "summary: ${summary:-n/a}"
    # Existing RHCL objects must still be untouched after the load
    snapshot_rhcl "$RUN_DIR/rhcl-after-tests.txt"
    compare_snapshots "$RUN_DIR/rhcl-before.txt" "$RUN_DIR/rhcl-after-tests.txt" || rc=3
    return "$rc"
}

# ---------------------------------------------------------------- uninstall
confirm() { [[ $ASSUME_YES -eq 1 ]] && return 0; read -r -p "$1 [y/N] " a; [[ "$a" == y || "$a" == Y ]]; }

do_uninstall() {
    mkdir -p "$RUN_DIR"
    local n; n="$(oc get pipelinepolicies -A --no-headers 2>/dev/null | wc -l)"
    if [[ "$n" -gt 0 ]]; then
        oc get pipelinepolicies -A -o yaml > "$RUN_DIR/pipelinepolicies-backup.yaml"
        ok "backed up ${n} PipelinePolicy object(s) to $RUN_DIR/pipelinepolicies-backup.yaml"
    fi
    snapshot_rhcl "$RUN_DIR/rhcl-before.txt"
    # Order: workload first, then RBAC, then namespace; the CRD last and only on request
    oc -n "$EXT_NAMESPACE" delete deploy "${EXT_NAME}-extension" --ignore-not-found
    oc delete clusterrolebinding "${EXT_NAME}-manager-rolebinding" --ignore-not-found
    oc delete clusterrole "${EXT_NAME}-manager-role" --ignore-not-found
    oc delete ns "$EXT_NAMESPACE" --ignore-not-found
    if [[ $DELETE_CRD -eq 1 ]]; then
        warn "deleting CRD ${CRD_NAME} also deletes ALL PipelinePolicy objects (${n} now)"
        if [[ "$n" -gt 0 ]] && ! confirm "Delete the CRD and ${n} PipelinePolicy object(s)?"; then
            warn "CRD kept"
        else
            oc delete crd "$CRD_NAME" --ignore-not-found
        fi
    else
        log "CRD ${CRD_NAME} kept (use --delete-crd to remove it; this deletes all PipelinePolicy objects)"
    fi
    snapshot_rhcl "$RUN_DIR/rhcl-after.txt"
    compare_snapshots "$RUN_DIR/rhcl-before.txt" "$RUN_DIR/rhcl-after.txt" || exit 3
}

# ---------------------------------------------------------------- main
prereqs
case "$ACTION" in
    check)     do_check; exit $? ;;
    render)    mkdir -p "$RUN_DIR"; render; dry_run; log "nothing applied; manifests in ${RENDER_DIR}" ;;
    install)   do_install ;;
    test)      do_test; exit $? ;;
    all)       do_install; do_test; exit $? ;;
    uninstall) do_uninstall ;;
esac
