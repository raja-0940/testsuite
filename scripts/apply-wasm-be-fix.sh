#!/usr/bin/env bash
# =============================================================================
# apply-wasm-be-fix.sh
#
# Applies the ppc64le wasm-shim workaround for Kuadrant / RHCL operator on
# OpenShift.
#
# BACKGROUND
# ----------
# NOTE: ppc64le is a LITTLE-endian architecture (verified on this cluster:
# lscpu "Byte Order: Little Endian", Envoy ELF EI_DATA=01/LSB). The
# big-endian issue https://github.com/proxy-wasm/proxy-wasm-cpp-host/issues/552
# applies to big-endian hosts such as s390x, NOT to ppc64le.
# This workaround was originally added after the wasm plugin failed to start on
# an earlier (custom-built) ppc64le proxy setup; the root cause was never
# confirmed. On OCP 4.22 + OSSM 3.4.3 (official istio-proxyv2-rhel9) the
# official RHCL 1.5.0 ppc64le wasm-shim image loaded and enforced a
# RateLimitPolicy without this patch. Treat this script as a legacy, optional
# local workaround; prefer the official RHCL wasm-shim image.
#
# FIX
# ---
# Patch wasm-shim so current_log_filter() returns a hardcoded WARN default
# instead of calling the broken get_log_level host-call, rebuild the .wasm
# binary, publish it as an OCI image, then inject it into the running
# kuadrant-operator pod via an init-container so the operator's internal HTTP
# wasm server (port 8082) serves the patched binary.
#
# WHEN TO RUN
# -----------
# Run once after the RHCL/Kuadrant operator has been successfully installed
# (CSV phase = Succeeded) and before kicking off e2e / QE tests.
#
# PREREQUISITES
# -------------
#   * oc / kubectl configured for the target cluster
#   * podman logged in to quay.io (podman login quay.io)
#   * Rust toolchain with wasm32-wasip1 target
#       rustup target add wasm32-wasip1
#   * protoc >= 3.15 (auto-downloaded for ppc64le into <wasm-src>/bin if missing), unzip, curl
#   * python3
#
# USAGE
# -----
#   ./apply-wasm-be-fix.sh [OPTIONS]
#
# OPTIONS
#   --wasm-src  DIR     Path to wasm-shim git checkout.
#                       Default: /root/wasm-shim  (use a v0.15.0+ checkout for RHCL 1.5)
#   --image-tag TAG     OCI image tag for the patched wasm binary.
#                       Default: quay.io/raja0940/wasm-shim:ppc64le-be-fix
#   --injector-tag TAG  OCI image tag for the init-container injector.
#                       Default: quay.io/raja0940/wasm-shim-injector:ppc64le-be-fix
#   --op-ns  NS         Namespace where the kuadrant-operator pod runs.
#                       Default: openshift-operators
#   --skip-build        Skip Rust build; use the existing wasm binary.
#   --skip-push         Skip podman push (images already in registry).
#   --dry-run           Show what would be done without making changes.
#   -h / --help         Show this help and exit.
# =============================================================================
set -euo pipefail

# ── defaults ──────────────────────────────────────────────────────────────────
WASM_SRC="${WASM_SRC:-/root/wasm-shim}"
IMAGE_TAG="${IMAGE_TAG:-quay.io/raja0940/wasm-shim:ppc64le-be-fix}"
INJECTOR_TAG="${INJECTOR_TAG:-quay.io/raja0940/wasm-shim-injector:ppc64le-be-fix}"
OPERATOR_NS="${OPERATOR_NS:-openshift-operators}"
SKIP_BUILD=false
SKIP_PUSH=false
DRY_RUN=false

# ── colours ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'
info()    { echo -e "${CYAN}[INFO]${RESET}  $*"; }
ok()      { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
error()   { echo -e "${RED}[ERROR]${RESET} $*" >&2; }
section() { echo -e "\n${BOLD}━━━  $*  ━━━${RESET}"; }
die()     { error "$*"; exit 1; }
require_cmd() { command -v "$1" &>/dev/null || die "'$1' not found. Install it first."; }

maybe_run() {
  # Execute a command, or just print it in dry-run mode.
  if $DRY_RUN; then echo -e "${YELLOW}[DRY-RUN]${RESET} $*"; else eval "$@"; fi
}

# ── argument parsing ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --wasm-src)     WASM_SRC="$2";     shift 2 ;;
    --image-tag)    IMAGE_TAG="$2";    shift 2 ;;
    --injector-tag) INJECTOR_TAG="$2"; shift 2 ;;
    --op-ns)        OPERATOR_NS="$2";  shift 2 ;;
    --skip-build)   SKIP_BUILD=true;   shift   ;;
    --skip-push)    SKIP_PUSH=true;    shift   ;;
    --dry-run)      DRY_RUN=true;      shift   ;;
    -h|--help)
      grep "^#" "$0" | grep -v "^#!/" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
