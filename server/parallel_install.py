"""Prepare a separately identified app before signing; never modify the source IPA."""

import hashlib
import plistlib
import re
import shutil
import zipfile


class ParallelInstallError(ValueError):
    pass


def validate_copy_name(value):
    if not isinstance(value, str) or len(value) > 40 or any(ord(c) < 32 for c in value):
        raise ParallelInstallError("副本名称最多 40 个字符，不能包含换行或控制字符")
    return value.strip()


def profile_allows(app_id, bundle_id):
    # The App ID prefix may differ from TeamIdentifier on older accounts.
    prefix, dot, pattern = (app_id or "").partition(".")
    if not prefix or not dot or not pattern:
        return False
    if "*" not in pattern:
        return pattern == bundle_id
    return pattern.count("*") == 1 and pattern.endswith("*") and bundle_id.startswith(pattern[:-1])


def parallel_identity(info, cert, copy_name="", previous=None):
    previous = previous or {}
    original = previous.get("originalBundleID") or info.get("bundleID") or ""
    if not re.fullmatch(r"[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+", original):
        raise ParallelInstallError("应用标识无效，不能生成并存副本")
    target = previous.get("parallelBundleID")
    if not target:
        pattern = (cert.get("appID") or "").partition(".")[2]
        if "*" not in pattern or not pattern.endswith("*") or pattern.count("*") != 1:
            raise ParallelInstallError("并存安装需要允许修改应用标识的通配描述文件（App ID 含 *）；当前描述文件不支持")
        target = original + ".ipasitecopy"
        if len(target) > 255 or not profile_allows(cert.get("appID"), target):
            # A restricted wildcard can only sign apps within its own namespace.
            target = pattern[:-1] + "ipasitecopy." + hashlib.sha256(original.encode()).hexdigest()[:16]
    if (target == original or len(target) > 255
            or not re.fullmatch(r"[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+", target)
            or not profile_allows(cert.get("appID"), target)):
        raise ParallelInstallError("这个描述文件不允许副本的应用标识；请选用匹配的证书和描述文件，副本标识不会自动更换")
    original_name = previous.get("originalAppName") or info.get("appName") or "应用"
    name = validate_copy_name(copy_name) or previous.get("copyName") or (original_name[:37] + " 副本")
    return {"parallelInstall": True, "parallelBundleID": target, "copyName": name,
            "originalBundleID": original, "originalAppName": original_name}


def _localized_name(data, name):
    try:
        values = plistlib.loads(data)
    except (ValueError, plistlib.InvalidFileException):
        encoding = "utf-16" if data.startswith((b"\xff\xfe", b"\xfe\xff")) else "utf-8-sig"
        try:
            text = data.decode(encoding)
        except UnicodeError as exc:
            raise ParallelInstallError("无法读取本地化应用名称，未生成副本") from exc
        quoted = '"' + name.replace("\\", "\\\\").replace('"', '\\"') + '"'
        for key in ("CFBundleName", "CFBundleDisplayName"):
            pattern = rf'(?m)(?:"{key}"|\b{key}\b)\s*=\s*"(?:\\.|[^"\\])*"\s*;'
            text = re.sub(pattern, lambda _: f'"{key}" = {quoted};', text)
        return text.encode(encoding)
    if not isinstance(values, dict):
        raise ParallelInstallError("本地化名称文件格式无效")
    values.update(CFBundleName=name, CFBundleDisplayName=name)
    return plistlib.dumps(values, fmt=plistlib.FMT_BINARY)


def prepare_parallel_ipa(source, destination, identity):
    """Stream ZIP entries without filesystem extraction, preserving binary and symlink metadata."""
    with zipfile.ZipFile(source) as archive:
        names = archive.namelist()
        if len(set(names)) != len(names):
            raise ParallelInstallError("IPA 包含重复路径，不能生成并存副本")
        for path in names:
            if path.startswith("/") or "\\" in path or ".." in path.split("/"):
                raise ParallelInstallError("IPA 包含无效路径")
        roots = [path for path in names if re.fullmatch(r"Payload/[^/]+\.app/Info\.plist", path)]
        if len(roots) != 1:
            raise ParallelInstallError("IPA 必须只包含一个主应用")
        root = roots[0][:-len("Info.plist")]
        removed = (root + "PlugIns/", root + "Extensions/", root + "Watch/", root + "AppClips/",
                   "WatchKitSupport/", "WatchKitSupport2/")
        with zipfile.ZipFile(destination, "w", allowZip64=True) as output:
            for entry in archive.infolist():
                path = entry.filename
                if path.startswith(removed):
                    continue
                if path.startswith(root) and path != root and any(
                        part.endswith((".app", ".appex")) for part in path[len(root):].split("/")):
                    raise ParallelInstallError("发现不支持的嵌套应用，未生成并存副本")
                if path == roots[0]:
                    values = plistlib.loads(archive.read(entry))
                    values.update(CFBundleIdentifier=identity["parallelBundleID"],
                                  CFBundleName=identity["copyName"], CFBundleDisplayName=identity["copyName"])
                    # Let the official app keep its existing custom URL schemes.
                    for key in ("CFBundleURLTypes", "WKWatchKitApp", "WKCompanionAppBundleIdentifier"):
                        values.pop(key, None)
                    output.writestr(entry, plistlib.dumps(values, fmt=plistlib.FMT_BINARY))
                elif re.fullmatch(re.escape(root) + r"[^/]+\.lproj/InfoPlist\.strings", path):
                    output.writestr(entry, _localized_name(archive.read(entry), identity["copyName"]))
                else:
                    with archive.open(entry) as src, output.open(entry, "w", force_zip64=True) as dest:
                        shutil.copyfileobj(src, dest, 1 << 20)
