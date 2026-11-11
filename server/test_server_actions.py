"""HTTP integration against an isolated server and deterministic CLI fixtures."""

import base64
import json
import os
from pathlib import Path
import plistlib
import socket
import struct
import subprocess
import sys
import tempfile
import time
import unittest
import urllib.error
import urllib.request
import zipfile


CLI = '''#!/usr/bin/env python3
import json, pathlib, plistlib, shutil, struct, sys, time, zipfile
args=sys.argv[1:]
if '--version' in args:
 print('ipatool version fixture');sys.exit(0)
if 'auth' in args:
 print(json.dumps({'email':'fixture@example.invalid','name':'Fixture','success':True}));sys.exit(0)
if '-k' in args:
 shutil.copyfile(args[-1],args[args.index('-o')+1]);sys.exit(0)
dest=pathlib.Path(args[args.index('-o')+1]);dest.mkdir(parents=True,exist_ok=True)
part=dest/'progress.tmp'
for _ in range(100):
 with part.open('ab') as f:f.write(b'x'*1024)
 time.sleep(.03)
out=dest/'com.example.fixture_1_1.ipa'
with zipfile.ZipFile(out,'w') as z:
 z.writestr('Payload/Fixture.app/Info.plist',plistlib.dumps({'CFBundleIdentifier':'com.example.fixture','CFBundleName':'Fixture','CFBundleShortVersionString':'1.0','CFBundleExecutable':'Fixture'}))
 z.writestr('Payload/Fixture.app/Fixture',struct.pack('<IIIIIIII',0xfeedfacf,0x100000c,0,2,0,0,0,0))
print(json.dumps({'output':str(out),'purchased':False}))
'''