done

WASM_BIN="${WASM_SRC}/target/wasm32-wasip1/release/wasm_shim.wasm"
PATCH_FILE="${WASM_SRC}/crates/wasm-shim/src/wasm_host.rs"

# ── preflight checks ──────────────────────────────────────────────────────────
section "Preflight checks"

require_cmd kubectl
require_cmd oc
require_cmd python3
$SKIP_BUILD || require_cmd cargo
$SKIP_BUILD || require_cmd rustup
$SKIP_BUILD || require_cmd unzip
$SKIP_PUSH  || require_cmd podman

ARCH=$(uname -m)
if [[ "$ARCH" != "ppc64le" ]]; then
  warn "Current arch is '$ARCH', not ppc64le."
  warn "This workaround was only ever used on ppc64le (little-endian) clusters."
  read -rp "Continue anyway? [y/N] " _c
  [[ "${_c,,}" == "y" ]] || exit 0
fi

kubectl cluster-info &>/dev/null || die "kubectl cannot reach the cluster."
ok "Cluster reachable."

kubectl get namespace "$OPERATOR_NS" &>/dev/null \
  || die "Namespace '$OPERATOR_NS' not found. Use --op-ns to override."

OPERATOR_DEPLOY=$(kubectl get deployment -n "$OPERATOR_NS" --no-headers \
  -o custom-columns=":metadata.name" 2>/dev/null \
  | grep "kuadrant-operator-controller-manager" | head -1)
[[ -n "$OPERATOR_DEPLOY" ]] \
  || die "kuadrant-operator-controller-manager not found in $OPERATOR_NS."
ok "Operator deployment: $OPERATOR_DEPLOY"

CSV_NAME=$(oc get csv -n "$OPERATOR_NS" --no-headers 2>/dev/null \
  | awk '/rhcl-operator/{print $1}' | head -1)
[[ -n "$CSV_NAME" ]] \
  || die "No rhcl-operator CSV found in '$OPERATOR_NS'. Is the RHCL operator installed?"
CSV_PHASE=$(oc get csv -n "$OPERATOR_NS" "$CSV_NAME" \
  -o jsonpath='{.status.phase}' 2>/dev/null)
[[ "$CSV_PHASE" == "Succeeded" ]] \
  || warn "CSV phase is '$CSV_PHASE' (expected Succeeded). Proceeding anyway."
ok "CSV: $CSV_NAME  (phase: $CSV_PHASE)"

[[ -d "$WASM_SRC" ]] || die "wasm-shim directory not found: $WASM_SRC"
[[ -f "$PATCH_FILE" ]] || die "Source file not found: $PATCH_FILE"
ok "wasm-shim source: $WASM_SRC"

# ── step 1: apply source patch ────────────────────────────────────────────────
section "Step 1 — Patch wasm-shim source (skip get_log_level hostcall)"

# Idempotent: detect already-patched file by the absence of the original body
if grep -q "LevelFilter::WARN$" "$PATCH_FILE" 2>/dev/null && \
   ! grep -q "hostcalls::get_log_level()" "$PATCH_FILE" 2>/dev/null; then
  ok "Patch already applied to $PATCH_FILE — skipping."
else
  grep -q "hostcalls::get_log_level()" "$PATCH_FILE" \
    || die "Expected 'hostcalls::get_log_level()' not found in $PATCH_FILE." \
           "Ensure the wasm-shim checkout matches the version used by this RHCL build."

  info "Patching $PATCH_FILE ..."
  if $DRY_RUN; then
    warn "[DRY-RUN] Would patch $PATCH_FILE"
  else
    python3 - "$PATCH_FILE" << 'PYEOF'
import sys

path = sys.argv[1]
with open(path) as f:
    content = f.read()

OLD = (
    'pub fn current_log_filter() -> LevelFilter {\n'
    '    match hostcalls::get_log_level() {\n'
    '        Ok(LogLevel::Trace) => LevelFilter::TRACE,\n'
    '        Ok(LogLevel::Debug) => LevelFilter::DEBUG,\n'
    '        Ok(LogLevel::Info) => LevelFilter::INFO,\n'
    '        Ok(LogLevel::Warn) => LevelFilter::WARN,\n'
    '        Ok(LogLevel::Error) | Ok(LogLevel::Critical) => LevelFilter::ERROR,\n'
    '        Err(_) => LevelFilter::WARN,\n'
    '    }\n'
    '}'
)

