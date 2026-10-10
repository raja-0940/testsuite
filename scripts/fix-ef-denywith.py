#!/usr/bin/env python3
"""
ppc64le workaround: continuously watch and fix the broken DenyResponse body
CEL expression that RHCL v1.5 kuadrant-operator emits on ppc64le.

The operator generates:
  body: Too Many Requests\n"!}   ← invalid CEL (unquoted body, stray chars)
Expected by wasm-shim v0.13.0:
  body: "Too Many Requests\n"    ← quoted CEL string

Without this fix, wasm-shim fails to compile the plugin config and rate-limiting
fails open (every request returns HTTP 200 instead of 429 after limit is hit).

Run in the background: nohup python3 scripts/fix-ef-denywith.py &> /tmp/ef-fix-daemon.log &
"""

import json
import os
import re
import subprocess
import sys
import time

POLL_INTERVAL = 1  # seconds between checks
BROKEN_SUFFIX = '\\n"!}'  # backslash + n + " + ! + }   as Python str


def run(*args, **kwargs):
    return subprocess.run(list(args), capture_output=True, text=True, **kwargs)


def fix_ef_json(ef_json_str):
    """Return (fixed_ef, changed) where changed=True if CEL was repaired."""
    ef = json.loads(ef_json_str)
    patches_list = ef.get("spec", {}).get("configPatches", [])
    changed = False

    for p in patches_list:
        try:
            cfg_section = p["patch"]["value"]["typed_config"]["value"]["config"]["configuration"]
        except (KeyError, TypeError):
            continue
        cfg_val = cfg_section.get("value", "")
        if not cfg_val:
            continue
        try:
            cfg_inner = json.loads(cfg_val)
        except json.JSONDecodeError:
            continue

        for as_ in cfg_inner.get("actionSets", []):
            for action in as_.get("actions", []):
                for reply in action.get("onReply", []):
                    dw = reply.get("denyWith", "")
                    if "Too Many Requests" not in dw:
                        continue
                    if dw.endswith(BROKEN_SUFFIX):
                        base = dw[: -len(BROKEN_SUFFIX)].rstrip()
                        base = re.sub(r",\s*body:\s*Too Many Requests$", "", base)
                        new_dw = base + ', body: "Too Many Requests\\n"}'
                        reply["denyWith"] = new_dw
                        changed = True
                        print(
                            f"[ef-fix] fixed denyWith in {ef['metadata']['namespace']}/" f"{ef['metadata']['name']}",
                            flush=True,
                        )
                    elif '"Too Many' not in dw:
                        # Fallback regex
                        new_dw = re.sub(
                            r"(body:\s*)Too Many Requests[^}]*\}$",
                            r'\1"Too Many Requests\\n"}',
                            dw,
                        )
                        if new_dw != dw:
                            reply["denyWith"] = new_dw
                            changed = True
                            print(
                                f"[ef-fix] fixed denyWith (fallback) in "
                                f"{ef['metadata']['namespace']}/{ef['metadata']['name']}",
                                flush=True,
                            )

        if changed:
            cfg_section["value"] = json.dumps(cfg_inner, separators=(",", ":"))

    return ef, changed


def apply_ef(ef):
    """Patch the EnvoyFilter using oc patch (avoids last-applied-configuration issues)."""
    # Use oc patch with merge-patch so we only update spec
    name = ef["metadata"]["name"]
    ns = ef["metadata"]["namespace"]

    # Get just the configPatches we need to patch
    patch_body = json.dumps({"spec": ef["spec"]})
    r = run(
        "oc",
        "patch",
        "envoyfilter",
        name,
        "-n",
        ns,
        "--type=merge",
        "-p",
        patch_body,
    )
    if r.returncode == 0:
        print(f"[ef-fix] patched {ns}/{name} OK", flush=True)
        return True
    else:
        print(f"[ef-fix] patch {ns}/{name} FAILED: {r.stderr[:200]}", flush=True)
        return False


def check_and_fix_all():
    """Find all broken Kuadrant wasm EnvoyFilters and fix them."""
    r = run("oc", "get", "envoyfilter", "-A", "-l", "kuadrant.io/wasm=true", "-o", "json")
    if r.returncode != 0:
        print(f"[ef-fix] list error: {r.stderr[:100]}", flush=True)
        return 0

    try:
        efs = json.loads(r.stdout)
    except json.JSONDecodeError:
        return 0

    fixed = 0
    for ef in efs.get("items", []):
        ef_str = json.dumps(ef)
        if "Too Many Requests" not in ef_str:
            continue
        fixed_ef, changed = fix_ef_json(ef_str)
        if changed:
            if apply_ef(fixed_ef):
                fixed += 1
    return fixed


print(f"[ef-fix] started — polling every {POLL_INTERVAL}s for broken wasm EFs", flush=True)
print(f"[ef-fix] PID={os.getpid()}", flush=True)

while True:
    try:
        n = check_and_fix_all()
        if n:
            print(f"[ef-fix] fixed {n} EnvoyFilter(s)", flush=True)
    except Exception as exc:  # pylint: disable=broad-exception-caught
        print(f"[ef-fix] error: {exc}", flush=True)
    time.sleep(POLL_INTERVAL)
