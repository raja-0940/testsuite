# Kuadrant e2e on ppc64le — helper scripts

These scripts prepare an OpenShift ppc64le cluster with RHCL (Kuadrant) 1.5 and run the
Kuadrant e2e testsuite from this repository. They contain only the steps needed to run
the e2e tests. Run all commands from the repository root (`testsuite/`) on the bastion.

| Script | When | Purpose |
|---|---|---|
| `apply-wasm-be-fix.sh` | once per operator install | Builds/injects a wasm-shim patched for big-endian (ppc64le) so the Wasm plugin (Auth/RateLimit/TokenRateLimit) loads in Envoy |
| `setup-egress-vault-authorino.sh` | once | Vault Kubernetes auth + Authorino cluster trust bundle (needed by `egress` tests) |
| `setup-operator-tracing.sh` | once | `OTEL_*` env on the RHCL operator Subscription (needed by `tracing/control_plane` tests) |
| `setup-dataplane-observability.sh` | once | `spec.observability.dataPlane` on the Kuadrant CR (needed by `tracing/data_plane_tracing` tests) |
| `setup-kuadrant-coredns.sh` | once | Deploys `coredns-kuadrant` (reads DNSRecords) on NodePort 30554 (needed by `gateway/*` DNSPolicy tests); `kuadrant-pre-e2e.sh` writes this port into the env file |
| `kuadrant-pre-e2e.sh` | before every run | Validates the cluster/tools, creates namespaces/services/secrets, updates DNS fields + OCP token in `config/settings.local.yaml`, starts the two helper daemons below, writes the env file |
| `sync-kuadrant-dns-etcd.sh` | daemon (started by pre-e2e) | Syncs HTTPRoute hostnames into etcd so `*.kuadrant.internal` resolves from the bastion |
| `fix-ef-denywith.py` | daemon (started by pre-e2e) | Rewrites the invalid `denyWith` CEL body (`Too Many Requests\n"!}`) that RHCL 1.5 generates in the wasm EnvoyFilter to the quoted string `"Too Many Requests\n"` (see section 7) |
| `run-kuadrant-e2e.sh` | run | Runs the full suite or selected tests/groups with the standard options |
| `run-full-e2e-power.sh` | run | Full suite with the Power workarounds: preflight checks, kuadrant-coredns NodePort (discovered, `COREDNS_PORT_OVERRIDE` wins), timestamped dir with `full-e2e.log`, junit, html, `summary.txt`, `failures.txt` |

## 1. Prerequisites

### Cluster
- OpenShift 4.x on ppc64le, logged in as cluster-admin (`oc whoami` works, `KUBECONFIG` set).
- Operators installed with CSV `Succeeded`:
  - Red Hat Connectivity Link `rhcl-operator.v1.5.0` (namespace `openshift-operators`)
  - OpenShift Service Mesh 3 (`servicemeshoperator3`) — Gateway API provider
  - cert-manager, with a ClusterIssuer (e.g. `kuadrant-qe-issuer`)
  - MetalLB with an `IPAddressPool` for Gateway `LoadBalancer` services. Make sure the pool has enough free IPs
    (each test module creates a gateway).
- `Kuadrant` CR `kuadrant` in `kuadrant-system` is `Ready`. For tracing tests, `spec.observability.tracing` points to
  the Jaeger collector.
- Test namespaces `kuadrant` and `kuadrant2` (created by `kuadrant-pre-e2e.sh` if missing).
- `tools` namespace with the testsuite tools, all ppc64le images, and Routes for keycloak, mockserver, vault
  and jaeger-query:
  `etcd`, `coredns` (etcd backend, zone `kuadrant.internal`, port 5353), `keycloak`, `mockserver`, `vault` (dev mode),
  `jaeger`.

### Bastion tools
`oc`, `kubectl`, `helm`, `yq` (v4), `jq`, `dig`, `curl`, `tmux`, `cfssl`, `python3` (3.11+), `poetry` (2.x), `git`.

Only for `apply-wasm-be-fix.sh`: `podman` (logged in to the target registry, e.g. `podman login quay.io`),
Rust with the `wasm32-wasip1` target (`rustup target add wasm32-wasip1`), `protoc`
(>= 3.15; auto-downloaded into `<wasm-src>/bin` if missing/older, needs `unzip` + `curl`), and a wasm-shim checkout
(`WASM_SRC`, default `/root/wasm-shim`).

