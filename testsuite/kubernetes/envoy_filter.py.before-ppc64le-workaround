"""Module containing Istio's EnvoyFilter related class"""

import json
import logging
import time

import openshift_client as oc
from openshift_client import OpenShiftPythonException

from testsuite.gateway import Gateway
from testsuite.kubernetes import KubernetesObject, modify
from testsuite.kubernetes.client import KubernetesClient
from testsuite.utils.constants import EXTENSION_POLICY_PROPAGATION_WAIT, WASM_PLUGIN_SYNC_WAIT

logger = logging.getLogger(__name__)

GATEWAY_NAME_LABEL = "gateway.networking.k8s.io/gateway-name"


def kuadrant_envoyfilter_names(gateway_name: str) -> tuple[str, str]:
    """Return Kuadrant WASM and ratelimit EnvoyFilter names for a gateway."""
    return f"kuadrant-{gateway_name}", f"kuadrant-ratelimiting-{gateway_name}"


def patch_kuadrant_managed_envoyfilters_to_workload_selector(cluster: KubernetesClient, gateway: Gateway) -> None:
    """Replace targetRefs with workloadSelector on Kuadrant-managed EnvoyFilters.

    Workaround for Istio/RHSM setups where EnvoyFilters attached only via targetRefs
    are not applied to Gateway API gateway pods.
    """
    gateway_name = gateway.name()
    patch_body = json.dumps(
        [
            {"op": "remove", "path": "/spec/targetRefs"},
            {
                "op": "add",
                "path": "/spec/workloadSelector",
                "value": {"labels": {GATEWAY_NAME_LABEL: gateway_name}},
            },
        ]
    )

    for ef_name in kuadrant_envoyfilter_names(gateway_name):
        with cluster.context:
            try:
                ef = oc.selector(f"envoyfilter.networking.istio.io/{ef_name}").object()
            except OpenShiftPythonException:
                logger.warning("Kuadrant EnvoyFilter %s not found, skipping workloadSelector patch", ef_name)
                continue

            if not getattr(ef.model.spec, "targetRefs", None):
                logger.info("EnvoyFilter %s already uses workloadSelector, skipping", ef_name)
                continue

        result = cluster.do_action(
            "patch",
            "envoyfilter",
            ef_name,
            "--type=json",
            "-p",
            patch_body,
            auto_raise=False,
        )
        if result.status() != 0:
            logger.warning(
                "Failed to patch EnvoyFilter %s to workloadSelector: %s",
                ef_name,
                result.err(),
            )
            continue
        logger.info("Patched EnvoyFilter %s to use workloadSelector for gateway %s", ef_name, gateway_name)

    time.sleep(EXTENSION_POLICY_PROPAGATION_WAIT + WASM_PLUGIN_SYNC_WAIT)


class EnvoyFilter(KubernetesObject):
    """Istio EnvoyFilter object for patching Envoy proxy configuration"""

    @classmethod
    def create_instance(
        cls,
        cluster,
        name,
        gateway: Gateway,
        labels: dict[str, str] = None,
    ):
        """Creates new instance of EnvoyFilter targeting a Gateway"""
        model: dict = {
            "apiVersion": "networking.istio.io/v1alpha3",
            "kind": "EnvoyFilter",
            "metadata": {
                "name": name,
                "namespace": cluster.project,
                "labels": labels,
            },
            "spec": {
                "targetRefs": [gateway.reference],
                "configPatches": [],
            },
        }

        return cls(model, context=cluster.context)

    @modify
    def add_client_cert_validation(self, port_number: int, ca_cert_path: str):
        """Adds a configPatch that enables client certificate validation on a listener"""
        self.model.spec.configPatches.append(
            {
                "applyTo": "FILTER_CHAIN",
                "match": {
                    "context": "GATEWAY",
                    "listener": {
                        "portNumber": port_number,
                    },
                },
                "patch": {
                    "operation": "MERGE",
                    "value": {
                        "transport_socket": {
                            "name": "envoy.transport_sockets.tls",
                            "typed_config": {
                                "@type": "type.googleapis.com/envoy.extensions.transport_sockets."
                                "tls.v3.DownstreamTlsContext",
                                "requireClientCertificate": True,
                                "commonTlsContext": {
                                    "validationContext": {
                                        "trusted_ca": {
                                            "filename": ca_cert_path,
                                        }
                                    }
                                },
                            },
                        }
                    },
                },
            }
        )
