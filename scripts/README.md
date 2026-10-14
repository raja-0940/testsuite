# Kuadrant E2E Automation for IBM Power (ppc64le)

This directory contains the automation tooling and modular helper scripts for preparing an OpenShift `ppc64le` cluster with Red Hat Connectivity Link (RHCL / Kuadrant 1.5) and executing the complete or targeted Kuadrant E2E test suite.

All operations can be driven through the master entry point script: **`scripts/automate-kuadrant-e2e.sh`**.

---

## 1. Quick Start & Shortest Verified Commands

Run all commands from the repository root (`/root/test/testsuite`) on the bastion host.

### Check Prerequisites (Non-Mutating)
Inspects bastion tools, cluster health, operators, Kuadrant CR, Authorino/Limitador, mock tools endpoints, DNS delegation, and local configuration without applying changes:
```bash
./scripts/automate-kuadrant-e2e.sh --check
```

### Full Setup & Test Execution (One Command)
Validates preflight, applies all missing prerequisites in dependency order, refreshes local tokens, starts the background DNS helper daemon, and launches the full Kuadrant E2E suite in a dedicated tmux session:
```bash
./scripts/automate-kuadrant-e2e.sh --test
```

### Setup Prerequisites Only (Idempotent)
Prepares all cluster namespaces, Vault kubernetes auth, Authorino trust bundles, operator OTEL tracing, Kuadrant dataPlane observability, Istio telemetry, and CoreDNS NodePort without running pytest:
```bash
./scripts/automate-kuadrant-e2e.sh --setup
```

### Run Selected Tests or Groups
Runs specific test modules or test files through the automated pipeline in tmux:
```bash
# Run Authorino basic tests
./scripts/automate-kuadrant-e2e.sh --test testsuite/tests/singlecluster/authorino/test_basic.py

# Run DNSPolicy suite
./scripts/automate-kuadrant-e2e.sh --test testsuite/tests/singlecluster/gateway/dnspolicy

# Run Limitador suite
./scripts/automate-kuadrant-e2e.sh --test testsuite/tests/singlecluster/limitador
```

### PipelinePolicy Extension: Install and Test
`PipelinePolicy` tests are skipped ("PipelinePolicy CRD is not installed on the cluster") until the CRD **and** the standalone `pipeline-policy` extension controller are installed. `pipeline-policy-e2e.sh` installs only those from the `Kuadrant/helm-charts-olm` chart (details in section 8) without touching the installed RHCL operator, then runs the tests:
```bash
./scripts/pipeline-policy-e2e.sh --check      # read-only: CRD, extension pod, operator handshake
./scripts/pipeline-policy-e2e.sh --render     # render + server dry-run only, applies nothing
./scripts/pipeline-policy-e2e.sh --all        # install the extension, then run pipeline_policy/ tests
```

### Inspect Active Execution & Logs
```bash
# Check status of tmux sessions, pytest processes, DNS helper daemon, and latest results
./scripts/automate-kuadrant-e2e.sh --status

# Attach to the live tmux test console (detach with Ctrl-b d)
tmux attach -t kuadrant-power-full-e2e

# Stream live pytest logs from the latest run
tail -n 100 -f $(cat /root/test/results/LATEST_FULL_RUN.txt 2>/dev/null || ls -td /root/test/results/full-e2e-* | head -1)/full-e2e.log
```

### Scoped Cleanup
Stops helper daemons and deletes leftover test objects (Gateways, HTTPRoutes, Policies, Secrets, Services, Deployments created by the test user) without affecting persistent operators, cluster issuers, or tools:
```bash
./scripts/automate-kuadrant-e2e.sh --clean
```

---

## 2. Scripts Reference

