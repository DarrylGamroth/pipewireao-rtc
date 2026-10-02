"""Offline checks for the installed property-control qualification harness."""

import copy
import json
from pathlib import Path
import tempfile
import struct
from types import SimpleNamespace
import unittest
from unittest.mock import Mock

import check_properties
import deploy


class PropertyCheckTests(unittest.TestCase):
    def checker(self):
        checker = check_properties.PropertyCheck.__new__(check_properties.PropertyCheck)
        checker.args = SimpleNamespace(node="science", gain=-0.3, pole=0.99, timeout=8)
        checker.runner = SimpleNamespace(socket=Path("unused"))
        checker.graph = "test-graph"
        checker.phase = "preparation"
        checker.evidence = {"commands": [], "checks": {}}
        checker.properties = Mock(return_value={
            f"science:{name}": {"type": "float", "bits": struct.unpack("=I", struct.pack("=f", value))[0]}
            for name, value in (("gain", checker.args.gain), ("pole", checker.args.pole))})
        return checker

    def test_loop_override_changes_only_rendered_fits_source(self):
        original = {"sources": [{"factory": "api.fits.source", "args": {"api.fits.loop": False}},
                                {"factory": "pipewireao.runtime-parameter", "args": {}}],
                    "graphs": [{"name": "scientific-graph"}]}
        with tempfile.TemporaryDirectory() as directory:
            installed, rendered = Path(directory) / "installed", Path(directory) / "rendered"
            installed.write_text(json.dumps(original))
            rendered.write_text(installed.read_text())
            record = check_properties.enable_looping_source(rendered)
            changed = copy.deepcopy(original)
            changed["sources"][0]["args"]["api.fits.loop"] = True
            self.assertEqual(json.loads(rendered.read_text()), changed)
            self.assertEqual(json.loads(installed.read_text()), original)
            self.assertEqual(record["installed_value"], False)
            self.assertEqual(record["rendered_session_sha256"], deploy.digest(rendered))

    def test_loop_override_rejects_ambiguous_source_without_writing(self):
        for sources in ([], [{"factory": "api.fits.source", "args": {}}] * 2):
            with self.subTest(sources=sources), tempfile.TemporaryDirectory() as directory:
                path = Path(directory) / "session"
                text = json.dumps({"sources": sources})
                path.write_text(text)
                with self.assertRaisesRegex(deploy.DeploymentError, "exactly one"):
                    check_properties.enable_looping_source(path)
                self.assertEqual(path.read_text(), text)

    def test_transport_timeout_is_not_operator_rejection_evidence(self):
        checker = self.checker()
        checker.client = Mock(side_effect=deploy.DeploymentError("control timed out; mutation outcome may be unknown"))
        with self.assertRaisesRegex(deploy.DeploymentError, "transport failure cannot establish"):
            checker.reject(["property"], "Ready")

    def test_operator_rejection_must_preserve_expected_state_and_diagnostic(self):
        checker = self.checker()
        for state, diagnostic in (("Fault", "pending"), ("Ready", "unexpected")):
            checker.client = Mock(side_effect=[deploy.DeploymentError("control rejected: already pending"),
                                               {"state": state, "result": {}}])
            with self.subTest(state=state), self.assertRaises(deploy.DeploymentError):
                checker.reject(["parameter"], "Ready", diagnostic=diagnostic)
        checker.client = Mock(side_effect=[deploy.DeploymentError("control rejected: already pending"),
                                           {"state": "Ready", "result": {"discarded_buffers": 0}}])
        rejection = checker.reject(["parameter"], "Ready", diagnostic="already pending")
        self.assertEqual(rejection["status"]["result"]["discarded_buffers"], 0)

    def test_accepted_invalid_request_cannot_pass_qualification(self):
        checker = self.checker()
        checker.client = Mock(return_value={"state": "Ready", "result": {}})
        with self.assertRaisesRegex(deploy.DeploymentError, "invalid request was accepted"):
            checker.reject(["property"], "Ready")

    def test_healthy_state_does_not_hide_changed_properties_or_generations(self):
        for field in ("properties", "generation"):
            checker = self.checker()
            checker.reject = Mock(return_value={"status": {"state": "Running"}})
            checker.generation = Mock(return_value={"requested": 1, "active": 1})
            if field == "properties":
                before = checker.properties.return_value
                after = copy.deepcopy(before)
                after["science:gain"]["bits"] = 0
                checker.properties.side_effect = [before, after]
            else:
                checker.generation.side_effect = [{"requested": 1, "active": 1}, {"requested": 2, "active": 2}]
            with self.subTest(field=field), self.assertRaisesRegex(deploy.DeploymentError, "changed"):
                checker.invalid("Running")

    def test_unrelated_parameter_publication_is_not_a_scalar_mutation(self):
        checker = self.checker()
        checker.reject = Mock(return_value={"status": {"state": "Running"}})
        checker.generation = Mock(return_value={"requested": 1, "active": 1})
        before = checker.properties.return_value
        before["reconstruct:active-parameter-sequence"] = {"type": "long", "value": 1}
        after = copy.deepcopy(before)
        after["reconstruct:active-parameter-sequence"]["value"] = 2
        checker.properties.side_effect = [before] + [after] * 7
        checker.invalid("Running")
        self.assertEqual(len(checker.evidence["checks"]["invalid_running"]), 7)

    def test_stale_equal_generation_cannot_certify_running_transaction(self):
        checker = self.checker()
        checker.generation = Mock(return_value={"requested": 3, "active": 3})
        checker.request = Mock(return_value={"state": "Running", "result": {
            "outcome": "active", "active_adoption_observed": True}})
        with self.assertRaisesRegex(deploy.DeploymentError, "did not advance"):
            checker.transaction("Running")
        checker.generation.side_effect = [{"requested": 3, "active": 3}, {"requested": 4, "active": 4}]
        self.assertEqual(checker.transaction("Running")["after"]["active"], 4)

    def test_stopped_transaction_cannot_claim_active_adoption(self):
        checker = self.checker()
        checker.generation = Mock(return_value={"requested": 3, "active": 3})
        checker.request = Mock(return_value={"state": "Ready", "result": {
            "outcome": "submitted", "active_adoption_observed": False}})
        self.assertEqual(checker.transaction("Ready")["after"]["active"], 3)
        checker.request.return_value["result"]["active_adoption_observed"] = True
        with self.assertRaisesRegex(deploy.DeploymentError, "incorrect active adoption"):
            checker.transaction("Ready")

    def test_active_generation_does_not_hide_wrong_active_values(self):
        checker = self.checker()
        checker.active_values()
        checker.properties.return_value["science:gain"]["bits"] = 0
        with self.assertRaisesRegex(deploy.DeploymentError, "active gain does not match"):
            checker.active_values()

    def test_pending_rejection_fixture_explicitly_queues_live_update_only_route(self):
        for initial in (False, True):
            checker = self.checker()
            checker.graph = "science"
            checker.parameter = {"name": "matrix", "element-type": "F32_LE",
                                 "shape": [2, 3], "schema": "matrix/1"}
            checker.args.pipewire_prefix = Path("/opt/pipewireao")
            checker.args.fits = Path("/input.fits")
            checker.args.parameter_file = Path("/matrix.f32")
            checker.runner = Mock(package=Path("/package"), runtime=Path("/runtime"),
                                  record={"remote": "private"})
            checker.session = {"parameters": {"science:matrix": "/matrix.f32"} if initial else {}}
            checker.invalid = Mock()
            checker.transaction = Mock()
            checker.reject = Mock(return_value={"status": {"result": {"discarded_buffers": 0}}})
            checker.request = Mock(return_value={"result": {"discarded_buffers": 0}})
            checker.evidence = {"checks": {}}
            with self.subTest(initial=initial):
                checker.prepared_checks()
                calls = [call.args[0][0] for call in checker.request.call_args_list]
                self.assertEqual(calls, ["status"] if initial else ["parameter", "status"])


if __name__ == "__main__":
    unittest.main()
