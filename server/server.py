"""
IPA 下载站：一个包装 ipatool 命令行的本地网站（仅用 Python 标准库）。

用法:
    python server.py                 # 默认 http://127.0.0.1:8686
环境变量（可选）:
    IPATOOL_PATH         ipatool 可执行文件路径（默认找同目录 ipatool.exe / bin\\ipatool.exe / PATH）
    IPA_DOWNLOAD_DIR     IPA 保存目录（默认 ./downloads）
    IPA_HOST / IPA_PORT  监听地址与端口（默认 127.0.0.1 / 8686）
    IPA_COUNTRY          用于补全图标/开发者等信息的商店地区（默认 cn）
    IPA_CONCURRENCY      同时进行的下载任务数（默认 3）
    IPA_PASSWORD         网站访问密码（浏览器弹窗登录，用户名随意）；监听非本机地址时必须设置
    IPA_ALLOW_NO_PASSWORD  设为 1 时允许不设访问密码对外监听（仅限可信内网）
    IPA_PASSPHRASE_FILE  钥匙串口令文件位置（默认 ./.keychain-passphrase）
    IPATOOL_KEYCHAIN_PASSPHRASE  直接指定钥匙串口令（优先于口令文件）
"""

import base64
import io
import plistlib
import zipfile
import hashlib
import hmac
import json
import os
import queue
import re
import shutil
import socket
import socketserver
import subprocess
import threading
import time
import urllib.parse
import urllib.request
import uuid
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

BASE_DIR = Path(__file__).resolve().parent
STATIC_DIR = BASE_DIR / "static"
DOWNLOAD_DIR = Path(os.environ.get("IPA_DOWNLOAD_DIR", BASE_DIR / "downloads")).resolve()
HOST = os.environ.get("IPA_HOST", "127.0.0.1")
PORT = int(os.environ.get("IPA_PORT", "8686"))
COUNTRY = os.environ.get("IPA_COUNTRY", "cn")
PASSPHRASE_FILE = Path(os.environ.get("IPA_PASSPHRASE_FILE", BASE_DIR / ".keychain-passphrase"))
ACCESS_PASSWORD = os.environ.get("IPA_PASSWORD", "")
PLATFORMS = {"", "iphone", "ipad", "appletv", "watchos", "visionos", "macos"}


def env_flag(name):
    """开关类配置：1 / true / yes / on 为开，0 / false / no / off / 留空为关；写错时提示并按关闭处理。"""
    raw = os.environ.get(name, "").strip().lower()
    if raw in ("1", "true", "yes", "on"):
        return True
    if raw not in ("", "0", "false", "no", "off"):
        print(f"配置提示：{name}={raw!r} 无法识别，只能填 1（开）或 0（关），现在按关闭处理", flush=True)
    return False


def env_int(name, default, minimum=1):
    raw = os.environ.get(name, "").strip()
    if not raw:
        return default
    if raw.isdigit() and int(raw) >= minimum:
        return int(raw)
    print(f"配置提示：{name}={raw!r} 应该是不小于 {minimum} 的整数，现在用默认值 {default}", flush=True)
    return default

DOWNLOAD_DIR.mkdir(parents=True, exist_ok=True)


def load_keychain_passphrase():
    """ipatool 在 Windows/Linux 上把账号存进加密文件，需要一个钥匙串口令。

    网站里没有终端能让 ipatool 弹出输入，所以由网站提供：优先用环境变量，
    否则首次运行时随机生成一个，保存在 .keychain-passphrase 里。
    """
    env = os.environ.get("IPATOOL_KEYCHAIN_PASSPHRASE")
    if env:
        return env
    if PASSPHRASE_FILE.is_file():
        return PASSPHRASE_FILE.read_text(encoding="utf-8").strip()
    import secrets
    value = secrets.token_urlsafe(32)
    PASSPHRASE_FILE.write_text(value, encoding="utf-8")
    return value


KEYCHAIN_PASSPHRASE = load_keychain_passphrase()


def find_ipatool():
    env = os.environ.get("IPATOOL_PATH")
    if env and Path(env).is_file():
        return env
    for name in ("ipatool.exe", "ipatool"):
        for d in (BASE_DIR, BASE_DIR / "bin"):
            if (d / name).is_file():
                return str(d / name)
    return shutil.which("ipatool")


# ---------------------------------------------------------------- 本地中转代理
#
# ipatool 查版本号要访问 uclient-api.itunes.apple.com，但有些网络里本地 DNS 给出的
# Apple IP 连不上，而另一个 IP（例如 Google DNS 给的）能连。这里在本机起一个只做
# CONNECT 转发的小代理给 ipatool 用：访问 PINNED_HOSTS 时直连能用的 IP，其他请求照常
# 交给原来的上游代理（如 Clash）或直连。只转发加密流量，证书校验仍由 ipatool 完成。

PINNED_HOSTS = {"uclient-api.itunes.apple.com"}
UPSTREAM_PROXY = os.environ.get("HTTPS_PROXY") or os.environ.get("https_proxy") or ""
_good_ip = {}


def resolve_candidates(host):
    ips = []
    try:
        ips += [ai[4][0] for ai in socket.getaddrinfo(host, 443, socket.AF_INET, socket.SOCK_STREAM)]
    except OSError:
        pass
    for url in ("https://dns.google/resolve?name={}&type=A", "https://cloudflare-dns.com/dns-query?name={}&type=A"):
        try:
            req = urllib.request.Request(url.format(host), headers={"accept": "application/dns-json"})
            with urllib.request.urlopen(req, timeout=5) as r:
                ips += [a["data"] for a in json.load(r).get("Answer", []) if a.get("type") == 1]
        except Exception:
            pass
    return list(dict.fromkeys(ips))


def connect_pinned(host, port):
    cached = _good_ip.get(host)
    candidates = ([cached] if cached else []) + [ip for ip in resolve_candidates(host) if ip != cached]
    for ip in candidates:
        try:
            sock = socket.create_connection((ip, port), timeout=4)
        except OSError:
            continue
        _good_ip[host] = ip
        return sock
    raise OSError(f"{host} 的所有 IP 都连不上：{', '.join(candidates) or '无'}")


def connect_upstream(host, port):
    if not UPSTREAM_PROXY:
        return socket.create_connection((host, port), timeout=30)
    up = urllib.parse.urlparse(UPSTREAM_PROXY if "://" in UPSTREAM_PROXY else "http://" + UPSTREAM_PROXY)
    sock = socket.create_connection((up.hostname, up.port or 80), timeout=30)
    sock.sendall(f"CONNECT {host}:{port} HTTP/1.1\r\nHost: {host}:{port}\r\n\r\n".encode())
    resp = b""
    while b"\r\n\r\n" not in resp:
        chunk = sock.recv(4096)
        if not chunk:
            break
        resp += chunk
    if not resp.split(b"\r\n", 1)[0].split(b" ")[1:2] == [b"200"]:
        sock.close()
        raise OSError(f"上游代理拒绝连接 {host}:{port}")
    return sock


def pipe(src, dst):
    try:
        while True:
            data = src.recv(65536)
            if not data:
                break
            dst.sendall(data)
    except OSError:
        pass
    finally:
        for s in (src, dst):
            try:
                s.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass


class RelayHandler(socketserver.BaseRequestHandler):
    def handle(self):
        client = self.request
        head = b""
        while b"\r\n\r\n" not in head and len(head) < 16384:
            chunk = client.recv(4096)
            if not chunk:
                return
            head += chunk
        parts = head.split(b"\r\n", 1)[0].decode("latin-1").split()
        if len(parts) < 2 or parts[0].upper() != "CONNECT":
            client.sendall(b"HTTP/1.1 405 Method Not Allowed\r\nContent-Length: 0\r\n\r\n")
            return
        host, _, port = parts[1].rpartition(":")
        try:
            remote = connect_pinned(host, int(port)) if host.lower() in PINNED_HOSTS else connect_upstream(host, int(port))
        except (OSError, ValueError):
            client.sendall(b"HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\n\r\n")
            return
        remote.settimeout(None)
        client.sendall(b"HTTP/1.1 200 Connection established\r\n\r\n")
        t = threading.Thread(target=pipe, args=(remote, client), daemon=True)
        t.start()
        pipe(client, remote)
        t.join()
        remote.close()


class RelayServer(socketserver.ThreadingTCPServer):
    daemon_threads = True
    allow_reuse_address = True


relay = RelayServer(("127.0.0.1", 0), RelayHandler)
threading.Thread(target=relay.serve_forever, daemon=True).start()
RELAY_URL = f"http://127.0.0.1:{relay.server_address[1]}"


# ---------------------------------------------------------------- 多账号
#
# ipatool 一次只记一个 Apple ID（登录状态存在 $HOME/.ipatool）。每个账号用自己的 HOME 运行 ipatool，
# 登录状态就互不干扰。"default" 是原来的账号，沿用进程本身的 HOME，所以升级前登录的账号不用重新登录。

DATA_DIR = PASSPHRASE_FILE.parent
ACCOUNTS_FILE = DATA_DIR / "accounts.json"
ACCOUNTS_DIR = DATA_DIR / "accounts"
_accounts_lock = threading.RLock()