| Script | Purpose |
|---|---|
| **`automate-kuadrant-e2e.sh`** | **Master automation entry point.** Provides `--check`, `--setup`, `--test`, `--status`, `--clean`, `--no-tmux`, `--with-wasm-workaround`, and `--results-dir`. Coordinates all sub-scripts in strict dependency order. |
| `kuadrant-pre-e2e.sh` | Validates tools/cluster, creates namespaces, provisions `coredns-credentials`, refreshes OCP token in `config/settings.local.yaml`, performs synthetic DNS checks, starts `sync-kuadrant-dns-etcd.sh`, and writes the environment file (`/tmp/kuadrant-ppc64le-e2e-env.sh`). |
| `run-full-e2e-power.sh` | Wrapper around `run-kuadrant-e2e.sh` executing preflight checks, timestamped logging outside the repo (`/root/test/results/full-e2e-<ts>/`), environment capture, JUnit XML, HTML reports, and post-test `summary.txt` / `failures.txt` extraction. |
| `run-kuadrant-e2e.sh` | Standard Pytest runner using Poetry with established Power flags (`-n0`, `--reruns 3`, `--reruns-delay 2`, `--verify-denials=true`, `--enforce`, `-m "not standalone_only and not disruptive and not ui"`). |
| `setup-egress-vault-authorino.sh` | Sets up Vault ServiceAccount `vault`, ClusterRoleBinding `kuadrant-vault-auth-delegator`, writes `auth/kubernetes/config`, creates `authorino-cluster-trust-ca-bundle` ConfigMap in `kuadrant-system`, and mounts it into Authorino CR. |
| `setup-operator-tracing.sh` | Patches RHCL Subscription with `OTEL_EXPORTER_OTLP_ENDPOINT` pointing to `rpc://jaeger-collector.tools.svc.cluster.local:4317` and restarts operator controller manager. |
| `setup-dataplane-observability.sh` | Patches Kuadrant CR `kuadrant` with `spec.observability.dataPlane.httpHeaderIdentifier: x-request-id` and tracing configuration. |
| `setup-kuadrant-coredns.sh` | Deploys CoreDNS with Kuadrant DNSRecord plugin in `kuadrant-coredns` namespace with NodePort `30554` (for DNSPolicy test resolution). |
| `sync-kuadrant-dns-etcd.sh` | Background daemon polling HTTPRoutes and synchronizing hostnames to SkyDNS etcd keys for bastion resolution of `*.kuadrant.internal`. |
| **`pipeline-policy-e2e.sh`** | Installs the standalone PipelinePolicy extension (Namespace, CRD, RBAC, Deployment rendered with `helm template` from `Kuadrant/helm-charts-olm`, pinned revision and image digest), waits for the operator handshake, and runs `extensions/pipeline_policy/`. Verifies the RHCL CSV, Subscriptions and operator Deployment are unchanged. Modes: `--check`, `--render`, `--install`, `--test`, `--all`, `--uninstall`. See section 8. |
| `apply-wasm-be-fix.sh` | Optional/legacy workaround: rebuilds/injects patched wasm-shim without log-level hostcall. (Standard setup uses official binary). |

---

## 3. Prerequisite Inventory & Dependency Classification

### Mandatory Prerequisites (Automated or Validated)
1. **Cluster & Architecture**: OpenShift 4.22+ on `ppc64le` with all Master and Worker nodes in `Ready` state.
2. **Cluster Permissions**: Logged in as `cluster-admin` (e.g. `kube:admin`).
3. **Required Operators (CSV Succeeded)**:
   - Red Hat Connectivity Link: `rhcl-operator.v1.5.0` (namespace `openshift-operators`)
   - OpenShift Service Mesh 3: `servicemeshoperator3.v3.4.3` (Sail Operator)
   - cert-manager: `cert-manager-operator.v1.20.1` (ClusterIssuer `kuadrant-qe-issuer`)
   - MetalLB: `metallb-operator` with `IPAddressPool` named `gateway-pool` allocating IPs for Gateways.
4. **Core Kuadrant Components**:
   - Kuadrant CR `kuadrant` in namespace `kuadrant-system` (Condition `Ready=True`).
   - Authorino deployment ready in `kuadrant-system`.
   - Limitador deployment ready in `kuadrant-system`.
   - GatewayClass `istio` accepted and ready.
5. **Namespaces**: `tools`, `kuadrant`, `kuadrant2`, `kuadrant-coredns`.
6. **Tools Deployments & Routes (in `tools` namespace)**:
   - `etcd` (ClusterIP `172.30.217.225:2379`)
   - `coredns` (NodePort `30553`, SkyDNS backend for `*.kuadrant.internal`)
   - `keycloak` (Route `http://keycloak-tools.apps.<domain>`)
   - `mockserver` (Route `http://mockserver-tools.apps.<domain>`)
   - `jaeger` (Query route `http://jaeger-query-tools.apps.<domain>`, OTLP gRPC `jaeger-collector.tools.svc.cluster.local:4317`)
   - `vault` (Route `http://vault-tools.apps.<domain>`, dev mode with root token)
7. **Secrets & Integration RBAC**:
   - `coredns-credentials` Secret in namespaces `kuadrant` and `kuadrant2`.
   - Vault `kuadrant-vault-auth-delegator` ClusterRoleBinding for token reviews.
   - Authorino `cluster-trust-bundle` ConfigMap containing cluster Ingress CA.
