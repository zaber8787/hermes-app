#!/usr/bin/env python3
"""Bounded official downloads; keep diagnostics on failure. No system cleanup."""
import hashlib,json,shutil,subprocess,sys,urllib.request,xml.etree.ElementTree as ET
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
SDK=ROOT/'toolchain'
SDK.mkdir(exist_ok=True)

def run(*args):
    print('+',*map(str,args),flush=True)
    subprocess.run(list(map(str,args)),check=True,timeout=1800,cwd=ROOT)

def space(gib=8):
    free=shutil.disk_usage(ROOT).free/1024**3
    print(f'Disk free: {free:.1f} GiB; minimum {gib}',flush=True)
    if free<gib:raise RuntimeError('Not enough free disk; stopping without deleting user files')

def digest(path, algorithm):
    value=hashlib.new(algorithm)
    with path.open('rb') as handle:
        for block in iter(lambda:handle.read(1024*1024),b''):value.update(block)
    return value.hexdigest()

def fetch(url,path,checksum=None,algorithm='sha256'):
    if path.exists() and checksum and digest(path,algorithm)==checksum:return
    print('Download:',url,flush=True)
    run('curl','--fail','--location','--retry','2','--connect-timeout','20','--max-time','1200','--speed-limit','16384','--speed-time','60','--silent','--show-error',url,'--output',path)
    if checksum:
        h=hashlib.new(algorithm)
        with path.open('rb') as f:
            for block in iter(lambda:f.read(1024*1024),b''):h.update(block)
        if h.hexdigest()!=checksum:raise RuntimeError(f'Checksum mismatch: {path.name}')
        print('Checksum verified:',path.name,flush=True)

try:
    space(12)
    jdk=SDK/'jdk/usr/lib/jvm/java-21-openjdk-amd64'
    if not (jdk/'bin/javac').exists():
        downloads=SDK/'jdk-downloads'
        downloads.mkdir(exist_ok=True)
        print('Download official Ubuntu JDK/JRE 21 packages (extract locally, no system install)',flush=True)
        subprocess.run(['apt-get','-o','Acquire::Retries=2','-o','Acquire::http::Timeout=30',
            'download','openjdk-21-jdk-headless','openjdk-21-jre-headless'],
            cwd=downloads,check=True,timeout=600)
        for package in downloads.glob('*.deb'):
            run('dpkg-deb','-x',package,SDK/'jdk')
    run(jdk/'bin/javac','-version')
    manifest=SDK/'releases_linux.json'
    fetch('https://storage.googleapis.com/flutter_infra_release/releases/releases_linux.json',manifest)
    data=json.loads(manifest.read_text())
    release=next(r for r in data['releases'] if r['hash']==data['current_release']['stable'] and r.get('dart_sdk_arch','x64')=='x64')
    (SDK/'flutter-release.json').write_text(json.dumps(release,indent=2))
    archive=SDK/'flutter-stable.tar.xz'
    if not (SDK/'flutter/bin/flutter').exists():
        fetch('https://storage.googleapis.com/flutter_infra_release/releases/'+release['archive'],archive,release['sha256'])
        space()
        run('tar','xf',archive,'-C',SDK)
        archive.unlink()  # Only our verified, successfully extracted download.
    space()
    run(SDK/'flutter/bin/flutter','--version')
    repo=SDK/'android-repository.xml'
    fetch('https://dl.google.com/android/repository/repository2-1.xml',repo)
    package=next(p for p in ET.parse(repo).getroot() if p.tag.endswith('remotePackage') and p.get('path')=='cmdline-tools;latest')
    entry=next(a.find('complete') for a in package.findall('./archives/archive') if a.findtext('host-os')=='linux')
    zipfile=SDK/'commandlinetools.zip'
    target=SDK/'android-sdk/cmdline-tools/latest'
    if not target.exists():
        fetch('https://dl.google.com/android/repository/'+entry.findtext('url'),zipfile,entry.findtext('checksum'),'sha1')
        staging=SDK/'android-unpack'
        run('unzip','-q',zipfile,'-d',staging)
        target.parent.mkdir(parents=True,exist_ok=True)
        shutil.move(str(staging/'cmdline-tools'),target)
        staging.rmdir()
        zipfile.unlink()
    run('bash','-c','source scripts/env.sh; yes | sdkmanager --licenses >/dev/null; sdkmanager "platform-tools" "platforms;android-34" "build-tools;34.0.0" "platforms;android-36" "build-tools;36.0.0"',)
    space(4)
    run('bash','-c','source scripts/env.sh; flutter config --android-sdk "$ANDROID_HOME"; flutter doctor -v')
except Exception as e:
    print('INSTALL FAILED:',e,flush=True)
    sys.exit(1)
