"""Conftest for rate limit tests"""

import json as _json
import logging
import os as _os
import re as _re
import subprocess
import tempfile as _tempfile

import pytest

from testsuite.kubernetes.envoy_filter import patch_kuadrant_managed_envoyfilters_to_workload_selector

logger = logging.getLogger(__name__)


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


def _fix_ef_denywith_cel(gateway) -> None:  # pylint: disable=too-many-locals,too-many-branches
    """# ppc64le-fix: ef-denywith-fix
    RHCL v1.5 operator generates invalid CEL in the wasm EF:
      body: Too Many Requests\n"!}
    instead of:
      body: "Too Many Requests\n"
    This causes wasm-shim to fail with InvalidDataExpression and refuse to
    load the plugin config (fail-closed → no rate limiting, returns 200 forever).
    Patch the EF on every commit so the wasm-shim can compile the config.
    """
    gateway_name = gateway.name()
    ef_name = f"kuadrant-{gateway_name}"

    try:  # pylint: disable=too-many-nested-blocks
        result = run_oc(
            "get",
            "envoyfilter",
            ef_name,
            "-n",
            gateway.namespace,
            "-o",
            "json",
            check=False,
        )
        if result.returncode != 0:
            logger.debug("EF %s not found (may not be created yet)", ef_name)
            return

        ef = _json.loads(result.stdout)
        patches_list = ef.get("spec", {}).get("configPatches", [])
        changed = False

        for p in patches_list:
            cfg_path = (
                p.get("patch", {})
                .get("value", {})
                .get("typed_config", {})
                .get("value", {})
                .get("config", {})
                .get("configuration", {})
            )
            if not cfg_path:
                continue
            cfg_val = cfg_path.get("value", "")
            if not cfg_val:
                continue
            try:
                cfg_inner = _json.loads(cfg_val)
            except _json.JSONDecodeError:
                continue

            for as_ in cfg_inner.get("actionSets", []):
                for action in as_.get("actions", []):
                    for reply in action.get("onReply", []):
                        dw = reply.get("denyWith", "")
                        # Detect the broken pattern:
                        # body: Too Many Requests\n"!}   (backslash + n + " + ! + })
                        if "Too Many Requests" in dw and dw.endswith('\\n"!}'):
                            fixed = dw[: -len('\\n"!}')].rstrip()
                            # Trim trailing "body: " literal content
                            fixed = _re.sub(r",\s*body:.*$", "", fixed) + ', body: "Too Many Requests\n"}'
                            reply["denyWith"] = fixed
                            changed = True
                            logger.info("Fixed EF %s denyWith CEL body expression", ef_name)
                        elif "Too Many Requests" in dw and '"Too Many' not in dw:
                            # Fallback: replace anything after "body: " up to the closing }
                            fixed_dw = _re.sub(
                                r"(body:\s*)Too Many Requests[^}]*\}$",
                                r'\1"Too Many Requests\n"}',
                                dw,
                            )
                            if fixed_dw != dw:
                                reply["denyWith"] = fixed_dw
                                changed = True
                                logger.info("Fixed EF %s denyWith CEL (fallback)", ef_name)

            if changed:
                cfg_path["value"] = _json.dumps(cfg_inner, separators=(",", ":"))

        if not changed:
            logger.debug("EF %s denyWith looks OK — no CEL fix needed", ef_name)
            return

        patched_json = _json.dumps(ef)
        # Write to a temp file and apply
        with _tempfile.NamedTemporaryFile(mode="w", suffix=".json", delete=False) as tf:
            tf.write(patched_json)
            tf_name = tf.name
        try:
            run_oc("apply", "-f", tf_name)
            logger.info("Applied CEL fix to EF %s", ef_name)
        finally:
            _os.unlink(tf_name)
    except Exception as exc:  # pylint: disable=broad-exception-caught
        logger.warning("EF denyWith CEL fix failed for %s: %s", ef_name, exc)


@pytest.fixture(scope="session")
def limitador(kuadrant):
    """Returns Limitador CR."""

    return kuadrant.limitador


@pytest.fixture(scope="module", autouse=True)
def commit(request, rate_limit, gateway):
    """Commits all important stuff before tests"""
    request.addfinalizer(rate_limit.delete)
    rate_limit.commit()
    rate_limit.wait_for_ready()
    _fix_ef_denywith_cel(gateway)
    patch_kuadrant_managed_envoyfilters_to_workload_selector(gateway.cluster, gateway)