8. **DNS Resolution Pipeline**:
   - `kuadrant-coredns` deployed on NodePort `30554` (resolving DNSRecord CRs).
   - `sync-kuadrant-dns-etcd.sh` background daemon active.

### Optional Prerequisites & Additional Coverage
- **Thanos Querier Token**: Needed for metrics observability tests (`testsuite/tests/singlecluster/observability`). Refreshed automatically from `oc whoami -t`.
- **UI Console Plugin**: Required only for UI tests (which are ignored in default CLI E2E runs).

### Temporary Workarounds & Product Adaptations
- **Wasm Shim Binary**: ppc64le is little-endian; standard RHCL 1.5.0 binary works without modifications. Optional custom builds can be enabled with `--with-wasm-workaround`.
- **Egress Authorino CA Bundle**: Ingress CA bundle mounted into Authorino container to validate self-signed certificates when calling internal routes.
- **Velocity MockServer Templates**: Velocity templates used for MockServer responses where JavaScript (Nashorn) engine is unavailable on ppc64le JVM builds.

---

## 4. Configuration & Secure Credential Handling

Configuration is managed via `config/settings.local.yaml`.
- The automation secures permissions on this file (`chmod 0600`) to prevent unauthorized access.
- Sensitive credentials (Vault root token, Keycloak passwords, OCP bearer tokens) are stored only in this ignored file or existing Kubernetes Secrets.
- Pre-E2E setup automatically refreshes `control_plane.cluster.token` by querying `oc whoami --show-token` without printing or logging secrets.

Sample snippet of `config/settings.local.yaml`:
```yaml
default:
  cfssl: /usr/local/bin/cfssl
  default_exposer: openshift
  prometheus:
    url: https://thanos-querier-openshift-monitoring.apps.<cluster-domain>
    project: openshift-monitoring
    service: thanos-querier
  service_protection:
    system_project: kuadrant-system
    operator_project: openshift-operators
    project: kuadrant
    project2: kuadrant2
  control_plane:
    cluster:
      kubeconfig_path: /root/.kube/config
      token: "<refreshed-automatically>"
    slow_loadbalancers: true
    provider_secret: coredns-credentials
    issuer:
      name: kuadrant-qe-issuer
      kind: ClusterIssuer
  dns:
    coredns_zone: kuadrant.internal
    dns_server:
      geo_code: DE
      address: 172.30.250.50
  tools:
    project: tools
  keycloak:
    url: http://keycloak-tools.apps.<cluster-domain>
    username: admin
    password: <keycloak-password>
```

---

## 5. CLI Options for `automate-kuadrant-e2e.sh`

```
Usage:
  ./scripts/automate-kuadrant-e2e.sh [MODE] [OPTIONS] [PYTEST_TARGETS...]

Modes (one required):
  -c, --check                 Run non-mutating diagnostic checks on all prerequisites.
  -s, --setup                 Apply and reconcile all prerequisites in dependency order.
  -t, --test [TARGETS...]     Run setup + execute E2E test suite (full or selected paths).
      --status                Show active tmux sessions, pytest processes, and latest runs.
      --clean                 Run scoped cleanup of test gateways, routes, and daemons.
  -h, --help                  Show help text and exit.

Options:
      --no-tmux               Run E2E directly in foreground instead of a tmux session.
      --with-wasm-workaround  Apply custom/patched wasm-shim binary (opt-in workaround).
      --kubeconfig <path>     Explicit path to kubeconfig (default: $KUBECONFIG or ~/.kube/config).
      --results-dir <dir>     Parent directory for test output (default: /root/test/results).
```

---

## 6. Execution Lifecycle, Output Artifacts, and Monitoring

When executed in test mode (`--test`), the automation creates a timestamped results directory outside the source tree at `/root/test/results/full-e2e-<YYYYMMDD-HHMMSS>/`.

### Artifacts Generated:
- `full-e2e.log` / `group-e2e-<ts>.log`: Complete live unbuffered execution log.
- `junit-full-e2e.xml`: Standard JUnit test report for CI/CD integration.
- `report-full-e2e.html`: Self-contained interactive HTML test report.
- `environment.txt`: Snapshot of cluster version, nodes, CSV versions, wasm sha, and preflight status.
- `exit-code.txt`: Exit code of the pytest execution.
- `summary.txt`: Parsed pass/fail/error/skip/rerun breakdown and duration summary.
- `failures.txt`: Extracted test IDs and truncated failure messages for failed test cases.

### Monitoring Commands:
```bash
# Attach to tmux session:
tmux attach -t kuadrant-power-full-e2e

# View live log output:
tail -n 100 -f /root/test/results/full-e2e-<ts>/full-e2e.log

# Check run summary upon completion:
cat /root/test/results/full-e2e-<ts>/summary.txt
```

