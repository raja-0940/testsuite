# VAP Workaround Automation for Kuadrant ppc64le Smoke Tests

## 1. Overview

### Purpose

`scripts/vap_workaround.sh` automates prerequisite validation, CoreDNS
NodePort discovery, exact-host DNS helper management, smoke-test collection,
serial smoke-test execution, result parsing, diagnostics, and safe cleanup
for the validated Kuadrant ppc64le smoke workflow.

### Problem Description

On the validated ppc64le environment, the Kuadrant-managed WASM rate-limit
filter cannot be used for the selected smoke tests. The existing test fixture
uses a temporary `ValidatingAdmissionPolicy` to block the incompatible
managed WASM EnvoyFilter and creates a native Envoy rate-limit filter.

The Gateway DNS/TLS test also requires exact hostnames under
`kuadrant.internal` to resolve to dynamically assigned Gateway addresses.
The existing DNS synchronization helper maps eligible HTTPRoutes to their
parent Gateways and writes exact SkyDNS records to etcd.

### Expected Outcome

The default workflow executes these tests serially and in this order:

1. Route-targeted RateLimitPolicy
2. Gateway-targeted RateLimitPolicy
3. Authorino API-key authentication
4. Gateway readiness
5. Gateway DNS/TLS

The validated result is:

```text
5 passed, 1 warning in 472.85s (0:07:52)
```

## 2. Prerequisites

### Supported Environment

The workflow was validated with:

```text
Operating system: Linux
Architecture: ppc64le
OpenShift: 4.22
RHCL: 1.5.0
Repository: /root/testsuite
```

The script reports a warning if it runs on an architecture other than
`ppc64le`.

### Required Tools

The script validates the following commands:

```text
bash
date
git
grep
jq
oc
pgrep
poetry
python3
tee
timeout
```

Optional tools:

```text
shellcheck
dig
rndc
```

### Cluster Access and Permissions

The current `oc` session must have permission to:

- List cluster nodes.
- Read Kuadrant resources.
- Read GatewayClass resources.
- Inspect Authorino and Limitador Pods.
- Inspect Services and EndpointSlices in the `tools` namespace.
- Create and delete temporary resources required by the existing pytest
  fixtures.
- Create and delete the temporary VAP resources used by the RLP fixture.

The script does not print:

- Kubeconfig contents.
- OpenShift bearer tokens.
- Passwords.
- Pull secrets.
- Private keys.
- The complete `config/settings.local.yaml`.

### Required Repository Files

The following existing files are read-only prerequisites:

```text
config/settings.local.yaml
testsuite/kubernetes/envoy_filter.py
testsuite/tests/singlecluster/limitador/conftest.py
block-kuadrant-wasm-envoyfilters.yaml
scripts/sync-kuadrant-dns-etcd.sh
```

The automation validates but does not modify these files.

### Required Environment Variables

The script exports these variables before starting pytest:

```text
KUADRANT_COREDNS_ZONE
KUADRANT_COREDNS_DNS_HOST
KUADRANT_COREDNS_DNS_PORT
```

It sets this variable only for smoke-test execution:

```text
PPC64LE_NATIVE_RLP_WORKAROUND=true
```

## 3. Existing Workflow

### Original Manual Workflow

The validated manual runbook performs these operations:

1. Validate repository prerequisites.
2. Validate cluster access and node readiness.
3. Validate Kuadrant, Authorino, Limitador, and GatewayClass.
4. Validate the native ppc64le RLP workaround.
5. Validate the read-only VAP manifest.
6. Discover the CoreDNS NodePort.
7. Discover a node InternalIP reachable from the bastion.
8. Configure the pytest DNS resolver through environment variables.
9. Start the exact-host DNS synchronization helper.
10. Collect the exact pytest node IDs.
11. Run the two RLP tests first.
12. Run Authorino, Gateway readiness, and Gateway DNS/TLS.
13. Capture pytest logs and JUnit results.
14. Parse the test summary.
15. Stop only the DNS helper started by the current workflow.
16. Preserve diagnostic logs and reproduction commands.

### Known Limitations

- The workflow requires the existing native RLP workaround code.
- The VAP manifest is a read-only prerequisite and is not generated.
- The script does not modify `config/settings.local.yaml`.
- An externally running DNS helper is preserved and is not stopped.
- Dry-run does not execute tests or validate real DNS responses.
- The workflow expects an accepted `istio` GatewayClass.
- A node InternalIP must be reachable from the bastion on the discovered
  CoreDNS NodePort.
- The workflow does not install missing operating-system packages.

## 4. Automated Workflow

### Script Location

```text
scripts/vap_workaround.sh
```