NEW = (
    'pub fn current_log_filter() -> LevelFilter {\n'
    "    // Workaround for ppc64le (Big Endian) hosts: proxy-wasm-cpp-host's\n"
    '    // get_log_level hostcall uses setDataType which performs an incorrect\n'
    '    // endian conversion on BE hosts, causing an out-of-bounds memory fault\n'
    '    // that crashes the wasm plugin before any policy can be enforced.\n'
    '    // See: https://github.com/proxy-wasm/proxy-wasm-cpp-host/issues/552\n'
    '    // We skip the hostcall and return the safe default (WARN). The log\n'
    '    // level can still be set via pluginConfig observability.default_level.\n'
    '    LevelFilter::WARN\n'
    '}'
)

if OLD not in content:
    print("ERROR: exact patch target not found in source.", file=sys.stderr)
    sys.exit(1)

content = content.replace(OLD, NEW)
# Remove the now-unused LogLevel import
content = content.replace(
    'use proxy_wasm::types::{LogLevel, Status};',
    'use proxy_wasm::types::Status;'
)

with open(path, 'w') as f:
    f.write(content)
print("Patch written.")
PYEOF
  fi
  ok "Source patched."
fi

# ── step 2: build wasm binary ─────────────────────────────────────────────────
section "Step 2 — Build wasm binary (wasm32-wasip1 release)"

if $SKIP_BUILD; then
  [[ -f "$WASM_BIN" ]] || die "--skip-build set but binary not found: $WASM_BIN"
  ok "Using existing binary: $WASM_BIN"
else
  if $DRY_RUN; then
    warn "[DRY-RUN] Would run: cd $WASM_SRC && BUILD=release make build"
  else
    # Ensure wasm32-wasip1 Rust target is installed
    if ! rustup target list --installed 2>/dev/null | grep -q "wasm32-wasip1"; then
      info "Adding wasm32-wasip1 Rust target..."
      rustup target add wasm32-wasip1
    fi

    # wasm-shim >= v0.15 needs protoc >= 3.15 (proto3 optional). The Makefile only downloads
    # x86_64/osx protoc, and RHEL's protoc is 3.14, so put a ppc64le protoc (PROTOC_VERSION,
    # default 21.1 = Makefile pin) into ${WASM_SRC}/bin when the existing one is missing/too old/wrong arch.
    BIN_DIR="${WASM_SRC}/bin"
    PROTO_IN_BIN="${BIN_DIR}/protoc"
    PROTOC_VERSION="${PROTOC_VERSION:-21.1}"
    PROTO_OK=false
    if [[ -x "$PROTO_IN_BIN" ]] && "$PROTO_IN_BIN" --version >/dev/null 2>&1; then
      PV=$("$PROTO_IN_BIN" --version | awk '{print $2}')
      [[ "$(printf '%s\n3.15.0\n' "$PV" | sort -V | head -1)" == "3.15.0" ]] && PROTO_OK=true
    fi
    if ! $PROTO_OK && [[ "$ARCH" == "ppc64le" ]]; then
      info "Installing protoc ${PROTOC_VERSION} (linux-ppcle_64) into ${BIN_DIR}"
      TMP_PROTOC=$(mktemp -d)
      curl -sSfL -o "${TMP_PROTOC}/protoc.zip" \
        "https://github.com/protocolbuffers/protobuf/releases/download/v${PROTOC_VERSION}/protoc-${PROTOC_VERSION}-linux-ppcle_64.zip" \
        || die "Failed to download protoc ${PROTOC_VERSION} for ppc64le"
      unzip -q -o "${TMP_PROTOC}/protoc.zip" -d "$TMP_PROTOC"
      mkdir -p "$BIN_DIR" "${WASM_SRC}/include"
      rm -f "$PROTO_IN_BIN"
      cp "${TMP_PROTOC}/bin/protoc" "$PROTO_IN_BIN"
      cp -r "${TMP_PROTOC}/include/." "${WASM_SRC}/include/"
      rm -rf "$TMP_PROTOC"
    fi
    ok "protoc: $("$PROTO_IN_BIN" --version 2>/dev/null || echo missing)"

    info "Running: BUILD=release make build  (this takes ~15s on ppc64le)"
    (cd "$WASM_SRC" && BUILD=release make build 2>&1)
    [[ -f "$WASM_BIN" ]] || die "Build finished but binary not found: $WASM_BIN"
    ok "Build complete."
  fi