@unittest.skipUnless(os.name == "posix", "Linux CLI fixtures and process groups")
class ServerActionTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory()
        cls.root = Path(cls.temp.name)
        cls.downloads = cls.root / 'downloads'
        cls.downloads.mkdir()
        tool = cls.root / 'fixture-cli'
        tool.write_text(CLI)
        tool.chmod(0o700)
        certdir = cls.root / 'certs' / 'aabbccdd'
        certdir.mkdir(parents=True)
        (certdir / 'cert.json').write_text(json.dumps({'id':'aabbccdd','password':'fixture','appID':'PREFIX.*','teamID':'TEAM',
            'certExpires':time.time()+86400,'profileExpires':time.time()+86400,'matchesProfile':True}))
        with socket.socket() as s:
            s.bind(('127.0.0.1', 0))
            port = s.getsockname()[1]
        cls.url = f'http://127.0.0.1:{port}'
        cls.auth = 'Basic '+base64.b64encode(b'test:fixture-password').decode()
        env = dict(os.environ, IPA_HOST='127.0.0.1', IPA_PORT=str(port), IPA_CONCURRENCY='1',
                   IPA_PASSWORD='fixture-password', IPA_DOWNLOAD_DIR=str(cls.downloads),
                   IPA_PASSPHRASE_FILE=str(cls.root / '.keychain-passphrase'),
                   IPATOOL_PATH=str(tool), ZSIGN_PATH=str(tool), HOME=str(cls.root),
                   IPA_SIGN_DIR=str(cls.root / 'signed'))
        for key in list(env):
            if key.startswith(('ALIST_', 'IPATOOL_STORE_PROOF_')):
                env.pop(key)
        cls.log = (cls.root / 'server.log').open('w+')
        cls.process = subprocess.Popen([sys.executable, str(Path(__file__).with_name('server.py'))],
                                       env=env, stdout=cls.log, stderr=cls.log)
        try:
            cls.wait(lambda: cls.request('/api/jobs')['ok'], timeout=10)
        except Exception:
            cls.process.terminate()
            cls.process.wait(5)
            cls.log.seek(0)
            raise AssertionError(cls.log.read())

    @classmethod
    def tearDownClass(cls):
        cls.process.terminate()
        cls.process.wait(5)
        cls.log.close()
        cls.temp.cleanup()

    @classmethod
    def request(cls, path, body=None, method=None, authenticated=True):
        headers = {'Authorization':cls.auth} if authenticated else {}
        if body is not None:
            headers['Content-Type']='application/json'
        req = urllib.request.Request(cls.url+path, headers=headers,
            data=None if body is None else json.dumps(body).encode(), method=method)
        with urllib.request.urlopen(req, timeout=15) as response:
            return json.load(response)

    @staticmethod
    def wait(predicate, timeout=8):
        deadline = time.monotonic()+timeout
        while time.monotonic()<deadline:
            try:
                result=predicate()
                if result:return result
            except (OSError, KeyError, StopIteration):
                pass
            time.sleep(.05)
        raise AssertionError('timed out waiting for fixture')

    def job(self, job_id):
        return next(j for j in self.request('/api/jobs')['jobs'] if j['id']==job_id)

    def download(self):
        return self.request('/api/download', {'bundleID':'com.example.fixture','name':'Fixture'})['job']['id']

    def test_download_actions_preserve_completed_file_and_keep_queue_alive(self):
        job_id=self.download()
        self.wait(lambda: (self.job(job_id).get('downloaded') or 0)>2048)
        self.request('/api/jobs/'+job_id, {'action':'pause'})
        time.sleep(.15)
        paused=self.job(job_id)
        self.assertEqual(paused['status'],'paused')
        time.sleep(.25)
        self.assertEqual(self.job(job_id)['downloaded'],paused['downloaded'])
        self.request('/api/jobs/'+job_id, {'action':'resume'})
        done=self.wait(lambda: (j if (j:=self.job(job_id))['status']=='done' else None))
        completed=self.downloads/done['file']
        self.assertTrue(completed.is_file())
        self.request('/api/jobs/'+job_id, method='DELETE')
        self.assertTrue(completed.is_file())
        self.assertFalse(any(j['id']==job_id for j in self.request('/api/jobs')['jobs']))
        # Delete an active paused job, then start another: one worker must survive.
        job_id=self.download()
        self.wait(lambda: (self.job(job_id).get('downloaded') or 0)>1024)
        self.request('/api/jobs/'+job_id, {'action':'pause'})
        self.request('/api/jobs/'+job_id, method='DELETE')
        self.wait(lambda: not (self.downloads/'.partial'/job_id).exists())
        next_id=self.download()
        self.wait(lambda: self.job(next_id)['status']=='running')
        self.request('/api/jobs/'+next_id, {'action':'cancel'})
        self.assertEqual(self.job(next_id)['status'],'cancelled')
        self.wait(lambda: not (self.downloads/'.partial'/next_id).exists())

    def test_control_routes_require_auth_and_validate_actions(self):
        with self.assertRaises(urllib.error.HTTPError) as caught:
            self.request('/api/jobs/no-such-job', {'action':'pause'}, authenticated=False)
        self.assertEqual(caught.exception.code,401)
        with self.assertRaises(urllib.error.HTTPError):
            self.request('/api/jobs/no-such-job', {'action':'invalid'})

    def test_parallel_sign_and_resign_keep_identity_and_original(self):
        source=self.downloads/'original.ipa'
        with zipfile.ZipFile(source,'w') as z:
            z.writestr('Payload/Fixture.app/Info.plist',plistlib.dumps({'CFBundleIdentifier':'com.example.fixture',
                'CFBundleDisplayName':'Fixture','CFBundleExecutable':'Fixture','CFBundleShortVersionString':'1.0'}))
            z.writestr('Payload/Fixture.app/Fixture',struct.pack('<IIIIIIII',0xfeedfacf,0x100000c,0,2,0,0,0,0))
        original=source.read_bytes()
        job=self.request('/api/sign',{'source':'server','name':source.name,'cert':'aabbccdd',
                                     'parallelInstall':True,'copyName':'Fixture copy'})['job']
        def sign_done(job_id):
            j=next(x for x in self.request('/api/sign/jobs')['jobs'] if x['id']==job_id)
            if j['status']=='error':self.fail(j['error'])
            return j if j['status']=='done' else None
        first=self.wait(lambda:sign_done(job['id']))
        self.assertEqual(first['bundleID'],'com.example.fixture.ipasitecopy')
        self.assertEqual(first['appName'],'Fixture copy')
        self.assertEqual(source.read_bytes(),original)
        rejob=self.request('/api/signed/resign',{'key':first['key'],'cert':'aabbccdd'})['job']
        second=self.wait(lambda:sign_done(rejob['id']))
        self.assertEqual(first['bundleID'],second['bundleID'])
        self.assertEqual(first['key'],second['key'])
        signed=self.request('/api/signed')['items']
        self.assertTrue(next(x for x in signed if x['key']==first['key'])['parallelInstall'])


if __name__=='__main__':
    unittest.main()
