#!/usr/bin/env python3
"""Fail-closed final job-result aggregation for impact-routed CI."""

from __future__ import annotations

import argparse
import json
import sys


FLAGS = (
    "full",
    "android_source",
    "ios_source",
    "renamed_android",
    "renamed_ios",
    "qr_android",
    "qr_ios",
)
PLAN_KEYS = {*FLAGS, "reason"}
SAFE_RESULTS = {
    "success",
    "failure",
    "cancelled",
    "skipped",
    "timed_out",
    "action_required",
    "neutral",
    "stale",
    "startup_failure",
    "unknown",
}
JOB_IDS = {"plan", "common-checks", "swift-policy", "android-source", "renamed-copy", "ios-simulator", "qr-opt-in-ios"}


def _validated_plan(plan: object) -> tuple[dict[str, bool] | None, str | None]:
    if not isinstance(plan, dict) or set(plan) != PLAN_KEYS:
        return None, "plan must contain exactly seven route flags and reason"
    flags: dict[str, bool] = {}
    for name in FLAGS:
        value = plan[name]
        if type(value) is not bool:
            return None, f"plan flag {name} is not a boolean"
        flags[name] = value
    if not isinstance(plan["reason"], str) or not plan["reason"].strip():
        return None, "plan reason must be a nonempty string"
    if flags["full"] and not all(flags[name] for name in FLAGS if name != "full"):
        return None, "full plan must enable every route"
    return flags, None


def required_jobs(flags: dict[str, bool], is_template: bool) -> set[str]:
    required = {"plan", "common-checks", "swift-policy"}
    if flags["android_source"] or flags["qr_android"]:
        required.add("android-source")
    if is_template and (flags["renamed_android"] or flags["qr_android"]):
        required.add("renamed-copy")
    if flags["ios_source"] or (is_template and flags["renamed_ios"]):
        required.add("ios-simulator")
    if flags["qr_ios"]:
        required.add("qr-opt-in-ios")
    return required


def evaluate(plan: object, results: object, is_template: bool) -> dict[str, object]:
    """Return a stable JSON-safe summary; failures never become success by skipping."""
    if type(is_template) is not bool:
        message = "template identity must be a boolean"
        return {"success": False, "reason": message, "required": [], "failures": [message]}
    flags, plan_error = _validated_plan(plan)
    if plan_error:
        return {"success": False, "reason": plan_error, "required": [], "failures": [plan_error]}
    if not isinstance(results, dict):
        message = "results must be a job-id to GitHub-result object"
        return {"success": False, "reason": message, "required": [], "failures": [message]}
    failures: list[str] = []
    for job, value in results.items():
        if not isinstance(job, str) or job not in JOB_IDS:
            failures.append("unrecognized result job id")
        elif not isinstance(value, str) or value not in SAFE_RESULTS:
            failures.append(f"invalid GitHub result for {job}")
    required = required_jobs(flags, is_template)
    for job in sorted(required):
        if job not in results:
            failures.append(f"missing required job result: {job}")
        elif results[job] != "success":
            result = results[job]
            failures.append(f"required job {job} result is {result}" if isinstance(result, str) and result in SAFE_RESULTS else f"required job {job} result is invalid")
    for job, result in results.items():
        if job in JOB_IDS and job not in required and (not isinstance(result, str) or result not in {"success", "skipped"}):
            failures.append(f"unselected job {job} result is {result}" if isinstance(result, str) and result in SAFE_RESULTS else f"unselected job {job} result is invalid")
    return {
        "success": not failures,
        "reason": "all required jobs succeeded" if not failures else "CI job results failed closed",
        "required": sorted(required),
        "failures": failures,
    }


def _read_json(path: str) -> object:
    with open(path, "r", encoding="utf-8") as stream:
        return json.load(stream, object_pairs_hook=_unique_object)


def _unique_object(pairs: list[tuple[str, object]]) -> dict[str, object]:
    result: dict[str, object] = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate JSON key")
        result[key] = value
    return result


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--plan-file", required=True)
    parser.add_argument("--results-file", required=True)
    parser.add_argument("--is-template", required=True, choices=("true", "false"))
    args = parser.parse_args(argv)
    try:
        summary = evaluate(_read_json(args.plan_file), _read_json(args.results_file), args.is_template == "true")
    except (OSError, json.JSONDecodeError, UnicodeError, ValueError):
        summary = {"success": False, "reason": "plan or results JSON unavailable/invalid", "required": [], "failures": ["plan or results JSON unavailable/invalid"]}
    print(json.dumps(summary, ensure_ascii=True, separators=(",", ":")))
    return 0 if summary["success"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