fi

if ! $DRY_RUN; then
  WASM_SHA256=$(sha256sum "$WASM_BIN" | awk '{print $1}')
  WASM_SIZE=$(du -sh "$WASM_BIN" | awk '{print $1}')
else
  WASM_SHA256="(computed at build time)"
  WASM_SIZE="(n/a)"
fi
info "Binary : $WASM_BIN"
info "sha256 : $WASM_SHA256   size: $WASM_SIZE"

# ── step 3: build and push OCI images ─────────────────────────────────────────
section "Step 3 — Build and push OCI images"

if $DRY_RUN; then
  warn "[DRY-RUN] Would build: $IMAGE_TAG  (FROM scratch, COPY wasm_shim.wasm /plugin.wasm)"
  warn "[DRY-RUN] Would build: $INJECTOR_TAG  (FROM ubi9-minimal + wasm binary)"
  warn "[DRY-RUN] Would push both images to registry."
else
  WASM_DIR=$(dirname "$WASM_BIN")

  # 3a. Minimal scratch image: just /plugin.wasm
  info "Building wasm OCI image: $IMAGE_TAG"
  WASM_CTF=$(mktemp /tmp/Containerfile.wasm.XXXX)
  printf 'FROM scratch\nCOPY wasm_shim.wasm /plugin.wasm\n' > "$WASM_CTF"
  podman build -f "$WASM_CTF" -t "$IMAGE_TAG" "$WASM_DIR" 2>&1
  rm -f "$WASM_CTF"
  ok "Built $IMAGE_TAG"

  # 3b. Init-container injector image: ubi9-minimal carrying the wasm binary
  info "Building injector init image: $INJECTOR_TAG"
  INJECTOR_CTF=$(mktemp /tmp/Containerfile.injector.XXXX)
  cat > "$INJECTOR_CTF" <<EOF
FROM ${IMAGE_TAG} AS wasm-source
FROM registry.access.redhat.com/ubi9/ubi-minimal:latest
COPY --from=wasm-source /plugin.wasm /wasm-patched/plugin.wasm
CMD ["/bin/sh","-c","cp /wasm-patched/plugin.wasm /wasm/plugin.wasm && echo 'ppc64le BE fix: patched wasm injected' && sha256sum /wasm/plugin.wasm"]
EOF
  podman build -f "$INJECTOR_CTF" -t "$INJECTOR_TAG" . 2>&1
  rm -f "$INJECTOR_CTF"
  ok "Built $INJECTOR_TAG"

  if ! $SKIP_PUSH; then
    info "Pushing $IMAGE_TAG ..."
    podman push "$IMAGE_TAG" 2>&1
    info "Pushing $INJECTOR_TAG ..."
    podman push "$INJECTOR_TAG" 2>&1
    ok "Images pushed to registry."
  else
    ok "Skipped registry push (--skip-push)."
  fi
fi

# ── step 4: patch the OLM CSV ─────────────────────────────────────────────────
section "Step 4 — Patch OLM CSV to inject patched wasm into operator pod"

# Always fetch the CSV (read-only) so we can inspect and patch it
CSV_JSON=$(oc get csv -n "$OPERATOR_NS" "$CSV_NAME" -o json 2>/dev/null) \
  || die "Failed to fetch CSV $CSV_NAME from $OPERATOR_NS."

# Idempotent check
if echo "$CSV_JSON" | grep -q '"inject-wasm"'; then
  ok "CSV already contains inject-wasm init container."
  info "Updating image tags in existing patch..."
fi

