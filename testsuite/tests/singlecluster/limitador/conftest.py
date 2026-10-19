"""Conftest for rate limit tests"""

import logging
import os
import subprocess
import time
from pathlib import Path

import pytest

from testsuite.kubernetes.envoy_filter import (
    create_native_ratelimit_workaround,
    patch_kuadrant_managed_envoyfilters_to_workload_selector,
)


logger = logging.getLogger(__name__)


ADMISSION_POLICY_NAME = "block-kuadrant-wasm-envoyfilters"

ADMISSION_POLICY_FILE = (
    Path(__file__).resolve().parents[4]
    / "block-kuadrant-wasm-envoyfilters.yaml"
)


def run_oc(*arguments: str, check: bool = True):
    """Run an oc command and return the completed process."""

    command = ["oc", *arguments]

    logger.info(
        "Running command: %s",
        " ".join(command),
    )

    result = subprocess.run(
        command,
        check=False,
        text=True,
        capture_output=True,
    )

    if check and result.returncode != 0:
        raise RuntimeError(
            f"Command failed: {' '.join(command)}\n"
            f"Exit status: {result.returncode}\n"
            f"stdout: {result.stdout}\n"
            f"stderr: {result.stderr}"
        )

    return result


def remove_rlp_admission_policy():
    """Remove the temporary ppc64le admission workaround."""

    logger.info(
        "Removing temporary RLP admission policy %s",
        ADMISSION_POLICY_NAME,
    )

    run_oc(
        "delete",
        "validatingadmissionpolicybinding",
        ADMISSION_POLICY_NAME,
        "--ignore-not-found",
        check=False,
    )

    run_oc(
        "delete",
        "validatingadmissionpolicy",
        ADMISSION_POLICY_NAME,
        "--ignore-not-found",
        check=False,
    )


def install_rlp_admission_policy():
    """Install and verify the temporary ppc64le admission workaround."""

    if not ADMISSION_POLICY_FILE.is_file():
        raise RuntimeError(
            "Admission-policy manifest does not exist: "
            f"{ADMISSION_POLICY_FILE}"
        )

    remove_rlp_admission_policy()

    logger.info(
        "Installing temporary RLP admission policy from %s",
        ADMISSION_POLICY_FILE,
    )

    result = run_oc(
        "apply",
        "-f",
        str(ADMISSION_POLICY_FILE),
    )

    logger.info(
        "Admission-policy apply output: %s",
        result.stdout.strip(),
    )

    time.sleep(10)

    binding = run_oc(
        "get",
        "validatingadmissionpolicybinding",
        ADMISSION_POLICY_NAME,
        "-o",
        (
            "jsonpath=policy={.spec.policyName} "
            "action={.spec.validationActions[0]} "
            "namespace={.spec.matchResources.namespaceSelector."
            "matchLabels.kubernetes\\.io/metadata\\.name}"
        ),
    )

    expected = (
        f"policy={ADMISSION_POLICY_NAME} "
        "action=Deny namespace=kuadrant"
    )

    actual = binding.stdout.strip()

    if actual != expected:
        raise RuntimeError(
            "Admission-policy binding validation failed. "
            f"Expected: {expected}. Actual: {actual}"
        )

    logger.info(
        "Temporary RLP admission policy is active: %s",
        actual,
    )


@pytest.fixture(scope="session")
def limitador(kuadrant):
    """Returns Limitador CR."""

    return kuadrant.limitador


@pytest.fixture(scope="module", autouse=True)
def commit(
    request,
    rate_limit,
    gateway,
    route,
    hostname,
    limitador,
):
    """Commit the RLP and configure the temporary ppc64le workaround."""

    workaround_enabled = (
        os.environ.get("PPC64LE_NATIVE_RLP_WORKAROUND", "false")
        .strip()
        .lower()
        == "true"
    )

    if workaround_enabled:
        install_rlp_admission_policy()

        # Registered first, so it runs last during teardown.
        request.addfinalizer(remove_rlp_admission_policy)

    # Registered second, so the RLP is deleted before policy removal.
    request.addfinalizer(rate_limit.delete)

    rate_limit.commit()

    if not workaround_enabled:
        rate_limit.wait_for_ready()
        patch_kuadrant_managed_envoyfilters_to_workload_selector(
            gateway.cluster,
            gateway,
        )
        return

    accepted = rate_limit.wait_until(
        lambda policy: any(
            condition.type == "Accepted"
            and condition.status == "True"
            for condition in policy.model.status.conditions
        ),
        timelimit=90,
    )

    assert accepted, (
        "RateLimitPolicy did not reach Accepted=True before applying "
        "the ppc64le native RLP workaround"
    )

    patch_kuadrant_managed_envoyfilters_to_workload_selector(
        gateway.cluster,
        gateway,
    )

    native_filter = create_native_ratelimit_workaround(
        cluster=gateway.cluster,
        gateway=gateway,
        route=route,
        rate_limit=rate_limit,
        limitador=limitador,
    )

    request.addfinalizer(native_filter.delete)

    logger.info(
        "Sending warm-up request before starting the RLP test"
    )

    warmup_client = hostname.client()

    try:
        warmup_result = warmup_client.get("/get")

        logger.info(
            "Warm-up request completed with status=%s error=%s",
            warmup_result.status_code,
            getattr(warmup_result, "error", None),
        )
    finally:
        warmup_client.close()

    logger.info(
        "Waiting 16 seconds for a clean Limitador window"
    )

    time.sleep(16)