---

## 7. Troubleshooting & Rollback

### Common Scenarios & Resolutions

1. **Another Pytest Process Detected**:
   - Check with `./scripts/automate-kuadrant-e2e.sh --status`.
   - Terminate hanging or stale pytest jobs: `pkill -f pytest`.

2. **Expired OCP Token in `settings.local.yaml`**:
   - `kube:admin` tokens expire after 24 hours.
   - Run `./scripts/automate-kuadrant-e2e.sh --setup` or `kuadrant-pre-e2e.sh` to refresh the token from `oc whoami -t`.

3. **MetalLB IP Address Pool Exhaustion**:
   - Interrupted test runs may leave behind Gateway LoadBalancer services.
   - Run `./scripts/automate-kuadrant-e2e.sh --clean` to remove orphaned test resources and free IP addresses.

4. **Rollback Authorino / Istio Tracing Changes**:
   - Revert Authorino trust bundle: `oc patch authorino -n kuadrant-system authorino --type json -p '[{"op":"remove","path":"/spec/volumes"}]'`.
   - Revert Istio tracing: `oc delete telemetry -n istio-system default-telemetry` and remove `spec.values.meshConfig.enableTracing` from `Istio/default`.
   - Revert Kuadrant dataPlane observability: `./scripts/setup-dataplane-observability.sh --revert`.

---

## 8. PipelinePolicy Extension (`pipeline-policy-e2e.sh`)

### 8.1 Why a separate script
The 56 tests under `testsuite/tests/singlecluster/extensions/pipeline_policy/` need more than the CRD:
- the `PipelinePolicy` CRD (`extensions.kuadrant.io/v1alpha1`, `pipelinepolicies.extensions.kuadrant.io`);
- the standalone `pipeline-policy` extension pod, which registers with the operator over gRPC (`kuadrant-operator-extensions` Service, port 50052) and sets the `Accepted` / `Enforced` conditions that the tests wait for;
- for `grpc/` tests, a ThreatAssessment gRPC service image that has a ppc64le build (`default.pipeline_policy_extension_service.image` in `config/settings.local.yaml`).

With only the CRD applied the tests stop skipping and **fail** (no `Enforced=True`), so the script installs the CRD, RBAC and extension together and refuses to run tests until the extension has been accepted by the operator.

### 8.2 What the script does (and does not do)
- Clones/updates `https://github.com/Kuadrant/helm-charts-olm` into `/root/scratch/helm-charts-olm` and checks out the pinned revision `55df600e7febb9b011518513894cf6447866e733` (override with `HELM_REPO_REF`).
- Runs `helm template` for **only** `templates/extensions/01-namespace`, `02-crd`, `03-rbac`, `04-deployment`, using `example-extensionCRD.yaml` as the Helm **values** file (it is not a CRD manifest). The operator address is rendered as `kuadrant-operator-extensions.<operator-namespace>.svc:50052`; the namespace is auto-detected (`openshift-operators` for RHCL).
- Refuses to continue if the rendered output contains `Subscription`, `OperatorGroup`, `CatalogSource`, `ClusterServiceVersion`, `Kuadrant`, `Istio`, `IstioCNI`, `ClusterIssuer` or `NetworkPolicy`.
- Validates with `oc apply --dry-run=server --validate=strict`, then applies in order: Namespace, CRD (an existing CRD is left alone unless `--force-crd`), RBAC, Deployment.
- Waits for rollout and for `handshake accepted ... policyKind: PipelinePolicy` in the extension log and, when available, the operator log.
- Snapshots the CSV, Subscriptions, operator Deployment/pod and Kuadrant CR before and after the install and after the tests. If any of them changes the script exits with code 3.
- It does **not** run `install.sh` / `install.sh -t` from the Helm repo. That script also creates Subscriptions, OperatorGroups, a CatalogSource, a second `Kuadrant` CR, Istio and the RHBK tools, and it expects `additionalManifests.yaml`. `-t` means "testsuite tools", not "test".

### 8.3 Usage
Run from the repository root. Run `./scripts/kuadrant-pre-e2e.sh` (or `automate-kuadrant-e2e.sh --setup`) first so the environment file `/tmp/kuadrant-ppc64le-e2e-env.sh` exists, or pass `--pre`.

