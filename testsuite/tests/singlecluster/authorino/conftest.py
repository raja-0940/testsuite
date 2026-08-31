"""Conftest for Authorino tests"""

import logging

import backoff
import pytest

from testsuite.httpx.auth import HttpxOidcClientAuth
from testsuite.kuadrant.authorino import AuthorinoCR, PreexistingAuthorino
from testsuite.kuadrant.policy.authorization.auth_config import AuthConfig

LOGGER = logging.getLogger(__name__)


from testsuite.utils.constants import AUTH_DATAPLANE_READY_INTERVAL, AUTH_DATAPLANE_READY_TIMEOUT


@pytest.fixture(scope="session")
def authorino(kuadrant, cluster, blame, request, testconfig, label):
    """Authorino instance"""
    if kuadrant:
        return kuadrant.authorino

    authorino_config = testconfig["service_protection"]["authorino"]
    if not authorino_config["deploy"]:
        return PreexistingAuthorino(
            authorino_config["auth_url"],
            authorino_config["oidc_url"],
            authorino_config["metrics_service_name"],
        )

    authorino = AuthorinoCR.create_instance(
        cluster,
        image=authorino_config.get("image"),
        log_level=authorino_config.get("log_level"),
        name=blame("authorino"),
        label_selectors=[f"testRun={label}"],
    )
    request.addfinalizer(authorino.delete)
    authorino.commit()
    authorino.wait_for_ready()
    return authorino


@pytest.fixture(scope="module")
def authorization(authorization, oidc_provider, route, authorization_name, cluster, label) -> AuthConfig:
    """In case of Authorino, AuthConfig used for authorization"""
    if authorization is None:
        authorization = AuthConfig.create_instance(cluster, authorization_name, route, labels={"testRun": label})
    authorization.identity.add_oidc("default", oidc_provider.well_known["issuer"])
    return authorization


@pytest.fixture(scope="module")
def auth(oidc_provider):
    """Returns authentication object for HTTPX"""
    return HttpxOidcClientAuth(oidc_provider.get_token, "authorization")


@pytest.fixture(scope="module", autouse=True)
def commit(request, authorization):
    """Commits all important stuff before tests"""
    request.addfinalizer(authorization.delete)
    authorization.commit()
    authorization.wait_for_ready()


@pytest.fixture(scope="module")
def wait_for_unauthenticated_denial():
    """
    Whether module setup should poll for unauthenticated /get denial (401/403)
    as a dataplane-readiness signal. Override to False in modules where that
    signal is wrong (e.g. mTLS frontend validation, path-conditional AuthPolicies).
    """
    return True


def _auth_dataplane_ready(response) -> bool:
    """True when Authorino is active on the request path."""
    if response.status_code in (401, 403):
        return True
    if response.status_code != 200:
        return False
    try:
        headers = response.json().get("headers", {})
    except Exception:  # pylint: disable=broad-exception-caught
        return False
    return any(name.lower() == "simple" for name in headers)


@pytest.fixture(scope="module", autouse=True)
def wait_for_auth_dataplane(commit, client, wait_for_unauthenticated_denial):  # pylint: disable=unused-argument
    """
    # ppc64le-fix: auth-dataplane
    Best-effort wait until Authorino is enforcing on the gateway dataplane.
    AuthPolicy Enforced / first HTTP 200 after wasm 503s is not enough: traffic
    can be fail-opened while the wasm filter is still loading. Retry an
    unauthenticated request until identity denial (401/403) or an Authorino
    'simple' response header appears.
    """
    if not wait_for_unauthenticated_denial:
        return

    @backoff.on_predicate(
        backoff.constant,
        lambda ready: not ready,
        interval=AUTH_DATAPLANE_READY_INTERVAL,
        max_time=AUTH_DATAPLANE_READY_TIMEOUT,
        jitter=None,
    )
    def _wait():
        try:
            return _auth_dataplane_ready(client.get("/get"))
        except Exception:  # pylint: disable=broad-exception-caught
            return False

    if not _wait():
        LOGGER.warning(
            "Authorino dataplane readiness signal not observed within %ss; continuing",
            AUTH_DATAPLANE_READY_TIMEOUT,
        )