> RHCL 1.5 needs wasm-shim **v0.15.0** or later: token reservation (Reserve/Commit), `responseBodyJSON`,
> streaming TRLP and case-insensitive hostnames are missing in older builds (all `tokens_rate_limit/reservation`
> and `test_hostname_case` tests fail with 200 instead of 401/429, streaming tests time out). Use a clean tag checkout:
> `git -C /root/wasm-shim worktree add /root/wasm-shim-v0.15.0 v0.15.0`, then `--wasm-src /root/wasm-shim-v0.15.0`.
> v0.15.0 reports dataplane traces to Jaeger as service `kuadrant-filter` (what upstream tests expect).

## 2. Testsuite setup

```bash
git clone <this repo> testsuite && cd testsuite
make poetry-no-dev          # creates the poetry venv (python 3.11) and installs dependencies
poetry run python -c "import testsuite"   # sanity check
```

Create `config/settings.local.yaml`. Keep secrets out of git; the file is ignored. Minimal content used on ppc64le:

```yaml
default:
  cfssl: /usr/local/bin/cfssl
  default_exposer: openshift
  prometheus:
    url: https://thanos-querier-openshift-monitoring.apps.<cluster-domain>
    project: openshift-monitoring
    service: thanos-querier
  service_protection:
    system_project: kuadrant-system      # namespace of the Kuadrant CR / Authorino / Limitador
    operator_project: openshift-operators # namespace of kuadrant-operator-controller-manager (OLM)
    project: kuadrant
    project2: kuadrant2
  control_plane:
    cluster:
      kubeconfig_path: <path to kubeconfig>
      token: <OCP bearer token; written by kuadrant-pre-e2e.sh step 9b>
    slow_loadbalancers: true
    provider_secret: coredns-credentials
    issuer:
      name: kuadrant-qe-issuer
      kind: ClusterIssuer
  dns:
    coredns_zone: kuadrant.internal
    dns_server:
      geo_code: DE
      address: <updated by kuadrant-pre-e2e.sh>
    default_geo_server: <updated by kuadrant-pre-e2e.sh>
  tools:
    project: tools
  keycloak:
    url: http://keycloak-tools.apps.<cluster-domain>
    username: admin
    password: <keycloak admin password>
    test_user:
      username: testUser
      password: <test user password>
  mockserver:
    url: http://mockserver-tools.apps.<cluster-domain>
    image: quay.io/pbastide_rh/mockserver-ppc64le:f572b831a14d0b3027d4f6164d60051fe8e2b6f7
  tracing:
    backend: jaeger
    collector_url: rpc://jaeger-collector.tools.svc.cluster.local:4317
    query_url: http://jaeger-query-tools.apps.<cluster-domain>
  vault:
    url: http://vault-tools.apps.<cluster-domain>
    token: <vault root token>
  llm_sim:
    image: quay.io/raja0940/llm-d-inference-sim-ppc64le:v091-fixed
  grpcbin:
    image: quay.io/raja0940/grpcbin:ppc64le-rc3-tls
  spicedb:
    image: quay.io/pbastide_rh/spicedb-ppc64le:latest
  pipeline_policy_extension_service:
    image: quay.io/raja-0940/threat-assessment-service:latest
```

> `system_project` must be `kuadrant-system`, not `openshift-operators`. With the wrong value, most Authorino and
> Limitador tests fail.
>
> `control_plane.cluster.token` is required when the kubeconfig uses client certificates (e.g. installer kubeconfig):
> the Prometheus fixture sends `Bearer <token>`, and an empty token fails all metrics tests with
> `Illegal header value b'Bearer '`. `kuadrant-pre-e2e.sh` refreshes it from `oc whoami --show-token`.
> `kube:admin` OAuth tokens expire after 24 h; an expired token gives `401 Unauthorized` from thanos-querier in metrics
> test setup. Re-run `kuadrant-pre-e2e.sh` (or step 9b) before metrics groups on long sessions.

## 3. One-time environment setup

Run these once after RHCL is installed (all are idempotent):

```bash
./scripts/apply-wasm-be-fix.sh                # add --skip-build --skip-push if the images already exist
./scripts/setup-egress-vault-authorino.sh
./scripts/setup-operator-tracing.sh
./scripts/setup-dataplane-observability.sh   # revert: --revert
make configure-istio-tracing TOOLS_NAMESPACE=tools   # upstream target: Istio meshConfig jaeger-otlp + Telemetry
./scripts/setup-kuadrant-coredns.sh
```

