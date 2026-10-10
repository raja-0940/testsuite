"""Test for AuthPolicy attached directly to gateway"""

import pytest

pytestmark = [pytest.mark.authorino, pytest.mark.kuadrant_only]


@pytest.fixture(scope="module")
def rate_limit():
    """Basic gateway test doesn't utilize RateLimitPolicy component"""
    return None


@pytest.mark.issue("https://github.com/Kuadrant/kuadrant-operator/pull/287")
def test_authpolicy_attached_gateway(client, auth):
    """Test if AuthPolicy attached directly to gateway works"""
    response = client.get("/get", auth=auth)
    assert response.status_code == 200

    import time

    deadline = time.time() + 60
    response = client.get("/get")
    # ppc64le-fix: gateway
    while response.status_code != 401 and time.time() < deadline:
        time.sleep(1)
        response = client.get("/get")
    assert response.status_code == 401
