import hashlib
from pathlib import Path
import plistlib
import tempfile
import unittest
import zipfile

from parallel_install import (ParallelInstallError, parallel_identity, prepare_parallel_ipa,
                              profile_allows, validate_copy_name)


class ParallelInstallTests(unittest.TestCase):
    def setUp(self):
        self.info = {"bundleID": "com.example.reader", "appName": "阅读器"}
        self.cert = {"appID": "PREFIX.*", "teamID": "TEAM"}

    def test_identity_is_stable_across_versions_names_and_wildcard_certificates(self):
        first = parallel_identity(self.info, self.cert, "阅读副本")
        second = parallel_identity({**self.info, "version": "2"}, {"appID": "OTHER.*"}, "另一个名称")
        self.assertEqual(first["parallelBundleID"], second["parallelBundleID"])
        self.assertNotEqual(first["parallelBundleID"], self.info["bundleID"])
        self.assertEqual(first["copyName"], "阅读副本")

    def test_restricted_wildcard_uses_allowed_namespace(self):
        cert = {"appID": "PREFIX.org.personal.*"}
        identity = parallel_identity(self.info, cert)
        self.assertTrue(profile_allows(cert["appID"], identity["parallelBundleID"]))
        self.assertTrue(identity["parallelBundleID"].startswith("org.personal."))

    def test_explicit_profile_uses_exact_identity_and_cannot_reuse_original_identity(self):
        identity = parallel_identity(self.info, {"appID": "PREFIX.org.personal.copy"})
        self.assertEqual(identity["parallelBundleID"], "org.personal.copy")
        with self.assertRaises(ParallelInstallError):
            parallel_identity(self.info, {"appID": "PREFIX.com.example.reader"})

    def test_resign_preserves_copy_and_does_not_rename_it_repeatedly(self):
        identity = parallel_identity(self.info, self.cert)
        copied_info = {"bundleID": identity["parallelBundleID"], "appName": identity["copyName"]}
        result = parallel_identity(copied_info, self.cert, previous=identity)
        self.assertEqual(result, identity)
        explicit = {"appID": "PREFIX." + identity["parallelBundleID"]}
        self.assertEqual(parallel_identity(copied_info, explicit, previous=identity), identity)
        with self.assertRaises(ParallelInstallError):
            parallel_identity(copied_info, {"appID": "PREFIX.org.different.*"}, previous=identity)

    def test_profile_prefix_is_not_assumed_to_equal_team_id(self):
        self.assertTrue(profile_allows("PREFIX.com.example.*", "com.example.reader"))
        self.assertFalse(profile_allows("PREFIX.com.example.*", "com.exampleevil.reader"))
        self.assertFalse(profile_allows("PREFIX.com.*.bad", "com.any.bad"))
        self.assertFalse(profile_allows(None, "com.example.reader"))

    def test_invalid_copy_names_rejected(self):
        for value in (None, [], "x" * 41, "name\n", "name\x00"):
            with self.assertRaises(ParallelInstallError):
                validate_copy_name(value)

    def test_zip_keeps_executable_and_source_but_removes_conflicting_components(self):
        with tempfile.TemporaryDirectory() as tmp:
            source, dest = Path(tmp) / "source.ipa", Path(tmp) / "copy.ipa"
            root = "Payload/Reader.app/"
            with zipfile.ZipFile(source, "w") as z:
                z.writestr(root + "Info.plist", plistlib.dumps({"CFBundleIdentifier": self.info["bundleID"],
                    "CFBundleDisplayName": "阅读器", "CFBundleURLTypes": [{"CFBundleURLSchemes": ["reader"]}]}))
                executable = zipfile.ZipInfo(root + "Reader")
                executable.external_attr = 0o100755 << 16
                z.writestr(executable, b"executable unchanged")
                z.writestr(root + "PlugIns/Share.appex/Info.plist", b"removed")
                z.writestr(root + "Watch/Watch.app/Info.plist", b"removed")
                z.writestr(root + "AppClips/Clip.app/Info.plist", b"removed")
                z.writestr(root + "en.lproj/InfoPlist.strings", b'"CFBundleDisplayName" = "Reader";')
                z.writestr(root + "zh-Hans.lproj/InfoPlist.strings", plistlib.dumps({"CFBundleName": "阅读器"}, fmt=plistlib.FMT_BINARY))
                z.writestr(root + "Frameworks/Keep.framework/Keep", b"keep framework")
            digest = hashlib.sha256(source.read_bytes()).digest()
            identity = parallel_identity(self.info, self.cert)
            prepare_parallel_ipa(source, dest, identity)
            self.assertEqual(hashlib.sha256(source.read_bytes()).digest(), digest)
            with zipfile.ZipFile(dest) as z:
                self.assertIsNone(z.testzip())
                info = plistlib.loads(z.read(root + "Info.plist"))
                self.assertEqual(info["CFBundleIdentifier"], identity["parallelBundleID"])
                self.assertEqual(info["CFBundleDisplayName"], "阅读器 副本")
                self.assertNotIn("CFBundleURLTypes", info)
                self.assertFalse(any("PlugIns/" in n or "/Watch/" in n or "AppClips/" in n for n in z.namelist()))
                self.assertEqual(z.read(root + "Reader"), b"executable unchanged")
                self.assertEqual(z.getinfo(root + "Reader").external_attr, executable.external_attr)
                self.assertEqual(z.read(root + "Frameworks/Keep.framework/Keep"), b"keep framework")
                self.assertIn("阅读器 副本", z.read(root + "en.lproj/InfoPlist.strings").decode())
                self.assertEqual(plistlib.loads(z.read(root + "zh-Hans.lproj/InfoPlist.strings"))["CFBundleName"], "阅读器 副本")

    def test_ambiguous_or_unsafe_archive_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            source, dest = Path(tmp) / "source.ipa", Path(tmp) / "copy.ipa"
            for bad in ("../escape", "Payload/Other.app/Info.plist", "Payload/Reader.app/Unknown/Nested.app/Info.plist"):
                with zipfile.ZipFile(source, "w") as z:
                    z.writestr("Payload/Reader.app/Info.plist", plistlib.dumps({}))
                    z.writestr(bad, b"unsafe")
                with self.assertRaises(ParallelInstallError):
                    prepare_parallel_ipa(source, dest, parallel_identity(self.info, self.cert))


if __name__ == "__main__":
    unittest.main()