`apply-wasm-be-fix.sh` options: `--wasm-src DIR`, `--image-tag TAG`, `--injector-tag TAG`, `--op-ns NS`, `--dry-run`.
You can set the same values through the env vars `WASM_SRC`, `IMAGE_TAG`, `INJECTOR_TAG` and `OPERATOR_NS`.
Re-run it after the operator is reinstalled or upgraded.

`tracing/data_plane_tracing` needs all three tracing pieces: `setup-dataplane-observability.sh` (wasm spans with
`request_id`), wasm-shim >= 0.15 (service `kuadrant-filter`), and `make configure-istio-tracing`. With the `istio`
GatewayClass, the tests expect the gateway's own Envoy spans (4 processes). Revert the Istio part with
`oc delete telemetry -n istio-system default-telemetry` and by removing `enableTracing`/`extensionProviders` from
`Istio/default` `spec.values.meshConfig`.

To swap only the injector image (wasm already built/pushed), patch the CSV init container and verify the served binary:

```bash
oc get csv rhcl-operator.v1.5.0 -n openshift-operators -o json > csv-backup.json   # rollback: restore the old image the same way
oc patch csv rhcl-operator.v1.5.0 -n openshift-operators --type json -p \
  '[{"op":"replace","path":"/spec/install/spec/deployments/0/spec/template/spec/initContainers/0/image","value":"<injector@sha256:...>"}]'
oc exec -n openshift-operators deploy/kuadrant-operator-controller-manager -c manager -- sha256sum /wasm/plugin.wasm
```

## 4. Before every run

```bash
./scripts/kuadrant-pre-e2e.sh
```

It writes `/tmp/kuadrant-ppc64le-e2e-env.sh` (override with `ENV_FILE`). `KUADRANT_COREDNS_DNS_PORT` in that file is the
NodePort of Service `kuadrant-coredns/kuadrant-coredns` (DNSRecord-backed, normally 30554); if that Service is missing it
falls back to the etcd CoreDNS NodePort 30553 with a warning (DNSPolicy tests then fail). Override with `TEST_DNS_PORT`.
It also starts these daemons:

- DNS sync: pid in `/tmp/kuadrant-ppc64le-dns-helper.pid`, log in `/tmp/kuadrant-ppc64le-dns-helper.log`
- EF fix: pid in `/tmp/ef-fix-daemon.pid`, log in `/tmp/ef-fix-daemon.log`

Re-running the script reuses the DNS helper and restarts the EF-fix daemon. Set `RESET_DNS=1` to restart the DNS helper.

## 5. Running the tests

The full run takes several hours, so use tmux. Recommended (preflight + kuadrant-coredns + reports):

```bash
tmux new -d -s kuadrant-power-full-e2e "cd /root/test/testsuite && ./scripts/run-full-e2e-power.sh; exec bash"
tmux attach -t kuadrant-power-full-e2e            # detach: Ctrl-b d
tail -n 100 -f /root/test/results/full-e2e-<ts>/full-e2e.log
```

`run-full-e2e-power.sh` refuses to start (exit 2) if a preflight check fails: another pytest is running, nodes/COs
unhealthy, RHCL CSV, served wasm sha (`EXPECTED_WASM_SHA`, default v0.15.0 BE `41e298e2`), Kuadrant CR dataPlane,
Istio tracing, both helper daemons, kuadrant-coredns NodePort, MetalLB pool, tools pods, settings token (checked with
`oc whoami`, never printed). Output goes to `RESULTS_ROOT/full-e2e-<ts>/` (default `/root/test/results`):
`full-e2e.log`, `junit-full-e2e.xml`, `report-full-e2e.html`, `exit-code.txt`, `environment.txt`, `summary.txt`,
`failures.txt`. It sets `COREDNS_PORT_OVERRIDE` to the kuadrant-coredns NodePort (30554 if it cannot be discovered): only
`gateway/*` tests use `*.kuadrant.internal` and they all create a DNSPolicy, which kuadrant-coredns serves directly.

Before a full run, delete leftover test resources from interrupted runs (they hold MetalLB IPs):
`oc get gateway,httproute,authpolicy,ratelimitpolicy,tokenratelimitpolicy -n kuadrant` and delete objects labelled
`testrun-root--*` that no running test owns (save them with `-o yaml` first).

Plain runner (no preflight):

```bash
tmux new -s kuadrant-e2e './scripts/run-kuadrant-e2e.sh'
```