PATCHED_CSV=$(CSV_JSON_CONTENT="$CSV_JSON" python3 - "$INJECTOR_TAG" "$IMAGE_TAG" <<PYEOF
import json, sys

injector_tag = sys.argv[1]
wasm_tag     = sys.argv[2]

import os
csv_json = os.environ.get('CSV_JSON_CONTENT', '')
d = json.loads(csv_json)

for dep in d['spec']['install']['spec']['deployments']:
    if 'kuadrant-operator' not in dep.get('name', ''):
        continue
    spec = dep['spec']['template']['spec']

    # emptyDir volume for /wasm (idempotent)
    vols = [v for v in spec.get('volumes', []) if v.get('name') != 'wasm-patched']
    vols.append({"name": "wasm-patched", "emptyDir": {}})
    spec['volumes'] = vols

    # /wasm volumeMount on manager container (idempotent)
    for c in spec['containers']:
        if c['name'] != 'manager':
            continue
        mounts = [m for m in c.get('volumeMounts', []) if m.get('mountPath') != '/wasm']
        mounts.append({"name": "wasm-patched", "mountPath": "/wasm"})
        c['volumeMounts'] = mounts
        # Update RELATED_IMAGE_WASMSHIM env var
        for e in c.get('env', []):
            if e.get('name') == 'RELATED_IMAGE_WASMSHIM':
                e['value'] = wasm_tag

    # inject-wasm init container (idempotent)
    init = [ic for ic in spec.get('initContainers', []) if ic.get('name') != 'inject-wasm']
    init.append({
        "name": "inject-wasm",
        "image": injector_tag,
        "command": [
            "/bin/sh", "-c",
            "cp /wasm-patched/plugin.wasm /wasm/plugin.wasm && "
            "echo 'ppc64le BE fix: patched wasm injected' && "
            "sha256sum /wasm/plugin.wasm"
        ],
        "volumeMounts": [{"name": "wasm-patched", "mountPath": "/wasm"}]
    })
    spec['initContainers'] = init

print(json.dumps(d))
PYEOF
)

if $DRY_RUN; then
  warn "[DRY-RUN] Would apply patched CSV $CSV_NAME to $OPERATOR_NS."
  info "CSV patch adds: inject-wasm init container + wasm-patched emptyDir volume."
else
  echo "$PATCHED_CSV" | oc apply -f - -n "$OPERATOR_NS" \
    || die "Failed to apply patched CSV."
  ok "CSV patched and applied."
fi

# ── step 5: wait for operator pod rollout ─────────────────────────────────────
section "Step 5 — Wait for operator rollout and verify injection"

if $DRY_RUN; then
  warn "[DRY-RUN] Would wait for rollout of $OPERATOR_DEPLOY in $OPERATOR_NS."
  warn "[DRY-RUN] Would verify sha256 of /wasm/plugin.wasm in operator pod."
else
  info "Waiting for rollout (timeout: 180s)..."
  kubectl rollout status deployment/"$OPERATOR_DEPLOY" -n "$OPERATOR_NS" \
    --timeout=180s || die "Rollout did not complete in time."

  # Locate the new running operator pod
  NEW_POD=$(kubectl get pods -n "$OPERATOR_NS" --no-headers \
    -l "control-plane=controller-manager" 2>/dev/null \
    | grep -v Terminating | awk '{print $1}' | head -1)
  if [[ -z "$NEW_POD" ]]; then
    NEW_POD=$(kubectl get pods -n "$OPERATOR_NS" --no-headers 2>/dev/null \
      | grep "$OPERATOR_DEPLOY" | grep -v Terminating | awk '{print $1}' | head -1)
  fi
  [[ -n "$NEW_POD" ]] || die "Could not find the running operator pod after rollout."

  info "Init-container log from $NEW_POD :"
  kubectl logs -n "$OPERATOR_NS" "$NEW_POD" -c inject-wasm 2>/dev/null || true
  echo ""

  SERVED_SHA=$(kubectl exec -n "$OPERATOR_NS" "$NEW_POD" -- \
    sha256sum /wasm/plugin.wasm 2>/dev/null | awk '{print $1}')

  if [[ "$SERVED_SHA" == "$WASM_SHA256" ]]; then
    ok "Operator is serving the patched binary  (sha256: $SERVED_SHA)."
  else
    error "SHA256 mismatch!"
    error "  Expected : $WASM_SHA256"
    error "  Served   : $SERVED_SHA"
    die "Check: kubectl logs -n $OPERATOR_NS $NEW_POD -c inject-wasm"
  fi
fi

# ── summary ───────────────────────────────────────────────────────────────────
section "Done ✓"
echo ""
echo -e "  Patched source : ${BOLD}${PATCH_FILE}${RESET}"
echo -e "  Built binary   : ${BOLD}${WASM_BIN}${RESET}"
echo -e "  sha256         : ${BOLD}${WASM_SHA256}${RESET}"
echo -e "  OCI image      : ${BOLD}${IMAGE_TAG}${RESET}"
echo -e "  Injector image : ${BOLD}${INJECTOR_TAG}${RESET}"
echo -e "  CSV patched    : ${BOLD}${CSV_NAME}${RESET}  (namespace: ${OPERATOR_NS})"
echo ""
echo -e "${GREEN}The kuadrant-operator is now serving the ppc64le-compatible wasm binary."
echo -e "You can proceed with e2e / QE test runs.${RESET}"
