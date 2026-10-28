#!/usr/bin/env python3
"""用多个 CPU 核运行 fairplay-decrypt 的 decrypt.py：参数、输出、报错都和 decrypt.py 一样。

decrypt.py 逐页算密钥、解密（纯 Python，只用一个核），写结果时还会用默认压缩级别把整个 IPA 重新压缩一遍，
在 NAS 这类慢 CPU 上一个大 App 要好几分钟。这里不改它的代码，只在运行前替换两处：

- 逐页解密分给多个进程做，每个进程复用同一个 AES 加密对象。算法和 core.py 完全一样，解出来的内容逐字节相同；
- 写结果时用最快的压缩级别 1。解压后的内容不变，文件稍大一点。

另外把自己的优先级调低，解密时不拖慢服务器上的其他服务。fairplay-decrypt 以后改了这些函数、对不上时，
自动退回原来的做法。
"""

import os
import struct
import sys
import zipfile
from concurrent.futures import ProcessPoolExecutor
from pathlib import Path

sys.path.insert(0, os.environ.get("FAIRPLAY_DIR") or str(Path(__file__).resolve().parent / "fairplay"))

import core  # noqa: E402  fairplay-decrypt 的 core.py
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes  # noqa: E402

PAGES_PER_TASK = 128   # 每个任务 512 KB；小程序也能分给多个核
WORKERS = max(1, min(os.cpu_count() or 1, 8))
NEEDED = ("PAGE_SIZE", "WORK_MASK", "CONSTANT", "_xor", "source_blocks", "finish",
          "arm64_encryption_info", "arm64_supf_record_offset", "derive_work16")
_pool = None


def decrypt_pages(work, records, ciphertext, first_index):
    """解密连续的几页：和 core.decrypt_binary 里的循环一样，只是 AES-ECB 加密对象复用（ECB 每块独立，结果相同）。"""
    size = core.PAGE_SIZE
    ecb = Cipher(algorithms.AES(core._xor(work, core.WORK_MASK)), modes.ECB()).encryptor()
    out = bytearray()
    for i in range(len(records) // 32):
        record = records[32 * i:32 * (i + 1)]
        a, b, c = (ecb.update(core._xor(s, core.CONSTANT)) for s in core.source_blocks(record[:16], first_index + i))
        key = core.finish(core._xor(core.finish(core._xor(core.finish(a), b)), c))
        op = Cipher(algorithms.AES(key), modes.CBC(record[16:32])).decryptor()
        out += op.update(ciphertext[size * i:size * (i + 1)]) + op.finalize()
    return bytes(out)


def decrypt_binary(source, sinf, supf, credential):
    """结果和 core.decrypt_binary 相同；页数多时分给多个进程。"""
    global _pool
    info = core.arm64_encryption_info(source)
    size = core.PAGE_SIZE
    page_count = info.cryptsize // size
    record_start = core.arm64_supf_record_offset(supf, page_count)
    work = core.derive_work16(credential, sinf)
    if len(supf) < record_start + 32 * page_count:
        raise ValueError("truncated SUPF page record")
    start = info.base + info.cryptoff
    first_index = start // size
    tasks = [(work,
              supf[record_start + 32 * p:record_start + 32 * min(p + PAGES_PER_TASK, page_count)],
              source[start + size * p:start + size * min(p + PAGES_PER_TASK, page_count)],
              first_index + p)
             for p in range(0, page_count, PAGES_PER_TASK)]
    if len(tasks) > 1 and WORKERS > 1:
        if _pool is None:
            _pool = ProcessPoolExecutor(WORKERS)
        parts = list(_pool.map(decrypt_pages, *zip(*tasks)))
    else:
        parts = [decrypt_pages(*t) for t in tasks]
    result = bytearray(source)
    result[start:start + size * page_count] = b"".join(parts)
    struct.pack_into("<I", result, info.cryptid_offset, 0)
    return bytes(result), page_count


def use_fast_compression():
    """写结果时没指定压缩级别的条目用级别 1（decrypt.py 原样复制每个条目的信息，级别都没指定）。"""
    original = zipfile._get_compressor

    def fast(compress_type, compresslevel=None):
        if compress_type == zipfile.ZIP_DEFLATED and compresslevel is None:
            compresslevel = 1
        return original(compress_type, compresslevel)

    zipfile._get_compressor = fast


def main():
    try:
        os.nice(10)
    except (AttributeError, OSError):
        pass
    import decrypt  # fairplay-decrypt 的 decrypt.py
    if all(hasattr(core, name) for name in NEEDED) and hasattr(decrypt, "decrypt_binary"):
        decrypt.decrypt_binary = decrypt_binary
    else:
        print("fairplay-decrypt 的接口变了，按原来的方式解密（只用一个核）", flush=True)
    if hasattr(zipfile, "_get_compressor"):
        use_fast_compression()
    sys.argv[0] = "decrypt.py"   # 参数错误时的提示和原来一样（decrypt.py: error: …）
    try:
        decrypt.main()
    finally:
        if _pool is not None:
            _pool.shutdown()


if __name__ == "__main__":
    main()