Run only selected tests or a failed group (same options as the full run):

```bash
RUN_NAME=limitador ./scripts/run-kuadrant-e2e.sh testsuite/tests/singlecluster/limitador
RUN_NAME=egress    ./scripts/run-kuadrant-e2e.sh testsuite/tests/singlecluster/egress
# dnspolicy tests resolve through kuadrant-coredns (port taken from the env file; COREDNS_PORT_OVERRIDE overrides it):
RUN_NAME=dnspolicy ./scripts/run-kuadrant-e2e.sh testsuite/tests/singlecluster/gateway/dnspolicy
```

The runner uses these pytest options:
- `--reruns 3 --verify-denials=true --enforce -n0`
- `-m "not standalone_only and not disruptive and not ui"`
- `ui/` and `observability/` are ignored

Results go to `RESULTS_DIR` (default `~/kuadrant-e2e-results`) as `<name>-e2e-<ts>.log`, `junit-<name>-<ts>.xml` and
`report-<name>-<ts>.html` (override the paths with `LOG_FILE`, `JUNIT_FILE`, `HTML_FILE`).

## 6. After the run

```bash
make clean                                            # remove objects created by the testsuite
oc get gateway -A                                     # orphan gateways hold MetalLB IPs; delete leftovers
kill "$(cat /tmp/kuadrant-ppc64le-dns-helper.pid)" "$(cat /tmp/ef-fix-daemon.pid)"   # stop the daemons
```

### Known order/timing flakes on Power (pass in isolation)
- `egress/credentials_injection/test_credential_injection_by_destination.py`
- `gateway/authpolicy/test_authpolicy_section_targeting_gateway.py` (also fails on IBM Z CI)
- `gateway/reconciliation/change_targetref/test_update_ratelimitpolicy_target_ref.py` (`reruns=0`): RLP `Enforced` /
  Gateway "affected by" is reported before Envoy runs the new wasm config. The test now waits (max 180 s) until the
  gateway answers 429 and then for the 10 s window to reset; the original assertions are unchanged (`ppc64le-fix: rlp-retarget`).

If one fails in a batch run, re-run it alone with `./scripts/run-kuadrant-e2e.sh <path>`.

## 7. What the Power workarounds change (and what they do not)

| Workaround | Where | Effect on what is tested |
|---|---|---|
| BE wasm-shim (`apply-wasm-be-fix.sh`) | CSV `inject-wasm` initContainer + `RELATED_IMAGE_WASMSHIM` | Upstream wasm-shim tag (v0.15.0) with one change: `current_log_filter()` returns `WARN` instead of calling the `proxy_get_log_level` host call that faults on big-endian ([proxy-wasm-cpp-host#552](https://github.com/proxy-wasm/proxy-wasm-cpp-host/issues/552)). Auth/RateLimit/TRLP logic is unchanged; only the wasm log level is fixed at WARN. |
| `fix-ef-denywith.py` | live EnvoyFilters `kuadrant.io/wasm=true` | Replaces the malformed operator CEL `body: Too Many Requests\n"!}` with `body: "Too Many Requests\n"`. Status 429 and headers are unchanged. Without it, every new wasm config is rejected by Envoy (`failed to compile plugin config: InvalidDataExpression`); with `failurePolicy: fail-closed` the gateway then answers 503, or keeps the previous config. The operator re-reconciles the EnvoyFilter and the daemon re-patches it, so the EnvoyFilter `generation` grows continuously while the daemon runs (expected). Not architecture-specific; it is a product defect. |
| `kuadrant-coredns` + resolver plugin | `kuadrant-coredns` ns, `kuadrant_coredns_resolve.py` | Test-side DNS only (`*.kuadrant.internal` from the bastion). DNSPolicy/DNSRecord reconciliation is unchanged. |
| Dataplane readiness waits (`ppc64le-fix:` in tests) | tests/fixtures | Poll until the dataplane shows the expected behaviour (401/403/429/302), bounded (60–180 s); the original assertions run afterwards. |
| Velocity mockserver templates | `echo_expectation.json`, two authorino fixtures | The ppc64le mockserver build has no JavaScript (Nashorn) engine; same responses in Velocity. |

Checked on the cluster (2026-10-10 audit): with only a RateLimitPolicy (2 req / 10 s) the gateway returns
`200 200 429 429 429`, and after a limit change `200 200 200 200 429 429`, so rate limiting is enforced, not bypassed.
