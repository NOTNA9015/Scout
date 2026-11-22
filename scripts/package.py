#!/usr/bin/env python3
"""Inject ScoutKit into a spoti.pw-based IPA, the same way spoti.pw is injected into Spotify.

    python3 scripts/package.py            # ~/Downloads/chroma-1.1.0.ipa -> out/Scout-chroma-1.1.0-unsigned.ipa

Another base can be passed (e.g. ~/Downloads/spoti.pw-0.51.0.ipa); the output is named after it
unless -o is given. The input IPA is never modified. The result is unsigned; sign it like the base IPA.
"""
import argparse, hashlib, json, plistlib, shutil, subprocess, sys, tempfile, zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

def run(command, **kwargs):
    print('$', ' '.join(str(c) for c in command), flush=True)
    return subprocess.run(command, check=True, **kwargs)

def sha256(path):
    digest = hashlib.sha256()
    with open(path, 'rb') as handle:
        for block in iter(lambda: handle.read(1 << 20), b''): digest.update(block)
    return digest.hexdigest()

def inspect(path):
    with zipfile.ZipFile(path) as archive:
        names = archive.namelist()
        infos = [n for n in names if n.startswith('Payload/') and n.count('/') == 2 and n.endswith('/Info.plist')]
        if len(infos) != 1: sys.exit('Not an app IPA: expected one Payload/*.app/Info.plist')
        app = infos[0].rsplit('/', 1)[0]
        info = plistlib.loads(archive.read(infos[0]))
        return {'app': app, 'info': info,
                'spotipw': f'{app}/Frameworks/spotifyglass.dylib' in names,
                'scout': any(n.startswith(f'{app}/Frameworks/ScoutKit.framework/') for n in names),
                'executable': f"{app}/{info['CFBundleExecutable']}"}

def framework_version(framework):
    """Scout's version, from the framework (MARKETING_VERSION in project.yml)."""
    version = plistlib.loads((framework / 'Info.plist').read_bytes()).get('CFBundleShortVersionString')
    if not version: sys.exit('ScoutKit.framework has no version; set MARKETING_VERSION in project.yml')
    return version

def framework_build(framework):
    """Scout's build, from the framework (CURRENT_PROJECT_VERSION in project.yml): what orders releases."""
    build = plistlib.loads((framework / 'Info.plist').read_bytes()).get('CFBundleVersion', '')
    if not build.isdigit(): sys.exit('ScoutKit.framework has no build number; set CURRENT_PROJECT_VERSION in project.yml')
    return int(build)

# Only what the app runs: Headers/ and Modules/ are for compiling against Scout, and the module
# files carry this Mac's source paths.
SHIPPED_IGNORE = shutil.ignore_patterns('Headers', 'Modules', '_CodeSignature', '.*')

def build(skip):
    product = ROOT / 'build/release/Release-iphoneos/ScoutKit.framework'
    if skip and product.exists(): return product
    run(['xcodegen', 'generate'], cwd=ROOT, stdout=subprocess.DEVNULL)
    run(['xcodebuild', '-project', 'Scout.xcodeproj', '-target', 'ScoutKit', '-configuration', 'Release', '-sdk', 'iphoneos',
         f'SYMROOT={ROOT / "build/release"}', 'CODE_SIGNING_ALLOWED=NO', 'build'], cwd=ROOT, stdout=subprocess.DEVNULL)
    if not product.exists(): sys.exit('ScoutKit.framework was not built')
    return product

def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('ipa', type=Path, nargs='?', default=Path.home() / 'Downloads/chroma-1.1.0.ipa')
    parser.add_argument('-o', '--output', type=Path, help='default: out/Scout-<base name>-unsigned.ipa')
    parser.add_argument('--skip-build', action='store_true', help='reuse the last Release build')
    args = parser.parse_args()
    if args.output is None: args.output = ROOT / 'out' / f'Scout-{args.ipa.stem}-unsigned.ipa'

    source = inspect(args.ipa)
    if not source['spotipw']: sys.exit('This IPA has no spotifyglass.dylib; pass a spoti.pw-based IPA (Chroma or spoti.pw).')
    if source['scout']: sys.exit('This IPA already contains Scout; start from the plain base IPA.')
    before = sha256(args.ipa)
    framework = build(args.skip_build)
    version = framework_version(framework)

    args.output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory() as work:
        merge = Path(work) / 'Info.plist'
        merge.write_bytes(plistlib.dumps({
            'UIFileSharingEnabled': True, 'LSSupportsOpeningDocumentsInPlace': True,
            'NSSpeechRecognitionUsageDescription': 'Scout writes timed lyrics from your audio on this iPhone.',
            'ScoutVersion': version}))
        staged = Path(work) / 'ScoutKit.framework'
        shutil.copytree(framework, staged, ignore=SHIPPED_IGNORE)
        if args.output.exists(): args.output.unlink()
        run(['cyan', '-i', args.ipa, '-o', args.output, '-f', staged, '-l', merge, '-c', '6', '--overwrite'])

        # The result must still be spoti.pw, now with Scout loaded by the main binary.
        result = inspect(args.output)
        if not (result['spotipw'] and result['scout']): sys.exit('Injected IPA is missing spoti.pw or Scout')
        with zipfile.ZipFile(args.output) as archive:
            binary = Path(work) / 'main'
            binary.write_bytes(archive.read(result['executable']))
        links = subprocess.run(['otool', '-L', binary], capture_output=True, text=True, check=True).stdout
        if 'ScoutKit.framework/ScoutKit' not in links: sys.exit('The app binary does not load ScoutKit')
        if 'spotifyglass' not in links: sys.exit('The app binary no longer loads spoti.pw')

    if sha256(args.ipa) != before: sys.exit('The input IPA changed; this should never happen')
    receipt = {'output': args.output.name, 'sha256': sha256(args.output), 'input': args.ipa.name, 'inputSHA256': before,
               'spotifyVersion': source['info'].get('CFBundleShortVersionString'), 'scoutVersion': version,
               'signing': 'unsigned', 'deviceValidated': False}
    args.output.with_suffix('.json').write_text(json.dumps(receipt, indent=2) + '\n')
    print(json.dumps(receipt, indent=2))

if __name__ == '__main__':
    main()
