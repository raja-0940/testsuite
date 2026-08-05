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
    Wraps a Hostname and actively polls the gateway until Istio's data plane
    has programmed the HTTPRoute (i.e. stops returning 404).
    Used on PowerVS where Istio xDS push takes longer than on x86 after
    wait_for_ready() returns True on the Gateway/HTTPRoute/policies.
    The probe fires AFTER all fixtures have completed, just before the test
    function calls hostname.client().
    """

    # Max seconds to wait for Istio to stop returning 404
    ISTIO_READY_TIMEOUT = 180
    ISTIO_POLL_INTERVAL = 5

    def __init__(self, inner: Hostname, delay_seconds: int) -> None:
        self._inner = inner
        self._delay_seconds = delay_seconds  # kept for compatibility, used as initial sleep
        self._waited = False

    def _log_cluster_state(self):
        """Log current state of HTTPRoutes, RateLimitPolicies and OCP Routes for diagnostics."""
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
                 "-o", "custom-columns=NAME:.metadata.name,HOST:.spec.host,SERVICE:.spec.to.name,PORT:.spec.port.targetPort"],
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
        """
        Poll the gateway hostname until Istio is programmed AND the pod has endpoints.

        Response categories:
          HTTP/1.1 404  — Istio is up, HTTPRoute not yet in xDS (keep waiting)
          HTTP/1.0 503  — HAProxy: Istio pod has no endpoints yet (keep waiting)
          connection err — pod not reachable yet (keep waiting)
          anything else — Istio up, route programmed, backend reachable (done)

        HTTP version discriminates the source:
          HTTP/1.1 -> came from Istio/Envoy
          HTTP/1.0 -> came from OCP HAProxy (no backend pod endpoints)

        After readiness is confirmed, wait 20s for the Limitador rate-limit window
        started by the probes to expire before the real test requests begin.
        """
        import httpx as _httpx

        # Probe path matches PathPrefix "/" but is distinct from the test path "/get"
        url = f"http://{self._inner.hostname}/probe-powervs-ready"
        deadline = time.time() + self.ISTIO_READY_TIMEOUT
        attempt = 0
        ready = False
        while time.time() < deadline:
            attempt += 1
            try:
                resp = _httpx.get(url, timeout=5, follow_redirects=False)
                status = resp.status_code
                http_ver = resp.http_version  # "HTTP/1.0" or "HTTP/1.1"
                logger.info("[PowerVSExposer] probe #%d -> %s %d", attempt, http_ver, status)

                if http_ver == "HTTP/1.0" and status == 503:
                    # HAProxy no-endpoints: Istio pod not running yet
                    logger.debug("[PowerVSExposer] HAProxy 503 - pod not ready yet")
                elif http_ver == "HTTP/1.1" and status == 404:
                    # Istio running but HTTPRoute not yet in xDS
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

        # Wait for Limitador rate-limit window to reset so probe requests don't
        # consume quota from the first real test window.
        logger.info("[PowerVSExposer] Waiting 20s for rate-limit window to reset...")
        time.sleep(20)

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
    # How long (seconds) to poll for OCP router to populate spec.host on the Route
    HOST_ASSIGN_TIMEOUT = 120
    HOST_ASSIGN_POLL = 3

    def expose_hostname(self, name, exposable) -> Hostname:
        # super().expose_hostname() calls route.commit() which does self.refresh()
        # but OCP router assigns spec.host asynchronously — it may still be empty.
        # We wait here until spec.host is populated before @cached_property caches it.
        route = super().expose_hostname(name, exposable)
        deadline = time.time() + self.HOST_ASSIGN_TIMEOUT
        while time.time() < deadline:
            route.refresh()
            try:
                host = route.model.spec.host
            except (AttributeError, KeyError):
                host = None
            if host:
                logger.info("[PowerVSExposer] OCP Route spec.host = %s", host)
                # Bust the cached_property so it re-reads the now-populated value
                route.__dict__.pop("hostname", None)
                break
            logger.debug("[PowerVSExposer] Waiting for OCP Route spec.host to be assigned...")
            time.sleep(self.HOST_ASSIGN_POLL)
        else:
            logger.warning("[PowerVSExposer] spec.host was never assigned after %ds", self.HOST_ASSIGN_TIMEOUT)
        return DelayedHostname(route, self.STABILIZE_SECONDS)