def load_accounts():
    try:
        data = json.loads(ACCOUNTS_FILE.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        data = {}
    data.setdefault("current", "default")
    data.setdefault("accounts", {}).setdefault("default", {})
    if data["current"] not in data["accounts"]:
        data["current"] = "default"
    return data


def save_accounts(data):
    tmp = ACCOUNTS_FILE.with_suffix(".tmp")
    tmp.write_text(json.dumps(data, ensure_ascii=False, indent=1), encoding="utf-8")
    os.replace(tmp, ACCOUNTS_FILE)


def current_account():
    return load_accounts()["current"]


def account_email(acc_id):
    return load_accounts()["accounts"].get(acc_id, {}).get("email")


def account_list():
    data = load_accounts()
    return [{"id": i, "email": a["email"], "name": a.get("name"), "current": i == data["current"]}
            for i, a in data["accounts"].items() if a.get("email")]


def ipatool_env(account=None):
    env = dict(os.environ)
    env["HTTPS_PROXY"] = env["https_proxy"] = RELAY_URL
    acc = account if account is not None else current_account()
    if acc != "default":
        home = ACCOUNTS_DIR / acc
        home.mkdir(parents=True, exist_ok=True)
        env["HOME"] = str(home)
        env["HOMEDRIVE"], env["HOMEPATH"] = "", str(home)   # Windows 上 ipatool 用这两个变量找 HOME
        env.pop("XDG_STATE_HOME", None)
        env.pop("XDG_DATA_HOME", None)
    return env


# ---------------------------------------------------------------- ipatool 调用

class IpatoolError(Exception):
    pass


NO_WINDOW = getattr(subprocess, "CREATE_NO_WINDOW", 0)


def ipatool_cmd(args, interactive=False):
    exe = find_ipatool()
    if not exe:
        raise IpatoolError("未找到 ipatool，请把 ipatool.exe 放到 server.py 同目录，或设置 IPATOOL_PATH")
    cmd = [exe, *args, "--format", "json", "--keychain-passphrase", KEYCHAIN_PASSPHRASE]
    if not interactive:
        cmd.append("--non-interactive")
    return cmd


def parse_output(stdout, stderr, returncode):
    """解析 ipatool 的 JSON 日志行；出错时抛 IpatoolError。"""
    lines = []
    for raw in (stdout + "\n" + stderr).splitlines():
        raw = raw.strip()
        if not raw.startswith("{"):
            continue
        try:
            lines.append(json.loads(raw))
        except json.JSONDecodeError:
            pass

    errors = [l.get("error") or l.get("message") for l in lines if l.get("level") == "error"]
    if errors or returncode != 0:
        msg = "; ".join(e for e in errors if e) or (stderr or stdout).strip() or f"退出码 {returncode}"
        raise IpatoolError(msg)
    return lines


def run_ipatool(args, timeout=120, account=None):
    """运行 ipatool 并返回解析后的 JSON 日志行列表；account 为空时用当前账号。"""
    try:
        proc = subprocess.run(
            ipatool_cmd(args), capture_output=True, text=True, encoding="utf-8", errors="replace",
            timeout=timeout, creationflags=NO_WINDOW, env=ipatool_env(account),
        )
    except subprocess.TimeoutExpired:
        raise IpatoolError("ipatool 执行超时")
    return parse_output(proc.stdout, proc.stderr, proc.returncode)


class LoginSession:
    """在同一个 ipatool 进程里完成“密码 → 2FA 验证码”。

    分两次调用 `auth login`（先不带验证码、再带 --auth-code）时，Apple 常会拒绝验证码
    （apple did not complete verification）。这里像在终端里一样以交互模式运行 ipatool，
    等它提示输入验证码时保持进程不退出，用户提交验证码后再写入它的 stdin。
    """

    TTL = 10 * 60  # 等待验证码的最长时间

    def __init__(self, email, password, account, is_new):
        self.account, self.is_new = account, is_new
        self.proc = subprocess.Popen(
            ipatool_cmd(["auth", "login", "-e", email, "-p", password], interactive=True),
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, creationflags=NO_WINDOW,
            env=ipatool_env(account),
        )
        self.created = time.time()
        self.out, self.err = bytearray(), bytearray()
        self.prompted = threading.Event()
        self.readers = [threading.Thread(target=self._read, args=(self.proc.stdout, self.out), daemon=True),
                        threading.Thread(target=self._read, args=(self.proc.stderr, self.err), daemon=True)]
        for t in self.readers:
            t.start()

    def _read(self, stream, buf):
        while True:
            chunk = stream.read1(4096)
            if not chunk:
                break
            buf.extend(chunk)
            if buf is self.err and b"2FA code" in buf:
                self.prompted.set()

    def alive(self):
        return self.proc.poll() is None and time.time() - self.created < self.TTL

    def wait_for_prompt(self, timeout):
        """返回 "code"（在等验证码）或 "done"（进程已结束）。"""
        deadline = time.time() + timeout
        while time.time() < deadline:
            if self.prompted.is_set():
                return "code"
            if self.proc.poll() is not None:
                return "done"
            time.sleep(0.2)
        self.kill()
        raise IpatoolError("登录超时，请稍后重试")

    def submit_code(self, code, timeout=180):
        try:
            self.proc.stdin.write((code + "\n").encode())
            self.proc.stdin.flush()
            self.proc.wait(timeout)
        except subprocess.TimeoutExpired:
            self.kill()
            raise IpatoolError("提交验证码后 ipatool 没有响应，请重新登录")
        except OSError:
            pass
        return self.result()

    def result(self):
        self.proc.wait()
        for t in self.readers:
            t.join(5)
        return parse_output(self.out.decode("utf-8", "replace"), self.err.decode("utf-8", "replace"),
                            self.proc.returncode)

    def kill(self):
        if self.proc.poll() is None:
            self.proc.kill()


pending_login = None
login_lock = threading.Lock()


def refresh_account(acc_id):
    """用 auth info 读出账号的邮箱和名字并记到账号表里；没登录时返回 None。"""
    try:
        info = pick(run_ipatool(["auth", "info"], timeout=30, account=acc_id), "email")
    except IpatoolError:
        info = {}
    with _accounts_lock:
        data = load_accounts()
        entry = data["accounts"].get(acc_id)
        if entry is not None and info.get("email"):
            if entry.get("email") != info["email"] or entry.get("name") != info.get("name"):
                entry.update(email=info["email"], name=info.get("name"))
                save_accounts(data)
    return {"email": info["email"], "name": info.get("name")} if info.get("email") else None


def pick_login_target(email, wanted):
    """登录时决定用哪个账号目录：指定的 > 同邮箱的已有账号（重新登录）> 空着的 default > 新建。"""
    data = load_accounts()
    if wanted in data["accounts"]:
        return wanted, False
    for acc_id, a in data["accounts"].items():
        if (a.get("email") or "").lower() == email.lower():
            return acc_id, False
    if not data["accounts"]["default"].get("email") and not refresh_account("default"):
        return "default", False
    return uuid.uuid4().hex[:8], True


def finish_login(acc_id, info):
    with _accounts_lock:
        data = load_accounts()
        data["accounts"][acc_id] = {"email": info.get("email"), "name": info.get("name"),
                                    "addedAt": data["accounts"].get(acc_id, {}).get("addedAt") or time.time()}
        data["current"] = acc_id
        save_accounts(data)


def drop_account_dir(acc_id):
    if acc_id != "default":
        shutil.rmtree(ACCOUNTS_DIR / acc_id, ignore_errors=True)


def remove_account(acc_id):
    """退出并删除账号；删的是当前账号时，切换到剩下的第一个账号。"""
    try:
        run_ipatool(["auth", "revoke"], timeout=30, account=acc_id)
    except IpatoolError:
        pass
    with _accounts_lock:
        data = load_accounts()
        if acc_id == "default":
            data["accounts"]["default"] = {}
        else:
            data["accounts"].pop(acc_id, None)
        if data["current"] == acc_id:
            data["current"] = next((i for i, a in data["accounts"].items() if a.get("email")), "default")
        save_accounts(data)
    drop_account_dir(acc_id)


def pick(lines, key):
    """取第一条包含 key 的日志行。"""
    for l in lines:
        if key in l:
            return l
    return {}


def ipatool_version():
    exe = find_ipatool()
    if not exe:
        return None
    try:
        out = subprocess.run([exe, "--version"], capture_output=True, text=True, timeout=15,
                             creationflags=NO_WINDOW)
        return (out.stdout or out.stderr).strip().split()[-1]
    except Exception:
        return "?"


def normalize_app(a):
    return {
        "id": a.get("id") or a.get("trackId"),
        "bundleID": a.get("bundleID") or a.get("bundleId"),
        "name": a.get("name") or a.get("trackName"),
        "version": a.get("version"),
        "price": a.get("price", 0),
    }


def itunes_lookup(ids, country):
    """用 iTunes 公共接口补全图标、开发者、大小等信息（尽力而为）。"""
    if not ids:
        return {}
    url = "https://itunes.apple.com/lookup?" + urllib.parse.urlencode(
        {"id": ",".join(str(i) for i in ids), "country": country, "entity": "software,macSoftware"})
    try:
        with urllib.request.urlopen(url, timeout=10) as r:
            data = json.load(r)
    except Exception:
        return {}
    return {item.get("trackId"): item for item in data.get("results", [])}


# ---------------------------------------------------------------- 下载队列

jobs = {}           # id -> job dict
jobs_lock = threading.Lock()
job_queue = queue.Queue()
# ipatool 每个下载只用一条连接，同时跑几个任务能更好地用满带宽
CONCURRENCY = env_int("IPA_CONCURRENCY", 3)
# 每个任务先下载到自己的临时目录，完成后再移到 DOWNLOAD_DIR，进度统计互不干扰
PARTIAL_DIR = DOWNLOAD_DIR / ".partial"
shutil.rmtree(PARTIAL_DIR, ignore_errors=True)


# ---------------------------------------------------------------- 文件名与应用信息
#
# ipatool 默认把文件命名为「bundleID_appID_版本.ipa」，不好认。下载完成后改名为
# 「应用名_版本.ipa」，并把应用名、版本、图标记在 .meta.json 里，供文件列表显示。

META_FILE = DOWNLOAD_DIR / ".meta.json"
IPATOOL_NAME = re.compile(r"^(?P<bundle>[A-Za-z0-9.\-]+)_(?P<appid>\d+)_(?P<version>.+)\.(?P<ext>ipa|pkg)$")
meta_lock = threading.Lock()


def load_meta():
    try:
        return json.loads(META_FILE.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}


def save_meta(meta):
    tmp = META_FILE.with_suffix(".tmp")
    tmp.write_text(json.dumps(meta, ensure_ascii=False, indent=1), encoding="utf-8")
    os.replace(tmp, META_FILE)


def safe_name_part(s, limit=60):
    """去掉文件名里不能用的字符；移动云盘等网盘对特殊字符、表情很挑剔，一并去掉。"""
    s = re.sub(r'[\\/:*?"<>|%#\x00-\x1f]', " ", str(s or ""))
    s = "".join(ch for ch in s if ord(ch) < 0x10000)
    s = re.sub(r"\s+", " ", s).strip(" .")
    return s[:limit].strip(" .")


def rename_readable(src, info):
    """把 src（ipatool 命名的文件）改成「应用名_版本.扩展名」并记录信息，返回新文件名。"""
    m = IPATOOL_NAME.match(src.name)
    bundle = info.get("bundleID") or (m.group("bundle") if m else "")
    version = safe_name_part(info.get("version") or (m.group("version") if m else ""), 30)
    ext = m.group("ext") if m else src.suffix.lstrip(".") or "ipa"
    base = safe_name_part(info.get("name")) or bundle or src.stem
    with meta_lock:
        meta = load_meta()
        target = f"{base}_{version}.{ext}" if version else f"{base}.{ext}"
        other = meta.get(target, {}).get("bundleID")
        if (DOWNLOAD_DIR / target).exists() and target != src.name and other and other != bundle:
            target = f"{base}_{bundle}_{version}.{ext}"   # 不同 App 同名时带上 bundleID 区分
        os.replace(src, DOWNLOAD_DIR / target)
        meta.pop(src.name, None)
        meta[target] = {"name": info.get("name") or base, "bundleID": bundle, "version": version,
                        "appID": info.get("appID") or (int(m.group("appid")) if m else None),
                        "icon": info.get("icon")}
        save_meta(meta)
    return target


def backfill_names():
    """给以前下载、还是 ipatool 原始命名的文件补上应用名并改名。"""
    olds = [p for p in DOWNLOAD_DIR.iterdir() if p.is_file() and IPATOOL_NAME.match(p.name)]
    if not olds:
        return
    ids = {int(IPATOOL_NAME.match(p.name).group("appid")) for p in olds}
    found = itunes_lookup(sorted(ids), COUNTRY)
    for p in olds:
        m = IPATOOL_NAME.match(p.name)
        item = found.get(int(m.group("appid")))
        if not item:
            continue
        try:
            new = rename_readable(p, {"name": item.get("trackName"), "bundleID": m.group("bundle"),
                                      "version": m.group("version"), "appID": int(m.group("appid")),
                                      "icon": item.get("artworkUrl100") or item.get("artworkUrl60")})
            print(f"改名：{p.name} -> {new}", flush=True)
        except OSError as e:
            print(f"改名失败：{p.name}：{e}", flush=True)


def catalog_latest_version_id(app_id, country, platform):
    """从 apps.apple.com 的公开目录接口取最新版本 ID（ipatool 自己也用它做备用）。"""
    country = re.sub(r"[^a-z]", "", str(country).lower())[:2] or COUNTRY
    url = f"https://apps.apple.com/api/apps/v1/catalog/{country}/apps/{int(app_id)}?platform={platform}"
    try:
        with urllib.request.urlopen(url, timeout=10) as r:
            item = json.load(r)["data"][0]
        return str(item["attributes"]["platformAttributes"]["ios"]["externalVersionId"])
    except Exception as e:
        raise IpatoolError(f"备用接口 apps.apple.com 也没取到最新版本号：{e}")


def download_args(job, version_id):
    args = ["download", "-o", str(job["workDir"])]
    if job["bundleID"]:
        args += ["-b", job["bundleID"]]
    else:
        args += ["-i", str(job["appID"])]
    if version_id:
        args += ["--external-version-id", version_id]
    if job.get("platform"):
        args += ["--platform", job["platform"]]
    if job.get("purchase"):
        args.append("--purchase")
    return args


def run_download(job):
    # ipatool 下载“最新版”时常要先访问 uclient-api.itunes.apple.com 查版本号，
    # 有些网络连这个服务器很慢（等几十秒超时）甚至连不上。所以先从 apps.apple.com
    # 查到最新版本 ID 并指定给 ipatool，跳过那一步；查不到再按 ipatool 默认方式下载。
    version_id = job.get("versionID")
    pinned = False
    if not version_id and job.get("appID") and job.get("platform") in ("", "iphone", "ipad"):
        platform = "ipad" if job.get("platform") == "ipad" else "iphone"
        try:
            version_id = catalog_latest_version_id(job["appID"], job.get("country") or COUNTRY, platform)
            pinned = True
        except IpatoolError:
            pass

    try:
        return run_ipatool(download_args(job, version_id), timeout=60 * 60, account=job.get("account"))
    except IpatoolError as e:
        low = str(e).lower()
        # 许可、账号层面的错误换个下载方式也一样，不用再白等一次
        if not pinned or any(k in low for k in ("license", "not available", "purchase")):
            if not pinned and not job.get("versionID") and "resolve latest iOS version" in str(e):
                raise IpatoolError(f"{e}（连不上 Apple 的版本查询服务器，备用接口 apps.apple.com 也没查到，请稍后重试）")
            raise
        # 指定的版本 ID 不行时，退回 ipatool 默认方式再试一次
        job["note"] = f"按最新版本 ID 下载失败（{e}），已改用 ipatool 默认方式重试"
        return run_ipatool(download_args(job, None), timeout=60 * 60, account=job.get("account"))


def explain_download_error(msg):
    """给常见的 Apple 报错加上中文说明。"""
    low = msg.lower()
    if "license" in low:
        return msg + "（没有该 App 的许可：免费 App 请勾选“自动获取许可”；付费 App 需先用此 Apple ID 在 App Store 购买）"
    if "not available" in low or "failed to purchase" in low:
        return msg + ("（Apple 不让这个 Apple ID 下载或获取这个 App。请先在 iPhone 的 App Store 里用同一个 Apple ID "
                      "搜索这个 App 点一次「获取」，开始下载后就可以取消，然后回来重新下载；"
                      "如果 App Store 也提示无法获取，说明这个 App 在该账号的地区不可用）")
    return msg


def download_worker():
    while True:
        job_id = job_queue.get()
        job = jobs[job_id]
        work = PARTIAL_DIR / job_id
        work.mkdir(parents=True, exist_ok=True)
        job["workDir"] = work
        job["status"] = "running"
        job["startedAt"] = time.time()
        try:
            lines = run_download(job)
            res = pick(lines, "output")
            src = Path(res["output"]) if res.get("output") else None
            name = None
            if src and src.is_file():
                name = rename_readable(src, {"name": job.get("name"), "bundleID": job.get("bundleID"),
                                             "appID": job.get("appID"), "icon": job.get("icon")})
            job["status"] = "done"
            job["file"] = name
            job["purchased"] = bool(res.get("purchased"))
            if job["file"] and ALIST_AUTO_UPLOAD and alist_enabled():
                enqueue_alist(job["file"])
        except (IpatoolError, OSError) as e:
            job["status"] = "error"
            job["error"] = explain_download_error(str(e))
        shutil.rmtree(work, ignore_errors=True)
        job["finishedAt"] = time.time()
        job_queue.task_done()


def job_progress(job):
    """下载中时，按任务临时目录里的文件大小估算进度和速度。"""
    if job["status"] != "running":
        return None
    size = 0
    try:
        for p in job["workDir"].iterdir():
            size = max(size, os.stat(p).st_size)  # os.stat 在 Windows 上能拿到写入中文件的实时大小
    except OSError:
        pass
    now = time.time()
    last = job.get("_sample")
    if not last or now - last[0] >= 1:
        if last:
            job["speed"] = max(0, (size - last[1]) / (now - last[0]))
        job["_sample"] = (now, size)
    return size


for _ in range(CONCURRENCY):
    threading.Thread(target=download_worker, daemon=True).start()
threading.Thread(target=backfill_names, daemon=True).start()


# ---------------------------------------------------------------- 上传到 Alist
#
# 和 tg-alist-bot 用同样的 Alist 接口：先 /api/auth/login 换 token，再 PUT /api/fs/put 流式上传。

ALIST_URL = os.environ.get("ALIST_URL", "").rstrip("/")
ALIST_USERNAME = os.environ.get("ALIST_USERNAME", "")
ALIST_PASSWORD = os.environ.get("ALIST_PASSWORD", "")
ALIST_TOKEN = os.environ.get("ALIST_TOKEN", "")
ALIST_DIR = "/" + os.environ.get("ALIST_DIR", "/").strip("/")
ALIST_AUTO_UPLOAD = env_flag("ALIST_AUTO_UPLOAD")

uploads = {}        # 文件名 -> 上传状态
uploads_lock = threading.Lock()
upload_queue = queue.Queue()
_alist_token = {"value": ALIST_TOKEN}


def alist_enabled():
    return bool(ALIST_URL and (ALIST_TOKEN or (ALIST_USERNAME and ALIST_PASSWORD)))


def alist_remote_path(name):
    return f"{ALIST_DIR.rstrip('/')}/{name}"


def alist_login():
    if ALIST_TOKEN:
        return ALIST_TOKEN
    req = urllib.request.Request(
        ALIST_URL + "/api/auth/login",
        data=json.dumps({"username": ALIST_USERNAME, "password": ALIST_PASSWORD}).encode(),
        headers={"Content-Type": "application/json"}, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=15) as r:
            data = json.load(r)
    except Exception as e:
        raise IpatoolError(f"连接 Alist 失败：{e}")
    if data.get("code") != 200:
        raise IpatoolError(f"Alist 登录失败：{data.get('message')}")
    _alist_token["value"] = data["data"]["token"]
    return _alist_token["value"]


def alist_put(local, remote, rec):
    """流式 PUT 到 /api/fs/put，边传边更新 rec["sent"]。返回 (HTTP 状态码, JSON)。"""
    import http.client
    u = urllib.parse.urlparse(ALIST_URL)
    conn_cls = http.client.HTTPSConnection if u.scheme == "https" else http.client.HTTPConnection
    conn = conn_cls(u.hostname, u.port, timeout=300)
    try:
        conn.putrequest("PUT", u.path.rstrip("/") + "/api/fs/put")
        conn.putheader("Authorization", _alist_token["value"] or alist_login())
        conn.putheader("File-Path", urllib.parse.quote(remote, safe="/"))
        conn.putheader("Content-Type", "application/octet-stream")
        conn.putheader("Content-Length", str(rec["size"]))
        conn.endheaders()
        with open(local, "rb") as f:
            while chunk := f.read(1024 * 1024):
                conn.send(chunk)
                rec["sent"] += len(chunk)
        resp = conn.getresponse()
        body = resp.read().decode("utf-8", "replace")
        try:
            data = json.loads(body)
        except json.JSONDecodeError:
            data = {"code": resp.status, "message": body[:200]}
        return resp.status, data
    finally:
        conn.close()


def upload_to_alist(rec):
    local = DOWNLOAD_DIR / rec["name"]
    for attempt in (1, 2):
        rec["sent"], rec["size"] = 0, local.stat().st_size
        if not _alist_token["value"]:
            alist_login()
        status, data = alist_put(local, rec["remote"], rec)
        if (status == 401 or data.get("code") == 401) and attempt == 1 and not ALIST_TOKEN:
            _alist_token["value"] = ""  # token 过期，重新登录再传一次
            continue
        if status == 200 and data.get("code") == 200:
            return
        raise IpatoolError(f"Alist 返回错误：HTTP {status}，{data.get('message')}")


def enqueue_alist(name):
    with uploads_lock:
        rec = uploads.get(name)
        if rec and rec["status"] in ("queued", "running"):
            return rec
        rec = uploads[name] = {"name": name, "status": "queued", "sent": 0, "size": 0,
                               "remote": alist_remote_path(name), "error": None}
    upload_queue.put(name)
    return rec


def alist_worker():
    while True:
        name = upload_queue.get()
        rec = uploads[name]
        rec["status"], rec["startedAt"] = "running", time.time()
        try:
            upload_to_alist(rec)
            rec["status"] = "done"
            # 直接把新文件放进目录缓存，不用等下次刷新
            _alist_cache["items"] = [{"name": name, "size": rec["size"],
                                      "modified": time.strftime("%Y-%m-%dT%H:%M:%S")}] + \
                [it for it in _alist_cache["items"] if it["name"] != name]
        except (IpatoolError, OSError) as e:
            rec["status"], rec["error"] = "error", str(e)
        rec["finishedAt"] = time.time()
        upload_queue.task_done()


threading.Thread(target=alist_worker, daemon=True).start()


# ---------------------------------------------------------------- 浏览 Alist 目录、取直链
#
# 手机可以直接从 Alist 背后的网盘直链下载，不经过家里的上行带宽。

ALIST_CACHE_SECONDS = 300
_alist_cache = {"at": 0, "items": []}
_alist_list_lock = threading.Lock()


def alist_call(path, body):
    """调用 Alist 的 JSON 接口，token 过期时重新登录一次。"""
    for attempt in (1, 2):
        token = _alist_token["value"] or alist_login()
        req = urllib.request.Request(ALIST_URL + path, data=json.dumps(body).encode(), method="POST",
                                     headers={"Content-Type": "application/json", "Authorization": token})
        try:
            with urllib.request.urlopen(req, timeout=120) as r:
                data = json.load(r)
        except Exception as e:
            raise IpatoolError(f"连接 Alist 失败：{e}")
        if data.get("code") == 401 and attempt == 1 and not ALIST_TOKEN:
            _alist_token["value"] = ""
            continue
        if data.get("code") != 200:
            raise IpatoolError(f"Alist 返回错误：{data.get('message')}")
        return data.get("data") or {}


def _alist_reload(refresh=False):
    with _alist_list_lock:
        data = alist_call("/api/fs/list", {"path": ALIST_DIR, "page": 1, "per_page": 0, "refresh": bool(refresh)})
        items = [{"name": it["name"], "size": it.get("size") or 0, "modified": it.get("modified")}
                 for it in data.get("content") or [] if not it.get("is_dir")]
        items.sort(key=lambda it: it.get("modified") or "", reverse=True)
        _alist_cache.update(at=time.time(), items=items)


def _alist_reload_quietly():
    try:
        _alist_reload()
    except IpatoolError as e:
        print(f"后台刷新 Alist 目录失败：{e}", flush=True)
    finally:
        _alist_cache["reloading"] = False


def alist_list(refresh=False):
    """列出 ALIST_DIR 里的文件（不含子目录），最新的在前。

    目录有几千个文件时 Alist 要读十几秒，所以结果会缓存：过期后先返回旧结果，同时在后台刷新。
    """
    if refresh or not _alist_cache["at"]:
        _alist_reload(refresh)
    elif time.time() - _alist_cache["at"] > ALIST_CACHE_SECONDS and not _alist_cache.get("reloading"):
        _alist_cache["reloading"] = True
        threading.Thread(target=_alist_reload_quietly, daemon=True).start()
    return _alist_cache["items"]


if alist_enabled():   # 启动时先在后台读一遍目录，第一次打开 Alist 页就不用等
    _alist_cache["reloading"] = True
    threading.Thread(target=_alist_reload_quietly, daemon=True).start()


def check_plain_name(name):
    if not name or "/" in name or "\\" in name or name in (".", ".."):
        raise IpatoolError("文件名无效")
    return name


def alist_link(name):
    """取文件在网盘的直链（有时效）。"""
    data = alist_call("/api/fs/get", {"path": alist_remote_path(check_plain_name(name))})
    if not data.get("raw_url"):
        raise IpatoolError("Alist 没有返回这个文件的直链")
    return data["raw_url"], data.get("size")


# ---------------------------------------------------------------- 直接安装（itms-services）
#
# iOS 只接受 HTTPS 上的安装清单（manifest），所以要配置 IPA_PUBLIC_URL（例如用 Lucky 反代出来的
# https 地址）。iOS 安装器下载清单和 IPA 时不会带网站密码，因此这两个链接用带过期时间的签名代替。

PUBLIC_URL = os.environ.get("IPA_PUBLIC_URL", "").strip().rstrip("/")
# 网盘直链里可能有未编码的中文，iOS / TrollStore 不认；编码时保留已编码的 %XX 和 URL 结构字符
URL_SAFE = ":/?#[]@!$&'()*+,;=%~"
LINK_TTL = 6 * 3600
LINK_SECRET_FILE = PASSPHRASE_FILE.parent / ".link-secret"


def load_link_secret():
    if LINK_SECRET_FILE.is_file():
        return LINK_SECRET_FILE.read_text(encoding="utf-8").strip()
    import secrets
    value = secrets.token_urlsafe(32)
    LINK_SECRET_FILE.write_text(value, encoding="utf-8")
    return value


LINK_SECRET = load_link_secret()


# ---------------------------------------------------------------- 历史版本信息缓存
#
# 版本 ID 对应的版本号、发布日期不会再变，查过一次就存下来。每查一个版本都要向 Apple 发一次请求，
# 所以同时最多查 3 个，避免一次打开几百个版本时请求太密。

VERSION_CACHE_FILE = PASSPHRASE_FILE.parent / ".version-cache.json"
_version_cache_lock = threading.Lock()
_version_lookup_slots = threading.BoundedSemaphore(3)


def _load_version_cache():
    try:
        return json.loads(VERSION_CACHE_FILE.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}


_version_cache = _load_version_cache()


def version_key(app, vid):
    return f"{app}:{vid}"


def remember_version(app, vid, info):
    with _version_cache_lock:
        _version_cache[version_key(app, vid)] = info
        tmp = VERSION_CACHE_FILE.with_suffix(".tmp")
        tmp.write_text(json.dumps(_version_cache, ensure_ascii=False), encoding="utf-8")
        os.replace(tmp, VERSION_CACHE_FILE)


def install_enabled():
    return PUBLIC_URL.startswith("https://")


def link_sig(kind, name, exp):
    return hmac.new(LINK_SECRET.encode(), f"{kind}\n{name}\n{exp}".encode(), "sha256").hexdigest()[:32]


def signed_path(kind, name, route, suffix=""):
    exp = int(time.time()) + LINK_TTL
    return f"{route}/{exp}/{link_sig(kind, name, exp)}/{urllib.parse.quote(name)}{suffix}"


def verify_signed(kind, rest, suffix=""):
    """rest 是 /{kind}/ 之后的部分：{exp}/{sig}/{name}{suffix}。合法时返回文件名。"""
    parts = rest.split("/", 2)
    if len(parts) != 3 or not parts[0].isdigit():
        return None
    exp, sig, quoted = parts
    if suffix:
        if not quoted.endswith(suffix):
            return None
        quoted = quoted[:-len(suffix)]
    name = urllib.parse.unquote(quoted)
    if int(exp) < time.time() or not hmac.compare_digest(sig, link_sig(kind, name, int(exp))):
        return None
    return name


def build_manifest(name, ipa_url):
    import plistlib
    info = load_meta().get(name) or {}
    ipa_url = urllib.parse.quote(ipa_url, safe=URL_SAFE)
    assets = [{"kind": "software-package", "url": ipa_url}]
    if info.get("icon"):
        assets += [{"kind": "display-image", "needs-shine": False, "url": info["icon"]},
                   {"kind": "full-size-image", "needs-shine": False, "url": info["icon"]}]
    return plistlib.dumps({"items": [{"assets": assets, "metadata": {
        "bundle-identifier": info.get("bundleID") or "",
        "bundle-version": info.get("version") or "1.0",
        "kind": "software",
        "title": info.get("name") or name,
    }}]})


def pick_install_source(name, wanted):
    local = (DOWNLOAD_DIR / name).is_file()
    in_alist = alist_enabled() and (
        (uploads.get(name) or {}).get("status") == "done"
        or any(it["name"] == name for it in _alist_cache["items"]))
    if wanted == "server":
        if not local:
            raise IpatoolError("服务器上已经没有这个文件了，可以改用 Alist 安装")
        return "server"
    if wanted == "alist":
        if not alist_enabled():
            raise IpatoolError("还没配置 Alist")
        return "alist"
    if in_alist:
        return "alist"   # 网盘直链不占家里的上行带宽，优先用
    if local:
        return "server"
    if alist_enabled():
        return "alist"
    raise IpatoolError("找不到这个文件")


# ---------------------------------------------------------------- 证书签名（zsign）
#
# 用户上传自己的 p12 证书 + 描述文件，选 Alist 或服务器上的 IPA，用 zsign 重新签名后在线安装。
# App Store 原版 IPA 是加密的，重签后会闪退；这个功能主要用来装改版 / 砸壳的 IPA。

ZSIGN = os.environ.get("ZSIGN_PATH") or shutil.which("zsign")
OPENSSL = shutil.which("openssl")
CERTS_DIR = DATA_DIR / "certs"
SIGNED_DIR = DATA_DIR / "signed"
SIGN_WORK_DIR = DATA_DIR / ".sign-work"
SIGNED_KEEP = 20          # 最多保留多少个签好的文件，旧的自动删
shutil.rmtree(SIGN_WORK_DIR, ignore_errors=True)

sign_jobs = {}
sign_jobs_lock = threading.Lock()
sign_queue = queue.Queue()
_signed_meta_lock = threading.Lock()


def parse_profile(data):
    """读出 .mobileprovision（CMS 签名包着的 plist）里的关键信息。"""
    start, end = data.find(b"<?xml"), data.find(b"</plist>")
    if start < 0 or end < 0:
        raise IpatoolError("描述文件格式不对，请上传 .mobileprovision 文件")
    try:
        pl = plistlib.loads(data[start:end + len(b"</plist>")])
    except Exception:
        raise IpatoolError("描述文件解析失败")
    ent = pl.get("Entitlements") or {}
    exp = pl.get("ExpirationDate")
    return {
        "profileName": pl.get("Name"),
        "team": pl.get("TeamName"),
        "teamID": (pl.get("TeamIdentifier") or [""])[0],
        "appID": ent.get("application-identifier"),
        "profileExpires": exp.timestamp() if exp else None,
        "allDevices": bool(pl.get("ProvisionsAllDevices")),
        "devices": len(pl.get("ProvisionedDevices") or []),
        "certsDER": [bytes(c) for c in pl.get("DeveloperCertificates") or []],
    }


def p12_info(path, password):
    """用 openssl 校验 p12 密码，读出证书名称、有效期和 DER（用来和描述文件比对）。"""
    if not OPENSSL:
        raise IpatoolError("服务器上没有 openssl，无法读取证书")
    env = dict(os.environ, P12PW=password)
    for extra in ([], ["-legacy"]):   # 老证书用的加密算法在 OpenSSL 3 里要加 -legacy
        p = subprocess.run([OPENSSL, "pkcs12", "-in", str(path), "-nokeys", "-clcerts", "-passin", "env:P12PW", *extra],
                           capture_output=True, env=env, timeout=30)
        if p.returncode == 0 and b"BEGIN CERTIFICATE" in p.stdout:
            pem = p.stdout[p.stdout.index(b"-----BEGIN CERTIFICATE-----"):]
            info = subprocess.run([OPENSSL, "x509", "-noout", "-subject", "-enddate", "-nameopt", "RFC2253,-esc_msb"],
                                  input=pem, capture_output=True, timeout=30).stdout.decode("utf-8", "replace")
            der = subprocess.run([OPENSSL, "x509", "-outform", "DER"], input=pem, capture_output=True, timeout=30).stdout
            cn = re.search(r"CN=((?:[^,\\\r\n]|\\.)*)", info)
            org = re.search(r"(?<![A-Z])O=((?:[^,\\\r\n]|\\.)*)", info)
            end = re.search(r"notAfter=(.+)", info)
            expires = None
            if end:
                try:
                    expires = time.mktime(time.strptime(end.group(1).strip(), "%b %d %H:%M:%S %Y %Z"))
                except ValueError:
                    pass
            return {"cn": cn.group(1).replace("\\", "") if cn else None,
                    "org": org.group(1).replace("\\", "") if org else None,
                    "certExpires": expires, "der": der}
    raise IpatoolError("证书密码不对，或者不是有效的 p12 文件")


def _cert_dir(cert_id):
    if not re.fullmatch(r"[0-9a-f]{8}", cert_id or ""):
        raise IpatoolError("证书 ID 无效")
    return CERTS_DIR / cert_id


def load_cert(cert_id):
    d = _cert_dir(cert_id)
    try:
        return json.loads((d / "cert.json").read_text(encoding="utf-8"))
    except (OSError, ValueError):
        raise IpatoolError("证书不存在")


def public_cert(c):
    return {k: v for k, v in c.items() if k != "password"}


def list_certs():
    out = []
    if CERTS_DIR.is_dir():
        for d in CERTS_DIR.iterdir():
            try:
                out.append(public_cert(json.loads((d / "cert.json").read_text(encoding="utf-8"))))
            except (OSError, ValueError):
                continue
    return sorted(out, key=lambda c: c.get("addedAt") or 0)


def add_cert(label, p12_data, profile_data, password):
    profile = parse_profile(profile_data)
    cert_id = uuid.uuid4().hex[:8]
    d = CERTS_DIR / cert_id
    d.mkdir(parents=True)
    try:
        (d / "cert.p12").write_bytes(p12_data)
        (d / "profile.mobileprovision").write_bytes(profile_data)
        info = p12_info(d / "cert.p12", password)
    except Exception:
        shutil.rmtree(d, ignore_errors=True)
        raise
    record = {
        "id": cert_id, "label": label or info["cn"] or profile["profileName"], "cn": info["cn"], "org": info["org"],
        "certExpires": info["certExpires"], "addedAt": time.time(), "password": password,
        # 证书不在描述文件的证书列表里时，签出来的包装不上
        "matchesProfile": info["der"] in profile["certsDER"] if profile["certsDER"] else None,
        **{k: v for k, v in profile.items() if k != "certsDER"},
    }
    (d / "cert.json").write_text(json.dumps(record, ensure_ascii=False, indent=1), encoding="utf-8")
    for f in d.iterdir():
        os.chmod(f, 0o600)
    return public_cert(record)


def _zip_name(info):
    """Windows 打包的中文文件名多半是 GBK，zipfile 会按 cp437 读成乱码，这里转回来。"""
    if info.flag_bits & 0x800:
        return info.filename
    try:
        return info.filename.encode("cp437").decode("gbk")
    except (UnicodeEncodeError, UnicodeDecodeError):
        return info.filename


def _decode_text(data):
    for enc in ("utf-8-sig", "gbk", "utf-16"):
        try:
            return data.decode(enc)
        except UnicodeDecodeError:
            continue
    return ""


def passwords_in(text):
    """从「密码：1234」「password=abc」之类的文字里找密码；找不到时把短的单行文字当作候选。"""
    found = [m.group(1) for m in re.finditer(
        r"(?:密码|口令|证书密码|password|passwd|pwd|pass)\s*(?:是|为)?\s*[:：=]?\s*([^\s，,；;。]+)", text, re.I)]
    if not found:
        found = [l.strip() for l in text.splitlines() if l.strip() and len(l.strip()) <= 64 and " " not in l.strip()]
    return found


def _expand_files(files):
    """把上传的文件列表展开：zip 解开成里面的文件（路径前加上压缩包名，当作文件夹），其他文件原样保留。"""
    out = []
    for name, data in files:
        name = name.replace("\\", "/").rsplit("/", 1)[-1]
        if not name.lower().endswith(".zip"):
            out.append((name, data))
            continue
        try:
            z = zipfile.ZipFile(io.BytesIO(data))
        except zipfile.BadZipFile:
            raise IpatoolError(f"{name} 不是有效的 zip 文件")
        for info in z.infolist()[:200]:
            inner = _zip_name(info).replace("\\", "/")
            if (info.is_dir() or inner.startswith("__MACOSX/") or inner.rsplit("/", 1)[-1].startswith("._")
                    or info.file_size > 5 * 1024 * 1024):
                continue
            try:
                out.append((f"{name[:-4]}/{inner}", z.read(info)))
            except (RuntimeError, zipfile.BadZipFile, NotImplementedError):
                raise IpatoolError(f"{name} 解压失败：压缩包加了密码或用了不支持的压缩方式，请解压后直接选里面的文件")
    return out


def import_cert_files(files, password="", label=""):
    """导入证书：files 里可以有 zip、p12、描述文件、写着密码的 txt。
    自动找密码，按「描述文件里是否包含这个证书」把 p12 和描述文件配对，一次可以导入多套。"""
    p12s, profiles, candidates = [], [], []
    for name, data in _expand_files(files):
        base = name.rsplit("/", 1)[-1]
        ext = base.rsplit(".", 1)[-1].lower() if "." in base else ""
        if ext in ("p12", "pfx"):
            p12s.append((name, data))
        elif ext == "mobileprovision":
            try:
                profiles.append((name, data, parse_profile(data)))
            except IpatoolError:
                pass
        elif ext in ("txt", "md", "rtf", ""):
            candidates += passwords_in(_decode_text(data))
        if re.search(r"密码|password|pwd", base, re.I):   # 有的证书包把密码写在文件名里
            candidates += passwords_in(base.rsplit(".", 1)[0])
    if not p12s:
        raise IpatoolError("没有找到 .p12 证书")
    if not profiles:
        raise IpatoolError("没有找到 .mobileprovision 描述文件")
    # 候选密码：手动填的优先，其次压缩包里写的，最后试空密码
    tries = list(dict.fromkeys(([password] if password else []) + candidates + [""]))[:30]
    seen = set()   # 已经导入过的「证书 + 描述文件」，同一个包导两次不重复添加
    if CERTS_DIR.is_dir():
        for d in CERTS_DIR.iterdir():
            try:
                seen.add(hashlib.sha256((d / "cert.p12").read_bytes() + (d / "profile.mobileprovision").read_bytes()).digest())
            except OSError:
                continue
    results = []
    for p12_name, p12_data in p12s:
        tmp = SIGN_WORK_DIR / ("import-" + uuid.uuid4().hex[:8] + ".p12")
        SIGN_WORK_DIR.mkdir(parents=True, exist_ok=True)
        tmp.write_bytes(p12_data)
        found = None
        try:
            for pw in tries:
                try:
                    found = (pw, p12_info(tmp, pw))
                    break
                except IpatoolError:
                    continue
        finally:
            tmp.unlink(missing_ok=True)
        if not found:
            results.append({"file": p12_name, "ok": False, "error": "密码不对，请检查密码框里填的密码" if password
                            else "密码不对：没找到能用的密码，请在密码框里填上再导入"})
            continue
        pw, info = found
        matched = [p for p in profiles if info["der"] in p[2]["certsDER"]]
        if not matched:
            folder = p12_name.rsplit("/", 1)[0] if "/" in p12_name else ""
            same_dir = [p for p in profiles if (p[0].rsplit("/", 1)[0] if "/" in p[0] else "") == folder]
            matched = same_dir[:1] or (profiles[:1] if len(profiles) == 1 else [])
        if not matched:
            results.append({"file": p12_name, "ok": False, "error": "没找到包含这个证书的描述文件"})
            continue
        for prof_name, prof_data, prof in matched:
            digest = hashlib.sha256(p12_data + prof_data).digest()
            if digest in seen:
                results.append({"file": p12_name, "profile": prof_name, "ok": False, "error": "已经导入过了，跳过"})
                continue
            seen.add(digest)
            name = label or (p12_name.rsplit("/", 2)[-2] if p12_name.count("/") else None) or info["cn"] or prof["profileName"]
            if len(matched) > 1:
                name = f"{name} · {prof['profileName']}"
            cert = add_cert(name[:40], p12_data, prof_data, pw)
            results.append({"file": p12_name, "profile": prof_name, "ok": True, "cert": cert})
    return results


def delete_cert(cert_id):
    # 用它签好的文件留着：证书过期删掉后，还能在「已签名」里直接换新证书重签
    shutil.rmtree(_cert_dir(cert_id), ignore_errors=True)


def load_signed_meta():
    try:
        return json.loads((SIGNED_DIR / "meta.json").read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}


def save_signed_meta(meta):
    SIGNED_DIR.mkdir(parents=True, exist_ok=True)
    tmp = SIGNED_DIR / "meta.tmp"
    tmp.write_text(json.dumps(meta, ensure_ascii=False, indent=1), encoding="utf-8")
    os.replace(tmp, SIGNED_DIR / "meta.json")


def signed_path_of(key):
    """key 形如「证书ID/文件名」，返回签好的文件路径（防止跳出目录）。"""
    cert_id, _, name = key.partition("/")
    _cert_dir(cert_id)   # 校验证书 ID 格式
    p = (SIGNED_DIR / cert_id / name).resolve()
    if p.parent != (SIGNED_DIR / cert_id).resolve():
        raise IpatoolError("文件名无效")
    return p


def _sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        while chunk := f.read(1 << 20):
            h.update(chunk)
    return h.hexdigest()


def ipa_info(path):
    """读出 IPA 主程序的 Bundle ID、版本、名称。"""
    with zipfile.ZipFile(path) as z:
        for n in z.namelist():
            parts = n.split("/")
            if len(parts) == 3 and parts[0] == "Payload" and parts[1].endswith(".app") and parts[2] == "Info.plist":
                pl = plistlib.loads(z.read(n))
                return {"bundleID": pl.get("CFBundleIdentifier"),
                        "version": pl.get("CFBundleShortVersionString") or pl.get("CFBundleVersion"),
                        "appName": pl.get("CFBundleDisplayName") or pl.get("CFBundleName")}
    raise IpatoolError("IPA 里没找到 Info.plist，可能不是有效的 IPA")


def enqueue_sign(source, name, cert_id, **extra):
    check_plain_name(name)
    load_cert(cert_id)
    if not extra.get("fromSigned"):   # 用签好的文件重签时不需要原文件
        if source == "server" and not (DOWNLOAD_DIR / name).is_file():
            raise IpatoolError("服务器上没有这个文件")
        if source == "alist" and not alist_enabled():
            raise IpatoolError("还没配置 Alist")
    job = {"id": uuid.uuid4().hex[:10], "status": "queued", "source": source, "name": name, "cert": cert_id,
           "certLabel": load_cert(cert_id).get("label"), "createdAt": time.time(),
           "downloaded": 0, "size": 0, "error": None, "key": None, **extra}
    with sign_jobs_lock:
        sign_jobs[job["id"]] = job
    sign_queue.put(job["id"])
    return job


def enqueue_resign(key, cert_id):
    """换证书重签：直接用签好的文件重签（不用再从网盘取），文件不在了就从原来的来源重新取。"""
    info = load_signed_meta().get(key)
    if not info:
        raise IpatoolError("没有这个签名记录")
    path = signed_path_of(key)
    extra = {"replaces": key, "icon": info.get("icon")}
    if path.is_file():
        return enqueue_sign(info.get("source") or "server", info.get("sourceName") or path.name, cert_id,
                            fromSigned=key, **extra)
    return enqueue_sign(info.get("source"), info.get("sourceName") or "", cert_id, **extra)


def cert_expired(cert_id):
    """证书或描述文件已过期，或者证书已被删除。"""
    try:
        c = load_cert(cert_id)
    except IpatoolError:
        return True
    ends = [t for t in (c.get("certExpires"), c.get("profileExpires")) if t]
    return bool(ends) and min(ends) < time.time()


def _fetch_to(url, dest, job):
    with urllib.request.urlopen(url, timeout=60) as r, open(dest, "wb") as f:
        job["size"] = int(r.headers.get("Content-Length") or 0)
        while chunk := r.read(1 << 20):
            f.write(chunk)
            job["downloaded"] += len(chunk)


def _prune_signed():
    files = sorted((p for p in SIGNED_DIR.glob("*/*") if p.is_file()), key=lambda p: p.stat().st_mtime, reverse=True)
    if len(files) <= SIGNED_KEEP:
        return
    with _signed_meta_lock:
        meta = load_signed_meta()
        for p in files[SIGNED_KEEP:]:
            p.unlink(missing_ok=True)
            meta.pop(f"{p.parent.name}/{p.name}", None)
        save_signed_meta(meta)


def run_sign(job):
    if not ZSIGN:
        raise IpatoolError("服务器上没有 zsign，请用最新的 Dockerfile 重新构建镜像")
    cert = load_cert(job["cert"])
    cdir = _cert_dir(job["cert"])
    work = SIGN_WORK_DIR / job["id"]
    work.mkdir(parents=True, exist_ok=True)
    try:
        src = work / "input.ipa"   # zsign 按扩展名识别，.tipa 也统一叫 .ipa
        if job.get("fromSigned"):
            shutil.copyfile(signed_path_of(job["fromSigned"]), src)
        elif job["source"] == "server":
            shutil.copyfile(DOWNLOAD_DIR / job["name"], src)
        else:
            job["status"] = "downloading"
            _fetch_to(alist_link(job["name"])[0], src, job)
        job["status"] = "signing"
        out_name = re.sub(r"\.tipa$", ".ipa", job["name"], flags=re.I)
        if not out_name.lower().endswith(".ipa"):
            out_name += ".ipa"
        out = SIGNED_DIR / job["cert"] / out_name
        out.parent.mkdir(parents=True, exist_ok=True)
        tmp_out = work / "signed.ipa"
        p = subprocess.run([ZSIGN, "-k", str(cdir / "cert.p12"), "-p", cert["password"],
                            "-m", str(cdir / "profile.mobileprovision"), "-z", "1", "-o", str(tmp_out), str(src)],
                           capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=60 * 60)
        if p.returncode != 0 or not tmp_out.is_file():
            detail = (p.stderr or p.stdout).strip().splitlines()
            raise IpatoolError("签名失败：" + (" ".join(detail[-3:]) if detail else f"zsign 退出码 {p.returncode}"))
        info = ipa_info(tmp_out)
        os.replace(tmp_out, out)
        key = f"{job['cert']}/{out_name}"
        old = job.get("replaces")
        with _signed_meta_lock:
            meta = load_signed_meta()
            meta[key] = {**info, "source": job["source"], "sourceName": job["name"], "signedAt": time.time(),
                         "cert": job["cert"], "teamID": cert.get("teamID"), "size": out.stat().st_size,
                         "icon": (load_meta().get(job["name"]) or {}).get("icon") or job.get("icon")}
            # 换证书重签后，旧证书已经过期 / 删除的那份没用了，顺手删掉
            if old and old != key and old in meta and cert_expired(old.partition("/")[0]):
                signed_path_of(old).unlink(missing_ok=True)
                del meta[old]
            save_signed_meta(meta)
        job.update(key=key, **info)
        _prune_signed()
    finally:
        shutil.rmtree(work, ignore_errors=True)


def sign_worker():
    while True:
        job_id = sign_queue.get()
        job = sign_jobs[job_id]
        job["startedAt"] = time.time()
        try:
            run_sign(job)
            job["status"] = "done"
        except (IpatoolError, OSError, zipfile.BadZipFile, subprocess.TimeoutExpired) as e:
            job["status"], job["error"] = "error", str(e)
        job["finishedAt"] = time.time()
        sign_queue.task_done()


threading.Thread(target=sign_worker, daemon=True).start()


def signed_links(key, host):
    """签好的文件的安装 / 下载链接（带签名，几小时内有效）。"""
    base = PUBLIC_URL or f"http://{host}"
    dl = base + signed_path("sdl", key, "/sdl")
    return {
        "installURL": ("itms-services://?action=download-manifest&url=" + urllib.parse.quote(
            PUBLIC_URL + signed_path("install-signed", key, "/install/signed", ".plist"), safe="")) if install_enabled() else None,
        "trollstoreURL": "apple-magnifier://install?url=" + urllib.parse.quote(dl, safe=""),
        "downloadURL": dl,
    }


# ---------------------------------------------------------------- HTTP

class Handler(BaseHTTPRequestHandler):
    server_version = "IPASite/1.0"

    def log_message(self, fmt, *args):
        pass

    def authorized(self):
        """设置了 IPA_PASSWORD 时，要求 HTTP Basic 认证（用户名随意，只校验密码）。"""
        if not ACCESS_PASSWORD:
            return True
        auth = self.headers.get("Authorization", "")
        if auth.startswith("Basic "):
            try:
                password = base64.b64decode(auth[6:]).decode("utf-8").partition(":")[2]
            except Exception:
                password = ""
            if hmac.compare_digest(password.encode(), ACCESS_PASSWORD.encode()):
                return True
            print(f"访问密码错误：{self.client_address[0]}", flush=True)
            time.sleep(1)  # 拖慢暴力猜测
        self.send_response(401)
        self.send_header("WWW-Authenticate", 'Basic realm="IPA", charset="UTF-8"')
        self.send_header("Content-Length", "0")
        self.end_headers()
        return False

    # helpers
    def send_json(self, obj, status=200):
        body = json.dumps(obj, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def send_error_json(self, msg, status=400):
        self.send_json({"ok": False, "error": msg}, status)

    def read_json(self):
        n = int(self.headers.get("Content-Length") or 0)
        if not n:
            return {}
        try:
            return json.loads(self.rfile.read(n).decode("utf-8"))
        except Exception:
            return {}

    def safe_file(self, name):
        p = (DOWNLOAD_DIR / urllib.parse.unquote(name)).resolve()
        if p.parent != DOWNLOAD_DIR or not p.is_file() or p.suffix.lower() not in (".ipa", ".pkg"):
            return None
        return p

    # routes
    def do_GET(self):
        url = urllib.parse.urlparse(self.path)
        # iOS 安装器取清单和 IPA 时不带网站密码，靠链接里的签名放行
        if url.path.startswith(("/install/", "/dl/", "/sdl/")):
            try:
                return self.serve_signed(url.path)
            except IpatoolError as e:
                return self.send_error_json(str(e), 502)
        if not self.authorized():
            return
        q = {k: v[0] for k, v in urllib.parse.parse_qs(url.query).items()}
        try:
            if url.path in ("/", "/index.html"):
                return self.serve_static("index.html")
            if url.path in ("/sign", "/sign.html"):
                return self.serve_static("sign.html")
            if url.path.startswith("/static/"):
                return self.serve_static(url.path[len("/static/"):])
            if url.path == "/api/certs":
                return self.api_certs()
            if url.path == "/api/sign/jobs":
                return self.api_sign_jobs()
            if url.path == "/api/signed":
                return self.api_signed()
            if url.path == "/api/status":
                return self.api_status()
            if url.path == "/api/search":
                return self.api_search(q)
            if url.path == "/api/versions":
                return self.api_versions(q)
            if url.path == "/api/version-meta":
                return self.api_version_meta(q)
            if url.path == "/api/jobs":
                return self.api_jobs()
            if url.path == "/api/files":
                return self.api_files()
            if url.path.startswith("/files/"):
                return self.serve_ipa(url.path[len("/files/"):])
            if url.path == "/api/alist/list":
                return self.api_alist_list(q)
            if url.path == "/api/alist/link":
                if not alist_enabled():
                    return self.send_error_json("还没配置 Alist")
                link, size = alist_link(q.get("name", ""))
                return self.send_json({"ok": True, "url": link, "size": size})
            if url.path == "/api/install":
                return self.api_install(q)
            self.send_error_json("Not found", 404)
        except IpatoolError as e:
            self.send_error_json(str(e), 500)

    def do_POST(self):
        if not self.authorized():
            return
        url = urllib.parse.urlparse(self.path)
        data = self.read_json()
        try:
            if url.path == "/api/login":
                return self.api_login(data)
            if url.path == "/api/logout":
                return self.api_logout(data)
            if url.path == "/api/accounts/switch":
                return self.api_switch_account(data)
            if url.path == "/api/purchase":
                return self.api_purchase(data)
            if url.path == "/api/download":
                return self.api_download(data)
            if url.path == "/api/alist/upload":
                if not alist_enabled():
                    return self.send_error_json("还没配置 Alist：请在 .env 里填写 ALIST_URL、ALIST_USERNAME、ALIST_PASSWORD")
                name = data.get("name") or ""
                if not self.safe_file(name):
                    return self.send_error_json("文件不存在", 404)
                return self.send_json({"ok": True, "upload": enqueue_alist(Path(name).name)})
            if url.path == "/api/certs":
                return self.api_add_cert(data)
            if url.path == "/api/certs/import":
                return self.api_import_certs(data)
            if url.path == "/api/sign":
                job = enqueue_sign(data.get("source") or "alist", data.get("name") or "", data.get("cert") or "")
                return self.send_json({"ok": True, "job": job})
            if url.path == "/api/signed/resign":
                job = enqueue_resign(data.get("key") or "", data.get("cert") or "")
                return self.send_json({"ok": True, "job": job})
            if url.path == "/api/sign/clear":
                with sign_jobs_lock:
                    for k in [k for k, j in sign_jobs.items() if j["status"] in ("done", "error")]:
                        del sign_jobs[k]
                return self.send_json({"ok": True})
            if url.path == "/api/jobs/clear":
                with jobs_lock:
                    for k in [k for k, j in jobs.items() if j["status"] in ("done", "error")]:
                        del jobs[k]
                return self.send_json({"ok": True})
            self.send_error_json("Not found", 404)
        except IpatoolError as e:
            self.send_error_json(str(e), 500)

    def do_PUT(self):
        if not self.authorized():
            return
        url = urllib.parse.urlparse(self.path)
        try:
            if url.path == "/api/upload":
                return self.api_upload(urllib.parse.parse_qs(url.query).get("name", [""])[0])
            self.send_error_json("Not found", 404)
        except IpatoolError as e:
            self.send_error_json(str(e), 400)

    def api_upload(self, name):
        """从手机 / 浏览器上传 IPA（请求体就是文件内容），存到服务器文件里，之后可以签名、安装。"""
        size = int(self.headers.get("Content-Length") or 0)
        base = safe_name_part(name.rsplit(".", 1)[0], 80)
        if not re.search(r"\.t?ipa$", name, re.I) or not base:
            raise IpatoolError("只能上传 .ipa / .tipa 文件")
        if not size:
            raise IpatoolError("文件是空的")
        if size > 8 * 1024 ** 3:
            raise IpatoolError("文件太大了（超过 8 GB）")
        DOWNLOAD_DIR.mkdir(parents=True, exist_ok=True)
        tmp = DOWNLOAD_DIR / f".upload-{uuid.uuid4().hex[:8]}.part"
        try:
            digest, left = hashlib.sha256(), size
            with open(tmp, "wb") as f:
                while left:
                    chunk = self.rfile.read(min(left, 1 << 20))
                    if not chunk:
                        raise IpatoolError("上传中断了，请重试")
                    f.write(chunk)
                    digest.update(chunk)
                    left -= len(chunk)
            try:
                info = ipa_info(tmp)
            except zipfile.BadZipFile:
                raise IpatoolError("不是有效的 IPA 文件")
            with meta_lock:
                # 同名文件内容一样就直接用它，不一样就加序号
                target, n = f"{base}.ipa", 1
                while (DOWNLOAD_DIR / target).exists():
                    existing = DOWNLOAD_DIR / target
                    if existing.stat().st_size == size and _sha256_file(existing) == digest.hexdigest():
                        tmp.unlink()
                        break
                    n += 1
                    target = f"{base}_{n}.ipa"
                else:
                    os.replace(tmp, DOWNLOAD_DIR / target)
                    meta = load_meta()
                    # 不记 bundleID：传上来的不是本站从 App Store 下载的，不能「系统安装」，要签名或 TrollStore 安装
                    meta[target] = {"name": info["appName"], "version": info["version"], "uploaded": True}
                    save_meta(meta)
        finally:
            tmp.unlink(missing_ok=True)
        self.send_json({"ok": True, "name": target, "app": load_meta().get(target)})

    def do_DELETE(self):
        if not self.authorized():
            return
        url = urllib.parse.urlparse(self.path)
        try:
            if url.path.startswith("/api/files/"):
                p = self.safe_file(url.path[len("/api/files/"):])
                if not p:
                    return self.send_error_json("文件不存在", 404)
                p.unlink()  # 应用信息留在 .meta.json 里，Alist 上的同名副本还要用
                return self.send_json({"ok": True})
            if url.path.startswith("/api/certs/"):
                delete_cert(url.path[len("/api/certs/"):])
                return self.send_json({"ok": True})
            if url.path.startswith("/api/signed/"):
                key = urllib.parse.unquote(url.path[len("/api/signed/"):])
                signed_path_of(key).unlink(missing_ok=True)
                with _signed_meta_lock:
                    meta = load_signed_meta()
                    meta.pop(key, None)
                    save_signed_meta(meta)
                return self.send_json({"ok": True})
            self.send_error_json("Not found", 404)
        except IpatoolError as e:
            self.send_error_json(str(e), 400)

    # handlers
    STATIC_TYPES = {".html": "text/html; charset=utf-8", ".css": "text/css; charset=utf-8",
                    ".js": "text/javascript; charset=utf-8"}

    def serve_static(self, name):
        p = (STATIC_DIR / name).resolve()
        if p.parent != STATIC_DIR.resolve() or not p.is_file() or p.suffix not in self.STATIC_TYPES:
            return self.send_error_json("Not found", 404)
        body = p.read_bytes()
        self.send_response(200)
        self.send_header("Content-Type", self.STATIC_TYPES[p.suffix])
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def send_file(self, p):
        size = p.stat().st_size
        self.send_response(200)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Content-Length", str(size))
        self.send_header("Content-Disposition", "attachment; filename*=UTF-8''" + urllib.parse.quote(p.name))
        self.end_headers()
        with p.open("rb") as f:
            shutil.copyfileobj(f, self.wfile, 1024 * 1024)

    def serve_signed(self, path):
        if path.startswith("/dl/"):
            name = verify_signed("dl", path[len("/dl/"):])
            if not name:
                return self.send_error_json("链接无效或已过期", 403)
            return self.serve_ipa(urllib.parse.quote(name))
        if path.startswith("/sdl/"):   # 证书签名后的文件
            key = verify_signed("sdl", path[len("/sdl/"):])
            if not key:
                return self.send_error_json("链接无效或已过期", 403)
            p = signed_path_of(key)
            return self.send_file(p) if p.is_file() else self.send_error_json("文件不存在", 404)
        kind, _, rest = path[len("/install/"):].partition("/")
        if kind not in ("server", "alist", "signed"):
            return self.send_error_json("Not found", 404)
        name = verify_signed("install-" + kind, rest, ".plist")
        if not name:
            return self.send_error_json("链接无效或已过期", 403)
        if kind == "signed":
            info = load_signed_meta().get(name) or {}
            body = plistlib.dumps({"items": [{"assets": [
                {"kind": "software-package", "url": PUBLIC_URL + signed_path("sdl", name, "/sdl")}] + (
                [{"kind": "display-image", "needs-shine": False, "url": info["icon"]}] if info.get("icon") else []),
                "metadata": {"bundle-identifier": info.get("bundleID") or "", "bundle-version": info.get("version") or "1.0",
                             "kind": "software", "title": info.get("appName") or name.partition("/")[2]}}]})
        else:
            ipa_url = PUBLIC_URL + signed_path("dl", name, "/dl") if kind == "server" else alist_link(name)[0]
            body = build_manifest(name, ipa_url)
        self.send_response(200)
        self.send_header("Content-Type", "text/xml; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def api_install(self, q):
        name = check_plain_name(q.get("name", ""))
        if q.get("mode") == "trollstore":
            return self.api_install_trollstore(name, q.get("source", "auto"))
        if not install_enabled():
            return self.send_json({"ok": False, "needHttps": True, "error":
                                   "直接安装需要 HTTPS：请先用 Lucky 等工具给网站配好 https 地址，"
                                   "再在服务器 .env 里设置 IPA_PUBLIC_URL=https://你的域名:端口"})
        info = load_meta().get(name) or {}
        if not info.get("bundleID"):
            return self.send_error_json("这个文件不是本站从 App Store 下载的，不能直接安装；请存到手机后用 TrollStore 等工具安装")
        source = pick_install_source(name, q.get("source", "auto"))
        manifest = PUBLIC_URL + signed_path("install-" + source, name, f"/install/{source}", ".plist")
        self.send_json({"ok": True, "source": source,
                        "url": "itms-services://?action=download-manifest&url=" + urllib.parse.quote(manifest, safe="")})

    def api_install_trollstore(self, name, wanted):
        """TrollStore 的 apple-magnifier://install?url= 链接：TrollStore 自己下载并安装，任何 IPA 都行。"""
        if not name.lower().endswith((".ipa", ".tipa")):
            return self.send_error_json("TrollStore 只能安装 .ipa / .tipa 文件")
        source = pick_install_source(name, wanted)
        if source == "alist":
            ipa_url = alist_link(name)[0]
        else:
            base = PUBLIC_URL or f"http://{self.headers.get('Host')}"
            ipa_url = base + signed_path("dl", name, "/dl")
        ipa_url = urllib.parse.quote(ipa_url, safe=URL_SAFE)
        self.send_json({"ok": True, "source": source,
                        "url": "apple-magnifier://install?url=" + urllib.parse.quote(ipa_url, safe="")})

    def api_alist_list(self, q):
        if not alist_enabled():
            return self.send_error_json("还没配置 Alist")
        items = alist_list(refresh=q.get("refresh") == "1")
        kw = (q.get("q") or "").strip().lower()
        if kw:
            items = [it for it in items if kw in it["name"].lower()]
        offset = max(0, int(q["offset"]) if (q.get("offset") or "").isdigit() else 0)
        limit = max(1, min(int(q["limit"]) if (q.get("limit") or "").isdigit() else 50, 200))
        meta = load_meta()
        page = [dict(it, app=meta.get(it["name"])) for it in items[offset:offset + limit]]
        self.send_json({"ok": True, "total": len(items), "items": page, "dir": ALIST_DIR,
                        "cachedAt": _alist_cache["at"]})

    def serve_ipa(self, name):
        p = self.safe_file(name)
        if not p:
            return self.send_error_json("文件不存在", 404)
        self.send_file(p)

    # ----- 证书签名
    def api_certs(self):
        self.send_json({"ok": True, "zsign": bool(ZSIGN), "installEnabled": install_enabled(), "certs": list_certs()})

    def api_add_cert(self, d):
        try:
            p12 = base64.b64decode(d.get("p12") or "", validate=True)
            profile = base64.b64decode(d.get("profile") or "", validate=True)
        except ValueError:
            return self.send_error_json("文件内容无效")
        if not p12 or not profile:
            return self.send_error_json("请同时选择 .p12 证书和 .mobileprovision 描述文件")
        cert = add_cert((d.get("label") or "").strip()[:40], p12, profile, d.get("password") or "")
        self.send_json({"ok": True, "cert": cert})

    def api_import_certs(self, d):
        files = []
        try:
            for f in (d.get("files") or [])[:20]:
                files.append((str(f.get("name") or ""), base64.b64decode(f.get("data") or "", validate=True)))
        except (ValueError, AttributeError):
            return self.send_error_json("文件内容无效")
        if not files:
            return self.send_error_json("请选择证书 zip 包，或者 .p12 和 .mobileprovision 文件")
        if sum(len(b) for _, b in files) > 30 * 1024 * 1024:
            return self.send_error_json("文件太大了（超过 30 MB），证书包一般只有几十 KB")
        results = import_cert_files(files, d.get("password") or "", (d.get("label") or "").strip()[:40])
        self.send_json({"ok": any(r["ok"] for r in results), "results": results,
                        "error": None if any(r["ok"] for r in results) else "没有导入成功的证书"})

    def api_sign_jobs(self):
        host = self.headers.get("Host")
        with sign_jobs_lock:
            out = []
            for j in sorted(sign_jobs.values(), key=lambda j: j["createdAt"], reverse=True):
                j = dict(j)
                if j["status"] == "done" and j.get("key"):
                    j.update(signed_links(j["key"], host))
                out.append(j)
        self.send_json({"ok": True, "jobs": out})

    def api_signed(self):
        host, certs = self.headers.get("Host"), {c["id"]: c for c in list_certs()}
        items = []
        for key, info in load_signed_meta().items():
            if signed_path_of(key).is_file():
                c = certs.get(info.get("cert"))
                ends = [t for t in ((c or {}).get("certExpires"), (c or {}).get("profileExpires")) if t]
                items.append({"key": key, **info, "certLabel": c.get("label") if c else None,
                              "certDeleted": c is None, "certExpires": min(ends) if ends else None,
                              "teamID": info.get("teamID") or (c or {}).get("teamID"),
                              **signed_links(key, host)})
        items.sort(key=lambda i: i.get("signedAt") or 0, reverse=True)
        self.send_json({"ok": True, "items": items})

    def api_status(self):
        exe = find_ipatool()
        out = {"ok": True, "ipatool": exe, "version": ipatool_version() if exe else None,
               "account": None, "downloadDir": str(DOWNLOAD_DIR), "country": COUNTRY, "relay": RELAY_URL,
               "alist": {"enabled": alist_enabled(), "dir": ALIST_DIR, "auto": ALIST_AUTO_UPLOAD},
               "install": {"enabled": install_enabled(), "publicURL": PUBLIC_URL}}
        acc = current_account()
        out["currentAccount"] = acc
        if exe:
            out["account"] = refresh_account(acc)
        out["accounts"] = account_list()
        self.send_json(out)

    def api_switch_account(self, d):
        acc = d.get("id")
        if acc not in {a["id"] for a in account_list()}:
            return self.send_error_json("没有这个账号")
        with _accounts_lock:
            data = load_accounts()
            data["current"] = acc
            save_accounts(data)
        self.send_json({"ok": True, "currentAccount": acc, "accounts": account_list()})

    def api_logout(self, d):
        acc = d.get("id") or current_account()
        if acc not in load_accounts()["accounts"]:
            return self.send_error_json("没有这个账号")
        remove_account(acc)
        self.send_json({"ok": True, "currentAccount": current_account(), "accounts": account_list()})

    def api_login(self, d):
        global pending_login
        email, password = (d.get("email") or "").strip(), d.get("password") or ""
        code = "".join((d.get("code") or "").split())

        def abandon(s):
            """登录没成功：结束进程；如果是为新账号临时建的目录，一并删掉。"""
            s.kill()
            if s.is_new:
                drop_account_dir(s.account)

        with login_lock:
            if code:
                sess, pending_login = pending_login, None
                if not sess or not sess.alive():
                    if sess:
                        abandon(sess)
                    return self.send_json({"ok": False, "restart": True,
                                           "error": "这次登录已失效（超过 10 分钟或网站重启过），请清空验证码重新登录"})
                if len(code) != 6 or not code.isdigit():
                    pending_login = sess
                    return self.send_json({"ok": False, "needCode": True, "error": "验证码应为 6 位数字"})
                try:
                    lines = sess.submit_code(code)
                except IpatoolError as e:
                    abandon(sess)
                    msg = str(e)
                    if "verification" in msg or "2FA" in msg:
                        msg = f"验证码未通过：{msg}"
                    else:
                        msg = f"登录失败：{msg}"
                    return self.send_json({"ok": False, "restart": True,
                                           "error": msg + "。请清空验证码，重新点登录获取新的验证码"})
            else:
                if not email or not password:
                    return self.send_error_json("请输入 Apple ID 和密码")
                if pending_login:
                    abandon(pending_login)
                    pending_login = None
                # 同一个 Apple ID 再登录会用回它原来的目录；新的 Apple ID 会新建一个账号
                target, is_new = pick_login_target(email, d.get("account"))
                sess = LoginSession(email, password, target, is_new)
                try:
                    if sess.wait_for_prompt(timeout=300) == "code":
                        pending_login = sess
                        return self.send_json({"ok": False, "needCode": True,
                                               "error": "需要双重认证：请在 Apple 设备上点「允许」，把显示的 6 位验证码填到下面，再点登录"})
                    lines = sess.result()
                except IpatoolError:
                    abandon(sess)
                    raise

        info = pick(lines, "email")
        if info.get("success"):
            finish_login(sess.account, info)
            return self.send_json({"ok": True, "account": {"email": info.get("email"), "name": info.get("name")},
                                   "currentAccount": sess.account, "accounts": account_list()})
        abandon(sess)
        self.send_error_json(" ".join(str(l.get("message", "")) for l in lines).strip() or "登录失败")

    def api_search(self, q):
        term = (q.get("q") or "").strip()
        if not term:
            return self.send_error_json("请输入关键词")
        limit = max(1, min(int(q.get("limit") or 20), 50))
        platform = q.get("platform", "")
        if platform not in PLATFORMS:
            platform = ""
        args = ["search", term, "-l", str(limit)]
        if platform:
            args += ["--platform", platform]
        lines = run_ipatool(args)
        apps = [normalize_app(a) for a in (pick(lines, "apps").get("apps") or [])]

        country = (q.get("country") or COUNTRY).lower()[:2]
        meta = itunes_lookup([a["id"] for a in apps if a["id"]], country)
        for a in apps:
            m = meta.get(a["id"], {})
            a["icon"] = m.get("artworkUrl100") or m.get("artworkUrl60")
            a["seller"] = m.get("sellerName") or m.get("artistName")
            a["size"] = int(m["fileSizeBytes"]) if m.get("fileSizeBytes") else None
            a["formattedPrice"] = m.get("formattedPrice")
            a["genre"] = m.get("primaryGenreName")
            a["url"] = m.get("trackViewUrl")
            a["minOS"] = m.get("minimumOsVersion")
            a["rating"] = m.get("averageUserRating")
        self.send_json({"ok": True, "apps": apps})

    def api_versions(self, q):
        bundle = q.get("bundle", "")
        args = ["list-versions", "-b", bundle] if bundle else ["list-versions", "-i", q.get("id", "0")]
        lines = run_ipatool(args, timeout=60)
        ids = pick(lines, "externalVersionIdentifiers").get("externalVersionIdentifiers") or []
        versions = [str(v) for v in reversed(ids)]   # 最新版本放最前
        app = bundle or q.get("id", "0")
        # 顺带返回已经查过的版本号，客户端可以直接显示
        known = {v: _version_cache[version_key(app, v)] for v in versions if version_key(app, v) in _version_cache}
        self.send_json({"ok": True, "versions": versions, "meta": known})

    def api_version_meta(self, q):
        vid = q.get("vid", "")
        app = q.get("bundle") or q.get("id", "0")
        cached = _version_cache.get(version_key(app, vid))
        if cached:
            return self.send_json({"ok": True, "cached": True, **cached})
        args = ["get-version-metadata", "--external-version-id", vid]
        args += ["-b", q["bundle"]] if q.get("bundle") else ["-i", q.get("id", "0")]
        with _version_lookup_slots:
            # Apple 回得很慢：已拥有的 App 约 10 秒，没下载过的可能要一分钟
            info = pick(run_ipatool(args, timeout=180), "displayVersion")
        result = {"displayVersion": info.get("displayVersion"), "releaseDate": info.get("releaseDate")}
        if result["displayVersion"]:
            remember_version(app, vid, result)
        self.send_json({"ok": True, **result})

    def api_purchase(self, d):
        run_ipatool(["purchase", "-b", d.get("bundleID", "")], timeout=90)
        self.send_json({"ok": True})

    def api_download(self, d):
        if not d.get("bundleID") and not d.get("appID"):
            return self.send_error_json("缺少 bundleID")
        job = {
            "id": uuid.uuid4().hex[:10], "status": "queued", "createdAt": time.time(),
            "bundleID": d.get("bundleID"), "appID": d.get("appID"), "name": d.get("name") or d.get("bundleID"),
            "icon": d.get("icon"), "size": d.get("size"),
            "versionID": str(d.get("versionID") or ""), "displayVersion": d.get("displayVersion"),
            "platform": d.get("platform") if d.get("platform") in PLATFORMS else "",
            "country": d.get("country") or COUNTRY,
            "purchase": bool(d.get("purchase")),
            # 记下发起时的账号：之后切换账号不影响这个任务
            "account": current_account(),
            "accountEmail": account_email(current_account()),
        }
        with jobs_lock:
            jobs[job["id"]] = job
        job_queue.put(job["id"])
        self.send_json({"ok": True, "job": job})

    def api_jobs(self):
        with jobs_lock:
            out = []
            for j in sorted(jobs.values(), key=lambda j: j["createdAt"], reverse=True):
                downloaded = job_progress(j)
                j = {k: v for k, v in j.items() if k not in ("workDir", "_sample")}
                j["downloaded"] = downloaded
                out.append(j)
        self.send_json({"ok": True, "jobs": out})

    def api_files(self):
        files = []
        meta = load_meta()
        for p in DOWNLOAD_DIR.iterdir():
            if p.is_file() and p.suffix.lower() in (".ipa", ".pkg"):
                st = p.stat()
                rec = uploads.get(p.name)
                files.append({"name": p.name, "size": st.st_size, "mtime": st.st_mtime,
                              "alist": dict(rec) if rec else None, "app": meta.get(p.name)})
        files.sort(key=lambda f: f["mtime"], reverse=True)
        self.send_json({"ok": True, "files": files})


if __name__ == "__main__":
    try:
        import sys
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass
    if (HOST not in ("127.0.0.1", "localhost", "::1") and not ACCESS_PASSWORD
            and not env_flag("IPA_ALLOW_NO_PASSWORD")):
        print(f"拒绝启动：监听 {HOST} 会让其他设备访问到你的 Apple ID。请设置 IPA_PASSWORD 作为访问密码；"
              "只在可信内网使用、确定不要密码时，设置 IPA_ALLOW_NO_PASSWORD=1。")
        raise SystemExit(1)
    exe = find_ipatool()
    print(f"ipatool: {exe or '未找到！'}")
    print(f"下载目录: {DOWNLOAD_DIR}")
    if ACCESS_PASSWORD:
        print("访问密码: 已设置")
    elif HOST in ("127.0.0.1", "localhost", "::1"):
        print("访问密码: 未设置（仅本机可访问）")
    else:
        print("访问密码: 未设置（已按 IPA_ALLOW_NO_PASSWORD=1 允许网络内任何设备访问）")
    print(f"打开浏览器访问: http://{'127.0.0.1' if HOST in ('0.0.0.0', '') else HOST}:{PORT}", flush=True)
    ThreadingHTTPServer((HOST, PORT), Handler).serve_forever()
