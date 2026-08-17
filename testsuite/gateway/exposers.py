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
    Wraps an OpenshiftRoute and actively probes the gateway until Istio's
    data plane is programmed (stops returning 404) AND the pod has endpoints
    (stops returning HTTP/1.0 503 from HAProxy).

    Probe logic:
      HTTP/1.1 404  -> Istio up, HTTPRoute not yet in xDS (keep waiting)
      HTTP/1.0 503  -> HAProxy no-endpoints: pod not running (keep waiting)
      connection err -> pod unreachable (keep waiting)
      anything else -> Istio up, route programmed, backend reachable (done)

    After readiness is confirmed, waits 20s for any Limitador rate-limit
    window started by the probes to expire before the real test begins.
    """

    ISTIO_READY_TIMEOUT = 300
    ISTIO_POLL_INTERVAL = 5

    def __init__(self, inner: Hostname, delay_seconds: int) -> None:
        self._inner = inner
        self._delay_seconds = delay_seconds
        self._waited = False

    def _log_cluster_state(self):
        """Log HTTPRoutes, RateLimitPolicies and OCP Routes for diagnostics."""
        try:
            httproutes = subprocess.run(
                ["kubectl", "get", "httproute", "-n", "kuadrant",
                 "-o", "custom-columns=NAME:.metadata.name,HOSTNAMES:.spec.hostnames"],
                capture_output=True, text=True, timeout=10
            )
            logger.info("[PowerVSExposer] HTTPRoutes:\n%s", httproutes.stdout)
            rlp = subprocess.run(
                ["kubectl", "get", "ratelimitpolicy", "-n", "kuadrant"],
                capture_output=True, text=True, timeout=10
            )
            logger.info("[PowerVSExposer] RateLimitPolicies:\n%s", rlp.stdout)
            routes = subprocess.run(
                ["oc", "get", "route", "-n", "kuadrant",
                 "-o", "custom-columns=NAME:.metadata.name,HOST:.spec.host,"
                       "SERVICE:.spec.to.name,PORT:.spec.port.targetPort"],
                capture_output=True, text=True, timeout=10
            )
            logger.info("[PowerVSExposer] OCP Routes:\n%s", routes.stdout)
        except Exception as exc:  # pylint: disable=broad-except
            logger.warning("[PowerVSExposer] Could not query cluster state: %s", exc)

    def client(self, **kwargs) -> KuadrantClient:
        if not self._waited:
            self._waited = True
            self._log_cluster_state()
            self._wait_for_istio_ready()
        return self._inner.client(**kwargs)

    def _wait_for_istio_ready(self):
        import httpx as _httpx

        url = f"http://{self._inner.hostname}/probe-powervs-ready"
        deadline = time.time() + self.ISTIO_READY_TIMEOUT
        attempt = 0
        ready = False
        while time.time() < deadline:
            attempt += 1
            try:
                resp = _httpx.get(url, timeout=5, follow_redirects=False)
                status = resp.status_code
                http_ver = resp.http_version
                logger.info("[PowerVSExposer] probe #%d -> %s %d", attempt, http_ver, status)

                if http_ver == "HTTP/1.0" and status == 503:
                    logger.debug("[PowerVSExposer] HAProxy 503 - pod not ready yet")
                elif http_ver == "HTTP/1.1" and status == 404:
                    logger.debug("[PowerVSExposer] Istio 404 - xDS not programmed yet")
                else:
                    logger.info("[PowerVSExposer] Istio ready after %d probe(s) (%s %d)",
                                attempt, http_ver, status)
                    ready = True
                    break
            except _httpx.RequestError as exc:
                logger.info("[PowerVSExposer] probe #%d connection error: %s", attempt, exc)
            time.sleep(self.ISTIO_POLL_INTERVAL)

        if not ready:
            logger.warning("[PowerVSExposer] Istio not ready after %ds; proceeding anyway",
                           self.ISTIO_READY_TIMEOUT)
            return

        logger.info("[PowerVSExposer] Waiting 20s for rate-limit window to reset...")
        time.sleep(20)

    @property
    def hostname(self) -> str:
        return self._inner.hostname


class PowerVSExposer(OpenShiftExposer):
    """
    Exposer for PowerVS clusters where:
    1. OCP Router assigns spec.host asynchronously (wait before caching)
    2. Istio xDS push is slower than x86 (active probe before test requests)
    """

    STABILIZE_SECONDS = 60
    HOST_ASSIGN_TIMEOUT = 120
    HOST_ASSIGN_POLL = 3

    def expose_hostname(self, name, exposable) -> Hostname:
        route = super().expose_hostname(name, exposable)
        # Wait for OCP Router to populate spec.host before @cached_property caches it
        deadline = time.time() + self.HOST_ASSIGN_TIMEOUT
        while time.time() < deadline:
            route.refresh()
            try:
                host = route.model.spec.host
            except (AttributeError, KeyError):
                host = None
            if host:
                logger.info("[PowerVSExposer] OCP Route spec.host = %s", host)
                route.__dict__.pop("hostname", None)
                break
            logger.debug("[PowerVSExposer] Waiting for OCP Route spec.host...")
            time.sleep(self.HOST_ASSIGN_POLL)
        else:
            logger.warning("[PowerVSExposer] spec.host never assigned after %ds",
                           self.HOST_ASSIGN_TIMEOUT)
        return DelayedHostname(route, self.STABILIZE_SECONDS)