### Script Execution Sequence

The script performs these steps:

1. Parse command-line arguments.
2. Create the output directory.
3. Validate required commands.
4. Discover the repository from the script location.
5. Validate existing workaround files without modifying them.
6. Validate cluster prerequisites unless dry-run is active.
7. Discover the CoreDNS NodePort.
8. Discover a reachable node InternalIP unless explicitly supplied.
9. Export the CoreDNS resolver environment variables.
10. Detect and preserve an externally running DNS helper.
11. Start and track a DNS helper only when one is not already running.
12. Collect the selected pytest node IDs.
13. Generate reproduction commands.
14. Run selected tests serially with `-n0`.
15. Parse the generated JUnit XML.
16. Report passed, failed, error, and skipped counts.
17. Classify failures.
18. Save execution logs and diagnostics.
19. Stop only the helper started by the current invocation.

### Cleanup Safety

The script does not delete pre-existing VAP resources or EnvoyFilters.

Temporary VAP resources are managed by the existing pytest fixture. Script
cleanup is limited to the DNS helper process started by the current script
invocation.

The script never stops a DNS helper that was already running before the
script started.

## 5. Execution Commands

### Make the Script Executable

```bash
chmod 0755 scripts/vap_workaround.sh
```

### Display Help

```bash
scripts/vap_workaround.sh --help
```

### Perform a Dry Run

```bash
scripts/vap_workaround.sh \
  --dry-run \
  --verbose \
  --output-dir /tmp/vap-workaround-dry-run
```

Dry-run does not:

- Create or delete cluster resources.
- Apply or remove VAP resources.
- Run pytest.
- Start or stop the DNS helper.
- Change Git branches.
- Modify repository files.
- Modify `config/settings.local.yaml`.

### Execute the Complete Workflow

```bash
scripts/vap_workaround.sh
```

### Use a Custom Output Directory

```bash
scripts/vap_workaround.sh \
  --output-dir /tmp/kuadrant-vap-smoke
```

### Enable Verbose Logging

```bash
scripts/vap_workaround.sh \
  --verbose
```

### Use an Explicit CoreDNS Endpoint

```bash
scripts/vap_workaround.sh \
  --coredns-host 10.20.182.54 \
  --coredns-port 30553
```

### Use Explicit Helper and Manifest Paths

```bash
scripts/vap_workaround.sh \
  --dns-helper /root/testsuite/scripts/sync-kuadrant-dns-etcd.sh \
  --manifest /root/testsuite/block-kuadrant-wasm-envoyfilters.yaml
```

### Keep a Script-Owned Helper Running

```bash
scripts/vap_workaround.sh \
  --keep-helper
```

This option applies only when the current invocation starts the DNS helper.
An externally owned helper is always preserved.

### Execute One Test

Supported test selections:

```text
all
route-rlp
gateway-rlp
authorino
gateway-readiness
gateway-dns-tls
```

Examples:

```bash
scripts/vap_workaround.sh \
  --test route-rlp \
  --verbose
```

```bash
scripts/vap_workaround.sh \
  --test gateway-dns-tls \
  --verbose
```

## 6. Smoke-Test Details

### Route-Targeted Rate Limiting

Test node ID:

```text
testsuite/tests/singlecluster/limitador/test_basic_limit.py::test_limit[2 requests every 15 sec-route]
```

Purpose:

Validates a RateLimitPolicy targeting an HTTPRoute.

Prerequisites:

- Limitador is ready.
- Istio GatewayClass is accepted.
- The VAP manifest exists.
- The native RLP workaround exists.
- `PPC64LE_NATIVE_RLP_WORKAROUND=true` is set during execution.

Exact execution command:

```bash
PPC64LE_NATIVE_RLP_WORKAROUND=true \
poetry run pytest \
  --tb=long \
  -p no:rerunfailures \
  --log-cli-level=INFO \
  -n0 \
  -v \
  -s \
  "testsuite/tests/singlecluster/limitador/test_basic_limit.py::test_limit[2 requests every 15 sec-route]"
```

Expected result:

```text
Warm-up: 200
Request 1: 200
Request 2: 200
Request 3: 429
PASSED
```

Relevant logs:

```text
execution.log
pytest.log
junit.xml
summary.txt
failures.txt
```

Troubleshooting:

- Verify that the fixture detects `PPC64LE_NATIVE_RLP_WORKAROUND`.
- Verify that the VAP manifest is present.
- Verify that the native EnvoyFilter is created.
- Inspect `failures.txt`.
- Use the exact command in `reproduction-commands.txt`.

### Gateway-Targeted Rate Limiting

Test node ID:

