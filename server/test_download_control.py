import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import time
import unittest

from download_control import DownloadCancelled, DownloadControl


class DownloadControlTests(unittest.TestCase):
    def test_cancel_before_start_never_launches_process(self):
        control = DownloadControl()
        control.cancel()
        with self.assertRaises(DownloadCancelled):
            control.run([sys.executable, "-c", "raise AssertionError()"], timeout=1)

    def test_cancellation_after_completion_preserves_result(self):
        control = DownloadControl()
        with control.completing():
            pass
        control.cancel()
        self.assertFalse(control.cancelled)
        self.assertTrue(control.finished)

    @unittest.skipUnless(os.name == "posix", "Linux process group signals")
    def test_pause_resume_and_cancel_real_process_without_affecting_other_task(self):
        with tempfile.TemporaryDirectory() as tmp:
            paths = [Path(tmp) / str(i) for i in range(2)]
            controls = [DownloadControl(), DownloadControl()]
            errors = []
            code = "import pathlib,sys,time\np=pathlib.Path(sys.argv[1])\nwhile True:\n with p.open('ab') as f:f.write(b'x')\n time.sleep(.02)"
            def run(i):
                try:
                    controls[i].run([sys.executable, "-c", code, str(paths[i])], timeout=10)
                except DownloadCancelled:
                    errors.append(i)
            threads = [threading.Thread(target=run, args=(i,)) for i in range(2)]
            for thread in threads:
                thread.start()
            try:
                deadline = time.monotonic() + 3
                while not all(p.exists() and p.stat().st_size > 2 for p in paths):
                    if time.monotonic() > deadline:
                        self.fail("child processes never started")
                    time.sleep(.02)
                controls[0].pause()
                time.sleep(.1)
                sizes = [p.stat().st_size for p in paths]
                time.sleep(.25)
                self.assertEqual(paths[0].stat().st_size, sizes[0])
                self.assertGreater(paths[1].stat().st_size, sizes[1])
                controls[0].resume()
                time.sleep(.15)
                self.assertGreater(paths[0].stat().st_size, sizes[0])
                controls[0].pause()
                controls[0].cancel()
                threads[0].join(3)
                self.assertFalse(threads[0].is_alive())
                self.assertIsNone(controls[0].process)
                self.assertTrue(threads[1].is_alive())
            finally:
                for control in controls:
                    control.cancel()
                for thread in threads:
                    thread.join(3)
            self.assertCountEqual(errors, [0, 1])

    @unittest.skipUnless(os.name == "posix", "Linux process group signals")
    def test_paused_time_does_not_consume_execution_timeout(self):
        control = DownloadControl()
        results = []
        def run():
            try:
                results.append(control.run([sys.executable, "-c", "import time;time.sleep(.5);print('done')"],
                                           timeout=.8, text=True))
            except Exception as exc:
                results.append(exc)
        thread = threading.Thread(target=run)
        thread.start()
        deadline = time.monotonic() + 2
        while control.process is None and time.monotonic() < deadline:
            time.sleep(.01)
        try:
            control.pause()
            time.sleep(1.1)
            control.resume()
            thread.join(3)
            self.assertEqual(len(results), 1)
            self.assertIsInstance(results[0], subprocess.CompletedProcess)
            self.assertEqual(results[0].returncode, 0)
            self.assertIn("done", results[0].stdout)
        finally:
            control.cancel()
            thread.join(3)


if __name__ == "__main__":
    unittest.main()
