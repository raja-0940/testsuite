# Kuadrant e2e on ppc64le — helper scripts

These scripts prepare an OpenShift ppc64le cluster with RHCL (Kuadrant) 1.5 and run the
Kuadrant e2e testsuite from this repository. They contain only the steps needed to run
the e2e tests. Run all commands from the repository root (`testsuite/`) on the bastion.

| Script | When | Purpose |
|---|---|---|
| `apply-wasm-be-fix.sh` | once per operator install | Builds/injects a wasm-shim patched for big-endian (ppc64le) so the Wasm plugin (Auth/RateLimit/TokenRateLimit) loads in Envoy |
| `setup-egress-vault-authorino.sh` | once | Vault Kubernetes auth + Authorino cluster trust bundle (needed by `egress` tests) |
| `setup-operator-tracing.sh` | once | `OTEL_*` env on the RHCL operator Subscription (needed by `tracing/control_plane` tests) |
| `setup-kuadrant-coredns.sh` | once | Deploys `coredns-kuadrant` (reads DNSRecords) on NodePort 30554 (needed by `dnspolicy` tests) |
| `kuadrant-pre-e2e.sh` | before every run | Validates the cluster/tools, creates namespaces/services/secrets, updates DNS fields + OCP token in `config/settings.local.yaml`, starts the two helper daemons below, writes the env file |
| `sync-kuadrant-dns-etcd.sh` | daemon (started by pre-e2e) | Syncs HTTPRoute hostnames into etcd so `*.kuadrant.internal` resolves from the bastion |
| `fix-ef-denywith.py` | daemon (started by pre-e2e) | Fixes the invalid `denyWith` CEL body (`Too Many Requests\n"!}`) that RHCL 1.5 generates in the wasm EnvoyFilter |
| `run-kuadrant-e2e.sh` | run | Runs the full suite or selected tests/groups with the standard options |

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
(`dnf install -y protobuf-compiler unzip`), and a wasm-shim checkout (`WASM_SRC`, default `/root/wasm-shim`).

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

## 3. One-time environment setup

Run these once after RHCL is installed (all are idempotent):

```bash
./scripts/apply-wasm-be-fix.sh                # add --skip-build --skip-push if the images already exist
./scripts/setup-egress-vault-authorino.sh
./scripts/setup-operator-tracing.sh
./scripts/setup-kuadrant-coredns.sh
```

`apply-wasm-be-fix.sh` options: `--wasm-src DIR`, `--image-tag TAG`, `--injector-tag TAG`, `--op-ns NS`, `--dry-run`.
You can set the same values through the env vars `WASM_SRC`, `IMAGE_TAG`, `INJECTOR_TAG` and `OPERATOR_NS`.
Re-run it after the operator is reinstalled or upgraded.

## 4. Before every run

```bash
./scripts/kuadrant-pre-e2e.sh
```

It writes `/tmp/kuadrant-ppc64le-e2e-env.sh` (override with `ENV_FILE`). It also starts these daemons:

- DNS sync: pid in `/tmp/kuadrant-ppc64le-dns-helper.pid`, log in `/tmp/kuadrant-ppc64le-dns-helper.log`
- EF fix: pid in `/tmp/ef-fix-daemon.pid`, log in `/tmp/ef-fix-daemon.log`

Re-running the script reuses the DNS helper and restarts the EF-fix daemon. Set `RESET_DNS=1` to restart the DNS helper.

## 5. Running the tests

The full run takes several hours, so use tmux:

```bash
tmux new -s kuadrant-e2e './scripts/run-kuadrant-e2e.sh'
# detach: Ctrl-b d      re-attach: tmux attach -t kuadrant-e2e
```

Run only selected tests or a failed group (same options as the full run):

```bash
RUN_NAME=limitador ./scripts/run-kuadrant-e2e.sh testsuite/tests/singlecluster/limitador
RUN_NAME=egress    ./scripts/run-kuadrant-e2e.sh testsuite/tests/singlecluster/egress
# dnspolicy tests resolve through kuadrant-coredns (setup-kuadrant-coredns.sh):
COREDNS_PORT_OVERRIDE=30554 RUN_NAME=dnspolicy ./scripts/run-kuadrant-e2e.sh testsuite/tests/singlecluster/gateway/dnspolicy
```

The runner uses these pytest options:
- `--reruns 3 --verify-denials=true --enforce -n0`
- `-m "not standalone_only and not disruptive and not ui"`
- `ui/` and `observability/` are ignored

Results go to `RESULTS_DIR` (default `~/kuadrant-e2e-results`) as `<name>-e2e-<ts>.log`, `junit-<name>-<ts>.xml` and
`report-<name>-<ts>.html`.

## 6. After the run

```bash
make clean                                            # remove objects created by the testsuite
oc get gateway -A                                     # orphan gateways hold MetalLB IPs; delete leftovers
kill "$(cat /tmp/kuadrant-ppc64le-dns-helper.pid)" "$(cat /tmp/ef-fix-daemon.pid)"   # stop the daemons
```