| Command | Effect |
|---|---|
| `./scripts/pipeline-policy-e2e.sh --check` | Read-only. Exit 0 only when CRD, extension Deployment and handshake are all present. |
| `./scripts/pipeline-policy-e2e.sh --render` | Fetch chart, render, dry-run. Nothing is applied. Output in `<results-dir>/rendered/`. |
| `./scripts/pipeline-policy-e2e.sh --install` | Idempotent install of the extension, as described above. |
| `./scripts/pipeline-policy-e2e.sh --test` | Runs the whole `pipeline_policy/` directory through `run-kuadrant-e2e.sh`. Requires the extension to be ready. |
| `./scripts/pipeline-policy-e2e.sh --test -- <paths/ids>` | Runs only the given pytest paths or ids. |
| `./scripts/pipeline-policy-e2e.sh --all` | `--install` followed by `--test`. |
| `./scripts/pipeline-policy-e2e.sh --uninstall` | Removes Deployment, ClusterRoleBinding, ClusterRole, and the namespace. The CRD is kept. |
| `./scripts/pipeline-policy-e2e.sh --uninstall --delete-crd [--yes]` | Also deletes the CRD. This **deletes every PipelinePolicy object**; they are backed up to `pipelinepolicies-backup.yaml` first and a confirmation is required unless `--yes`. |

Examples:
```bash
# Long run: use tmux (SSH sessions time out)
tmux new -d -s pipeline-policy "cd /root/test/testsuite && ./scripts/pipeline-policy-e2e.sh --all; exec bash"

# Only the gRPC tests
./scripts/pipeline-policy-e2e.sh --test -- testsuite/tests/singlecluster/extensions/pipeline_policy/grpc/
```

### 8.4 Configuration
| Variable | Default | Purpose |
|---|---|---|
| `HELM_REPO_URL` / `HELM_REPO_REF` / `HELM_REPO_DIR` | upstream URL / `55df600e...` / `/root/scratch/helm-charts-olm` | Chart source and pinned revision. |
| `EXTENSION_CRD_FILE` | `<repo>/example-extensionCRD.yaml` | Helm values file with the `extensionCRD:` list. The upstream CRD in `Kuadrant/internal-extensions` additionally has the `store` action fields. |
| `EXT_IMAGE` | `quay.io/kuadrant/internal-extensions@sha256:a80b7b6f73fe...` | Extension image, pinned to the multi-arch index that includes ppc64le. The `v1.0.x` tags are amd64-only and `latest` is mutable. |
| `EXT_NAMESPACE` | `kuadrant-extensions` | Namespace of the extension. |
| `OPERATOR_NAMESPACE` | auto-detected | Namespace of the Service `kuadrant-operator-extensions`. |
| `RESULTS_ROOT` | `/root/test/results` | Parent of `pipelinepolicy-<timestamp>/`. |
| `ENV_FILE` | `/tmp/kuadrant-ppc64le-e2e-env.sh` | Environment file written by `kuadrant-pre-e2e.sh`. |
| `HANDSHAKE_TIMEOUT` | `180` | Seconds to wait for rollout and handshake. |

The ThreatAssessment image for `grpc/` tests is read by the testsuite from `config/settings.local.yaml`:
```yaml
default:
  pipeline_policy_extension_service:
    image: quay.io/raja-0940/threat-assessment-service:latest   # ppc64le build; the upstream quay.io/kuadrant image is amd64/arm64 only
```

### 8.5 Output artifacts
In `<results-dir>` (default `/root/test/results/pipelinepolicy-<ts>/`): `rendered/` manifests, `rhcl-before.txt` / `rhcl-after.txt` / `rhcl-after-tests.txt` snapshots, `pipeline-policy-e2e.log`, `junit-pipeline-policy.xml`, `report-pipeline-policy.html`, `pipeline-policy.console`, `summary.txt`, `exit-code.txt`.

### 8.6 Exit codes
`0` success, `1` error or test failures, `2` prerequisite failed (tools, login, CSV, Kuadrant not Ready, extension not ready, env file missing, pytest already running), `3` an existing RHCL object changed.

### 8.7 Limits and notes
- Verified on OpenShift 4.22.8 / ppc64le with `rhcl-operator.v1.5.0` (QE catalog `rhcl-1.5.0-v4.22-rc3`, a pre-release build with a patched wasm-shim). Support for standalone extensions with this downstream build is not confirmed by Red Hat; treat it as experimental.
- Skips that remain regardless of this script: Auth0 (5), Gateway API CRDs older than v1.5.0 (4), letsencrypt issuer (1).
- `--test` only runs `pipeline_policy/`. Re-run the regression groups (`authorino`, `limitador`, `gateway`, `tracing`, `observability`, `reconciliation`) or `run-full-e2e-power.sh` after installing the extension.
- Rollback: `--uninstall`. Delete the CRD only when no PipelinePolicy objects are needed.