```text
testsuite/tests/singlecluster/limitador/test_basic_limit.py::test_limit[2 requests every 15 sec-gateway]
```

Purpose:

Validates a RateLimitPolicy targeting a Gateway.

Prerequisites:

- Limitador is ready.
- The Gateway becomes programmed.
- The HTTPRoute is accepted.
- The temporary VAP is active during setup.
- The native RLP workaround filter is created.

Exact execution command:

```bash
PPC64LE_NATIVE_RLP_WORKAROUND=true \
poetry run pytest \
  --tb=long \
  -p no:rerunfailures \
  --log-cli-level=INFO \
  -n0 \
  -v \
  -s \
  "testsuite/tests/singlecluster/limitador/test_basic_limit.py::test_limit[2 requests every 15 sec-gateway]"
```

Expected result:

```text
Warm-up: 200
Request 1: 200
Request 2: 200
Request 3: 429
PASSED
```

Troubleshooting:

- Confirm the Gateway is `Programmed=True`.
- Confirm the HTTPRoute is accepted.
- Confirm the native RLP filter targets the correct Gateway.
- Inspect `pytest.log`.
- Inspect `failures.txt`.

### Authorino API-Key Authentication

Test node ID:

```text
testsuite/tests/singlecluster/authorino/identity/api_key/test_auth_credentials.py::test_custom_selector[authorizationHeader]
```

Purpose:

Validates Authorino API-key extraction from the authorization header.

Prerequisites:

- Authorino Pod is running and ready.
- Gateway and HTTPRoute are programmed.
- AuthPolicy is accepted and enforced.

Exact execution command:

```bash
PPC64LE_NATIVE_RLP_WORKAROUND=true \
poetry run pytest \
  --tb=long \
  -p no:rerunfailures \
  --log-cli-level=INFO \
  -n0 \
  -v \
  -s \
  "testsuite/tests/singlecluster/authorino/identity/api_key/test_auth_credentials.py::test_custom_selector[authorizationHeader]"
```

Expected result:

```text
HTTP request: 200 OK
PASSED
```

Troubleshooting:

- Verify the Authorino Pod is ready.
- Inspect AuthPolicy status.
- Inspect Gateway and HTTPRoute status.
- Review Authorino logs without printing credentials.
- Inspect `pytest.log` and `failures.txt`.

### Gateway Readiness

Test node ID:

```text
testsuite/tests/singlecluster/gateway/test_basic.py::test_gateway_readiness
```

Purpose:

Validates Gateway readiness and dataplane reachability.

Prerequisites:

- Istio GatewayClass is accepted.
- Gateway becomes programmed.
- Gateway Pod becomes ready.
- Gateway Service receives an address.

Exact execution command:

```bash
PPC64LE_NATIVE_RLP_WORKAROUND=true \
poetry run pytest \
  --tb=long \
  -p no:rerunfailures \
  --log-cli-level=INFO \
  -n0 \
  -v \
  -s \
  "testsuite/tests/singlecluster/gateway/test_basic.py::test_gateway_readiness"
```

Expected result:

```text
PASSED
```

Troubleshooting:

- Verify the GatewayClass is accepted.
- Verify the Gateway is programmed.
- Verify the Gateway Service has an address.
- Verify the Gateway Pod is ready.
- Inspect `pytest.log`.

### Gateway DNS/TLS

Test node ID:

```text
testsuite/tests/singlecluster/gateway/test_basic.py::test_gateway_basic_dns_tls
```

Purpose:

Validates exact-host DNS resolution, TLS configuration, and HTTPS Gateway
access.

Prerequisites:

- CoreDNS NodePort is reachable from the bastion.
- The pytest DNS resolver variables are set.
- The exact-host DNS helper is running.
- The HTTPRoute is accepted.
- The Gateway is programmed.
- TCP port 443 is reachable on the Gateway address.

Exact execution command:

```bash
PPC64LE_NATIVE_RLP_WORKAROUND=true \
poetry run pytest \
  --tb=long \
  -p no:rerunfailures \
  --log-cli-level=INFO \
  -n0 \
  -v \
  -s \
  "testsuite/tests/singlecluster/gateway/test_basic.py::test_gateway_basic_dns_tls"
```

Expected resolver startup:

```text
getaddrinfo patched for *.kuadrant.internal -> <host>:<port>
dnspython patched for *.kuadrant.internal -> <host>:<port>
```

Expected result:

```text
HTTPS request: 200 OK
PASSED
```

Troubleshooting:

- Verify the DNS helper is running.
- Verify its log contains `Created`, `Verified`, and `READY`.
- Verify the exact SkyDNS key exists.
- Query the discovered CoreDNS endpoint directly.
- Confirm TCP port 443 is reachable on the Gateway address.
- Inspect `dns-helper.log`.
- Inspect `pytest.log`.

## 7. Troubleshooting

### Missing Prerequisite

The script classifies missing tools, missing files, cluster access failures,
unready nodes, and unreachable DNS endpoints as:

```text
prerequisite/infrastructure failure
```

Correct the prerequisite and rerun the workflow.

### Workaround Validation Failure

The script classifies missing native RLP code, an invalid VAP manifest, or a
DNS helper startup problem as:

```text
DNS-helper/workaround failure
```

The script does not rewrite source files, test files, or the VAP manifest.

### Test Failure

Failed assertions or unexpected responses are classified as:

```text
test failure
```

Inspect:

```text
pytest.log
junit.xml
summary.txt
failures.txt
reproduction-commands.txt
```

### CoreDNS Failure

Check the NodePort Service:

```bash
oc get service \
  coredns-nodeport \
  -n tools \
  -o wide
```

Check endpoint readiness:

```bash
oc get endpointslice \
  -n tools \
  -l kubernetes.io/service-name=coredns-nodeport
```

Run with an explicit endpoint when automatic discovery cannot find a
reachable node:

```bash
scripts/vap_workaround.sh \
  --coredns-host <node-internal-ip> \
  --coredns-port <node-port>
```

### Existing DNS Helper

If a matching DNS helper is already running, the script preserves it and
reports that ownership is external.

The script does not stop that process during cleanup.

### DNS Helper Startup Failure

Inspect:

```text
dns-helper.log
execution.log
```

Validate the helper manually:

```bash
bash -n scripts/sync-kuadrant-dns-etcd.sh
```

Confirm required commands:

```bash
command -v oc
command -v jq
command -v flock
command -v timeout
```

### Unknown Flaky Marker Warning

This warning is non-blocking:

```text
PytestUnknownMarkWarning: Unknown pytest.mark.flaky
```

The workflow intentionally disables retries using:

```text
-p no:rerunfailures
```

The warning does not change the test result.

## 8. Validation

### Validate Shell Syntax

```bash
bash -n scripts/vap_workaround.sh
```

Expected: no output and return code `0`.

### Run ShellCheck

```bash
if command -v shellcheck >/dev/null 2>&1; then
  shellcheck scripts/vap_workaround.sh
else
  echo "INFO: shellcheck is not installed"
fi
```

### Validate Help

```bash
scripts/vap_workaround.sh --help
```

### Validate Dry-Run

```bash
scripts/vap_workaround.sh \
  --dry-run \
  --verbose \
  --output-dir /tmp/vap-workaround-dry-run
```

### Verify the Workaround Prerequisites

```bash
grep -nE \
  'PPC64LE_NATIVE_RLP_WORKAROUND|create_native_ratelimit_workaround' \
  testsuite/tests/singlecluster/limitador/conftest.py
```

```bash
grep -n \
  'envoy.filters.http.ratelimit' \
  testsuite/kubernetes/envoy_filter.py
```

```bash
oc apply \
  --dry-run=server \
  -f block-kuadrant-wasm-envoyfilters.yaml
```

### Verify Smoke-Test Results

Inspect the summary:

```bash
cat <output-directory>/summary.txt
```

Expected fields:

```text
tests=<count>
passed=<count>
failed=<count>
errors=<count>
skipped=<count>
classification=<value>
```

Inspect the exit code:

```bash
cat <output-directory>/exit-code.txt
```

A successful run reports:

```text
0
```

### Inspect Logs and Artifacts

Each real execution directory contains:

```text
execution.log
pytest.log
junit.xml
summary.txt
failures.txt
reproduction-commands.txt
environment.txt
exit-code.txt
```

A helper started by the script also writes:

```text
dns-helper.log
```

Dry-run does not generate a JUnit XML result because no tests are executed.

## 9. Git Information

Original branch:

```text
kuadrant-ppc64le-dataplane-workaround
```

Original base commit:

```text
d5aad32ce804ef5b14bf808dd1fbec7a3a64ed10
```

Feature branch:

```text
feature/vap-workaround-automation
```

Planned remote branch:

```text
origin/feature/vap-workaround-automation
```

Commit message:

```text
Add VAP workaround automation and smoke test documentation
```

Commit ID:

```text
To be recorded after local validation and commit.
```

Files created by this task:

```text
scripts/vap_workaround.sh
scripts/VAP_WORKAROUND.md
```

No existing source file, test implementation, configuration file, settings
file, or CI/CD workflow is modified by this automation task.
