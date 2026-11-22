#!/usr/bin/env python3
"""Publish Scout's framework as a GitHub release, the update Scout finds in Scout → Updates.

    python3 scripts/release.py                    # builds, then releases v<MARKETING_VERSION>
    python3 scripts/release.py --notes notes.md   # release notes shown in Scout
    python3 scripts/release.py --dry-run          # builds the assets into out/release/ only

Bump MARKETING_VERSION in project.yml first: phones only take a release newer than their Scout.
A release carries ScoutKit-<version>.zip (ScoutKit.framework, nothing of Spotify's or Chroma's)
and scout-update.json (its version, size and SHA-256, which Scout checks before using it).
Commit and push first: the release is tagged at the pushed commit.
"""
import argparse, json, subprocess, sys, zipfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import package  # noqa: E402  (build, framework_version, sha256)

ROOT = package.ROOT
REPOSITORY = 'NOTNA9015/Scout'

def git(*args):
    return subprocess.run(['git', *args], cwd=ROOT, check=True, capture_output=True, text=True).stdout.strip()

def check_tree():
    if git('status', '--porcelain'): sys.exit('Commit your changes first: the release is built from the pushed commit.')
    git('fetch', '--quiet', 'origin')
    head = git('rev-parse', 'HEAD')
    if subprocess.run(['git', 'merge-base', '--is-ancestor', head, 'origin/main'], cwd=ROOT).returncode != 0:
        sys.exit('Push first: HEAD is not on origin/main.')
    return head

def zip_framework(framework, output):
    """ScoutKit.framework/… with permissions kept and symlinks refused (Scout won't unpack them)."""
    output.parent.mkdir(parents=True, exist_ok=True)
    output.unlink(missing_ok=True)
    with zipfile.ZipFile(output, 'w', zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
        for path in sorted(framework.rglob('*')):
            relative = path.relative_to(framework)
            if any(part.startswith('.') for part in relative.parts): continue
            if relative.parts[0] in ('Headers', 'Modules', '_CodeSignature'): continue   # see package.SHIPPED_IGNORE
            if path.is_symlink(): sys.exit(f'{relative} is a symlink; Scout does not unpack those.')
            if path.is_dir(): continue
            info = zipfile.ZipInfo(f'ScoutKit.framework/{relative.as_posix()}', date_time=(2026, 1, 1, 0, 0, 0))
            info.external_attr = (0o100000 | (path.stat().st_mode & 0o777)) << 16
            info.compress_type = zipfile.ZIP_DEFLATED
            info.create_system = 3
            archive.writestr(info, path.read_bytes())

def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--notes', type=Path, help='release notes (Markdown); shown in Scout → Updates')
    parser.add_argument('--skip-build', action='store_true', help='reuse the last Release build')
    parser.add_argument('--dry-run', action='store_true', help='build the assets without publishing')
    args = parser.parse_args()

    head = None if args.dry_run else check_tree()
    framework = package.build(args.skip_build)
    version = package.framework_version(framework)
    binary = (framework / 'ScoutKit').read_bytes()[:16]
    if binary[:4] != b'\xcf\xfa\xed\xfe' or binary[4:8] != b'\x0c\x00\x00\x01': sys.exit('ScoutKit is not an arm64 device build.')

    out = ROOT / 'out' / 'release'
    asset = out / f'ScoutKit-{version}.zip'
    zip_framework(framework, asset)
    spotify = []
    base = Path.home() / 'Downloads/chroma-1.1.0.ipa'
    if base.exists(): spotify = [package.inspect(base)['info'].get('CFBundleShortVersionString')]
    manifest = {'version': version, 'framework': {'name': asset.name, 'sha256': package.sha256(asset), 'size': asset.stat().st_size},
                'spotify': [v for v in spotify if v], 'commit': head}
    (out / 'scout-update.json').write_text(json.dumps(manifest, indent=2) + '\n')
    print(json.dumps(manifest, indent=2))
    if args.dry_run: print(f'Assets in {out}; nothing published.'); return

    tag = f'v{version}'
    if subprocess.run(['gh', 'release', 'view', tag, '--repo', REPOSITORY], cwd=ROOT, capture_output=True).returncode == 0:
        sys.exit(f'{tag} is already released. Bump MARKETING_VERSION in project.yml.')
    notes = args.notes.read_text() if args.notes else f'Scout {version}.'
    package.run(['gh', 'release', 'create', tag, str(asset), str(out / 'scout-update.json'), '--repo', REPOSITORY,
                 '--target', head, '--title', f'Scout {version}', '--notes', notes], cwd=ROOT)

if __name__ == '__main__':
    main()
