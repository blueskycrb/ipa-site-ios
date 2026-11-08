"""Initialize the optional Linux Store helper, without handling account secrets."""

import os
import subprocess
import threading


class StoreProofError(RuntimeError):
    pass


class StoreProofSetup:
    def __init__(self):
        self._lock = threading.Lock()
        self._ready = False

    def ensure(self, env):
        helper = env.get("IPATOOL_STORE_PROOF_HELPER")
        if not helper:
            return  # Existing Windows/macOS or manually installed ipatool.
        if not os.path.isabs(helper):
            raise StoreProofError("IPATOOL_STORE_PROOF_HELPER 必须是绝对路径")
        with self._lock:
            if self._ready:
                return
            print("正在准备 Apple 新认证组件（首次启动需要从 Apple 下载并校验设备证明库）", flush=True)
            try:
                result = subprocess.run(
                    [helper, "--setup"], env=env, capture_output=True,
                    timeout=330, check=False,
                )
            except (OSError, subprocess.TimeoutExpired) as exc:
                raise StoreProofError("Apple 认证组件初始化失败或超时，请检查 Apple 网络连接后重试") from exc
            if result.returncode:
                # Never include native helper output, machine identity or headers in an API error.
                raise StoreProofError("Apple 认证组件初始化失败，请检查网络；可在容器内运行 ipatool-store-proof --setup 诊断")
            self._ready = True
            print("Apple 新认证组件已就绪（设备身份保存在数据卷中）", flush=True)
