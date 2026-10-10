"""
Test for changing targetRef field in RateLimitPolicy
"""

import time

import pytest

from testsuite.kuadrant.policy.rate_limit import Limit, RateLimitPolicy
from testsuite.utils.constants import RLP_WINDOW_RESET_WAIT_BUFFERED

pytestmark = [pytest.mark.dnspolicy, pytest.mark.limitador]

DATAPLANE_TIMEOUT = 180


def _wait_for_rate_limiting(client):
    """ppc64le-fix: rlp-retarget - Gateway "affected by" / RLP Enforced is set before Envoy runs the new wasm config.

    Poll (max DATAPLANE_TIMEOUT s) until the gateway returns 429, then wait for the 10s window to reset so the
    original assertions start from an empty counter. Does not assert: the caller's assertions still decide.
    """
    deadline = time.time() + DATAPLANE_TIMEOUT
    while time.time() < deadline:
        if any(r.status_code == 429 for r in client.get_many("/get", 3)):
            break
        time.sleep(1)
    time.sleep(RLP_WINDOW_RESET_WAIT_BUFFERED + 5)


@pytest.fixture(scope="module")
def rate_limit(cluster, blame, module_label, gateway, route):  # pylint: disable=unused-argument
    """RateLimitPolicy for testing"""
    policy = RateLimitPolicy.create_instance(cluster, blame("limit"), gateway, labels={"testRun": module_label})
    policy.add_limit("basic", [Limit(2, "10s")])
    return policy


@pytest.mark.flaky(reruns=0)
def test_update_ratelimit_policy_target_ref(
    route2, gateway, gateway2, rate_limit, client, client2, dns_policy, dns_policy2, change_target_ref
):  # pylint: disable=unused-argument
    """Test updating the targetRef of a RateLimitPolicy from Gateway 1 to Gateway 2"""
    assert gateway.wait_until(lambda obj: obj.is_affected_by(rate_limit))
    assert gateway2.wait_until(lambda obj: not obj.is_affected_by(rate_limit))

    _wait_for_rate_limiting(client)
    responses = client.get_many("/get", 2)
    responses.assert_all(status_code=200)
    assert client.get("/get").status_code == 429

    responses = client2.get_many("/get", 3)
    responses.assert_all(status_code=200)

    change_target_ref(rate_limit, gateway2)

    assert gateway.wait_until(lambda obj: not obj.is_affected_by(rate_limit))
    assert gateway2.wait_until(lambda obj: obj.is_affected_by(rate_limit))

    _wait_for_rate_limiting(client2)
    responses = client2.get_many("/get", 2)
    responses.assert_all(status_code=200)
    assert client2.get("/get").status_code == 429

    responses = client.get_many("/get", 3)
    responses.assert_all(status_code=200)
