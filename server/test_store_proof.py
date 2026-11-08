import subprocess
import threading
import unittest
from unittest.mock import patch

from store_proof import StoreProofError, StoreProofSetup


class StoreProofSetupTests(unittest.TestCase):
    def setUp(self):
        self.setup = StoreProofSetup()
        self.env = {"IPATOOL_STORE_PROOF_HELPER": "/usr/local/bin/ipatool-store-proof"}

    @patch("store_proof.subprocess.run")
    def test_old_installation_never_invokes_helper(self, run):
        self.setup.ensure({})
        run.assert_not_called()

    @patch("store_proof.subprocess.run")
    def test_concurrent_requests_initialize_once(self, run):
        run.return_value.returncode = 0
        errors = []
        def invoke():
            try:
                self.setup.ensure(self.env)
            except Exception as exc:
                errors.append(exc)
        threads = [threading.Thread(target=invoke) for _ in range(8)]
        for thread in threads:
            thread.start()
        for thread in threads:
            thread.join()
        self.assertEqual(errors, [])
        run.assert_called_once_with(
            [self.env["IPATOOL_STORE_PROOF_HELPER"], "--setup"],
            env=self.env, capture_output=True, timeout=330, check=False,
        )

    @patch("store_proof.subprocess.run")
    def test_failure_does_not_leak_output_and_can_retry(self, run):
        run.return_value = subprocess.CompletedProcess([], 1, b"private-proof", b"private-identity")
        with self.assertRaises(StoreProofError) as caught:
            self.setup.ensure(self.env)
        self.assertNotIn("private", str(caught.exception))
        run.return_value.returncode = 0
        self.setup.ensure(self.env)
        self.assertEqual(run.call_count, 2)

    @patch("store_proof.subprocess.run", side_effect=subprocess.TimeoutExpired("helper", 330))
    def test_timeout_is_actionable(self, run):
        with self.assertRaisesRegex(StoreProofError, "超时"):
            self.setup.ensure(self.env)


if __name__ == "__main__":
    unittest.main()
