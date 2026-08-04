"""General exposers, not tied to Envoy or Gateway API"""

import logging
import subprocess
import time

from testsuite.gateway import Exposer, Hostname
from testsuite.httpx import KuadrantClient, ForceSNIClient
from testsuite.kubernetes.openshift.route import OpenshiftRoute

logger = logging.getLogger(__name__)


class OpenShiftExposer(Exposer):
    """Exposes hostnames through OpenShift Route objects"""

    def __init__(self, cluster) -> None:
        super().__init__(cluster)
        self.routes: list[OpenshiftRoute] = []

    @property
    def base_domain(self) -> str:
        return self.cluster.apps_url

    def expose_hostname(self, name, exposable) -> Hostname:
        tls = False
        termination = "edge"
        if self.passthrough:
            tls = True
            termination = "passthrough"
        route = OpenshiftRoute.create_instance(
            exposable.cluster, name, exposable.service_name, exposable.port_name, tls=tls, termination=termination
        )
        route.verify = self.verify
        self.routes.append(route)
        route.commit()
        return route

    def commit(self):
        return

    def delete(self):
        for route in self.routes:
            route.delete()
        self.routes = []


class StaticLocalHostname(Hostname):
    """Static local IP hostname"""

    def __init__(self, hostname, ip_getter, verify_getter=None, force_https: bool = False):
        self._hostname = hostname
        self.ip_getter = ip_getter
        self.verify_getter = verify_getter
        self.force_https = force_https

    def client(self, **kwargs) -> KuadrantClient:
        headers = kwargs.setdefault("headers", {})
        headers["Host"] = self.hostname
        ip = self.ip_getter()
        verify = self.verify_getter() if self.verify_getter else None
        protocol = "http"
        if verify or self.force_https:
            ip = ip.replace(":80", ":443")
            protocol = "https"
            kwargs.setdefault("verify", verify)
        return ForceSNIClient(base_url=f"{protocol}://{ip}", sni_hostname=self.hostname, **kwargs)

    @property
    def hostname(self):
        return self._hostname


class LoadBalancerServiceExposer(Exposer):
    """Exposer using Load Balancer service for Gateway"""

    def expose_hostname(self, name, exposable) -> Hostname:
        hostname = f"{name}.{self.base_domain}"
        return StaticLocalHostname(
            hostname, exposable.external_ip, lambda: exposable.get_tls_cert(hostname), force_https=self.passthrough
        )

    @property
    def backend_service_type(self) -> str:
        return "LoadBalancer"

    @property
    def base_domain(self) -> str:
        return "test.com"

    def commit(self):
        pass

    def delete(self):
        pass


class DelayedHostname(Hostname):
    """
    Wraps a Hostname and sleeps once before creating the first client.
    Used on PowerVS where Istio's data plane takes extra seconds to program
    after wait_for_ready() returns True on the HTTPRoute/policies.
    The sleep fires AFTER all fixtures (route, commit) have completed —
    i.e. just before the test function calls hostname.client().
    """

    def __init__(self, inner: Hostname, delay_seconds: int) -> None:
        self._inner = inner
        self._delay_seconds = delay_seconds
        self._waited = False

    def client(self, **kwargs) -> KuadrantClient:
        if not self._waited:
            self._waited = True
            logger.info("[PowerVSExposer] Waiting %ds for Istio data-plane to program...", self._delay_seconds)
            # Log current cluster state before sleeping
            try:
                httproutes = subprocess.run(
                    ["kubectl", "get", "httproute", "-n", "kuadrant",
                     "-o", "custom-columns=NAME:.metadata.name,HOSTNAMES:.spec.hostnames"],
                    capture_output=True, text=True, timeout=10
                )
                logger.info("[PowerVSExposer] HTTPRoutes before sleep:\n%s", httproutes.stdout)
                rlp = subprocess.run(
                    ["kubectl", "get", "ratelimitpolicy", "-n", "kuadrant"],
                    capture_output=True, text=True, timeout=10
                )
                logger.info("[PowerVSExposer] RateLimitPolicies before sleep:\n%s", rlp.stdout)
            except Exception as exc:  # pylint: disable=broad-except
                logger.warning("[PowerVSExposer] Could not query cluster state: %s", exc)
            time.sleep(self._delay_seconds)
            logger.info("[PowerVSExposer] Sleep done, creating client for hostname: %s", self._inner.hostname)
        return self._inner.client(**kwargs)

    @property
    def hostname(self) -> str:
        return self._inner.hostname


class PowerVSExposer(OpenShiftExposer):
    """
    Exposer for PowerVS/on-prem clusters where Istio's data plane takes
    additional time to program after wait_for_ready() returns on the HTTPRoute
    and policies. The delay fires once, just before the first client request,
    after all fixtures have completed — giving Istio time to push xDS config.
    """

    STABILIZE_SECONDS = 60

    def expose_hostname(self, name, exposable) -> Hostname:
        route = super().expose_hostname(name, exposable)
        return DelayedHostname(route, self.STABILIZE_SECONDS)
