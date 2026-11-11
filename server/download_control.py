"""Control one download subprocess group without touching other tasks."""

import os
import signal
import subprocess
import threading
import time
from contextlib import contextmanager


class DownloadCancelled(Exception):
    pass


class DownloadControl:
    pause_supported = os.name == "posix"

    def __init__(self):
        self.lock = threading.RLock()
        self.changed = threading.Condition(self.lock)
        self.paused = False
        self.cancelled = False
        self.finished = False
        self.process = None

    def _signal(self, sig):
        if self.process is not None and self.process.poll() is None:
            try:
                os.killpg(self.process.pid, sig)
            except ProcessLookupError:
                pass

    def pause(self):
        with self.lock:
            if not self.pause_supported:
                raise ValueError("当前服务器系统不支持暂停，请使用取消；Linux Docker 支持暂停和继续")
            if self.finished or self.cancelled:
                raise ValueError("这个任务已结束")
            self._signal(signal.SIGSTOP)
            self.paused = True

    def resume(self):
        with self.lock:
            if self.finished or self.cancelled:
                raise ValueError("这个任务已结束")
            if self.paused:
                self._signal(signal.SIGCONT)
            self.paused = False
            self.changed.notify_all()

    def cancel(self):
        with self.lock:
            if self.finished:
                return
            self.cancelled = True
            if self.process is not None and self.process.poll() is None:
                if self.pause_supported:
                    self._signal(signal.SIGCONT)
                    self._signal(signal.SIGTERM)
                else:
                    self.process.terminate()
            self.paused = False
            self.changed.notify_all()

    def checkpoint(self):
        with self.changed:
            while self.paused and not self.cancelled:
                self.changed.wait()
            if self.cancelled:
                raise DownloadCancelled()

    @contextmanager
    def completing(self):
        # Publication and cancellation cannot race: completed files are kept.
        with self.lock:
            self.checkpoint()
            yield
            self.finished = True

    def run(self, cmd, timeout, **kwargs):
        self.checkpoint()
        with self.lock:
            if self.cancelled:
                raise DownloadCancelled()
            process = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                       start_new_session=self.pause_supported, **kwargs)
            self.process = process
            if self.paused:
                self._signal(signal.SIGSTOP)
        active = 0.0
        last = time.monotonic()
        try:
            while True:
                try:
                    stdout, stderr = process.communicate(timeout=0.2)
                    with self.lock:
                        if self.cancelled:
                            raise DownloadCancelled()
                    return subprocess.CompletedProcess(cmd, process.returncode, stdout, stderr)
                except subprocess.TimeoutExpired:
                    now = time.monotonic()
                    with self.lock:
                        if not self.paused:
                            active += now - last
                        cancelled = self.cancelled
                    last = now
                    if cancelled:
                        raise DownloadCancelled()
                    if active > timeout:
                        raise subprocess.TimeoutExpired(cmd, timeout)
        finally:
            with self.lock:
                if process.poll() is None:
                    if self.pause_supported:
                        self._signal(signal.SIGCONT)
                        self._signal(signal.SIGKILL)
                    else:
                        process.kill()
                process.communicate()
                self.process = None
