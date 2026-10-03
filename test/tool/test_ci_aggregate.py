import json
import contextlib
import io
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tool"))
import ci_aggregate  # noqa: E402


def plan(**overrides):
    value = {name: False for name in ci_aggregate.FLAGS}
    value["reason"] = "test route"
    value.update(overrides)
    return value


def successes(**overrides):
    value = {"plan": "success", "common-checks": "success", "swift-policy": "success"}
    value.update(overrides)
    return value


class CiAggregateTest(unittest.TestCase):
    def test_full_freeze_requires_every_matrix_job(self):
        full = plan(full=True, android_source=True, ios_source=True, renamed_android=True, renamed_ios=True, qr_android=True, qr_ios=True)
        required = ci_aggregate.required_jobs({key: full[key] for key in ci_aggregate.FLAGS}, True)
        self.assertEqual({"plan", "common-checks", "swift-policy", "android-source", "renamed-copy", "ios-simulator", "qr-opt-in-ios"}, required)
        result = ci_aggregate.evaluate(full, successes(**{job: "success" for job in required}), True)
        self.assertTrue(result["success"], result)

    def test_docs_fast_requires_only_always_jobs(self):
        result = ci_aggregate.evaluate(plan(), successes(**{"android-source": "skipped", "renamed-copy": "skipped", "ios-simulator": "skipped", "qr-opt-in-ios": "skipped"}), True)
        self.assertTrue(result["success"], result)
        self.assertEqual(["common-checks", "plan", "swift-policy"], result["required"])

    def test_android_ios_and_qr_routes_require_exact_jobs(self):
        android = plan(android_source=True, renamed_android=True, qr_android=True)
        android_results = successes(**{"android-source": "success", "renamed-copy": "success"})
        self.assertTrue(ci_aggregate.evaluate(android, android_results, True)["success"])
        ios = plan(ios_source=True, renamed_ios=True)
        self.assertTrue(ci_aggregate.evaluate(ios, successes(**{"ios-simulator": "success"}), True)["success"])
        qr = plan(qr_android=True, qr_ios=True)
        qr_jobs = successes(**{"android-source": "success", "renamed-copy": "success", "qr-opt-in-ios": "success"})
        self.assertTrue(ci_aggregate.evaluate(qr, qr_jobs, True)["success"])
        self.assertTrue(ci_aggregate.evaluate(plan(qr_ios=True), successes(**{"qr-opt-in-ios": "success"}), False)["success"])

    def test_selected_skipped_and_missing_jobs_fail(self):
        route = plan(android_source=True)
        skipped = ci_aggregate.evaluate(route, successes(**{"android-source": "skipped"}), True)
        self.assertFalse(skipped["success"])
        missing = ci_aggregate.evaluate(route, successes(), True)
        self.assertFalse(missing["success"])
        self.assertIn("missing required job result: android-source", missing["failures"])

    def test_common_swift_and_plan_failures_are_never_masked(self):
        for job in ("plan", "common-checks", "swift-policy"):
            results = successes(**{job: "failure"})
            self.assertFalse(ci_aggregate.evaluate(plan(), results, True)["success"], job)

    def test_unselected_failures_and_cancellation_are_not_masked(self):
        for status in ("failure", "cancelled", "timed_out", "startup_failure"):
            with self.subTest(status=status):
                results = successes(**{"android-source": status})
                self.assertFalse(ci_aggregate.evaluate(plan(), results, True)["success"])
        for status in ("success", "skipped"):
            self.assertTrue(ci_aggregate.evaluate(plan(), successes(**{"android-source": status}), True)["success"])

    def test_non_template_does_not_require_renamed_jobs(self):
        route = plan(android_source=True, renamed_android=True, ios_source=True, renamed_ios=True)
        result = ci_aggregate.evaluate(route, successes(**{"android-source": "success", "ios-simulator": "success"}), False)
        self.assertTrue(result["success"], result)
        self.assertNotIn("renamed-copy", result["required"])

    def test_flags_schema_identity_and_results_are_strict(self):
        malformed = plan(android_source=1)
        self.assertFalse(ci_aggregate.evaluate(malformed, successes(), True)["success"])
        self.assertFalse(ci_aggregate.evaluate({**plan(), "extra": False}, successes(), True)["success"])
        self.assertFalse(ci_aggregate.evaluate(plan(full=True), successes(), True)["success"])
        self.assertFalse(ci_aggregate.evaluate(plan(), {"common-checks": []}, True)["success"])
        self.assertFalse(ci_aggregate.evaluate(plan(), successes(**{"future-job": "success"}), True)["success"])

    def test_duplicate_json_keys_fail_closed(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "duplicate.json"
            path.write_text('{"plan":"success","plan":"failure"}')
            with self.assertRaises(ValueError):
                ci_aggregate._read_json(str(path))

    def test_cli_requires_literal_template_boolean_and_reports_json(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            plan_file, results_file = path / "plan.json", path / "results.json"
            plan_file.write_text(json.dumps(plan()))
            results_file.write_text(json.dumps(successes()))
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(0, ci_aggregate.main(["--plan-file", str(plan_file), "--results-file", str(results_file), "--is-template", "false"]))
            with contextlib.redirect_stderr(io.StringIO()):
                with self.assertRaises(SystemExit):
                    ci_aggregate.main(["--plan-file", str(plan_file), "--results-file", str(results_file), "--is-template", "TRUE"])


if __name__ == "__main__":
    unittest.main()
