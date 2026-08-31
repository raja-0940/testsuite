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
