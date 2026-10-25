# Mac Sai Personal

This personal fork is based on upstream v1.25.7 (commit
`6bd8f7eac5e443c0ef6c88e81a1144ed2fe8fd6a`). It intentionally does not include
the unpublished v1.26.0 changes from upstream main.

## Install this version on your Mac

Requires macOS 14 or later and a Swift 6.1 toolchain (Xcode 16.3 or later).
Open Xcode once after installing or updating it to complete its setup.

```bash
git clone https://github.com/ammarabdulaziz/MacSai.git
cd MacSai
bash scripts/install-personal.sh
```

If manifest loading fails with `Undefined symbols` referring to
`PackageDescription`, check the selected toolchain with `xcode-select -p`,
`xcrun --find swift`, and `xcrun swift --version`. An incomplete or mismatched
Command Line Tools installation can cause this before any app code is built.
With a complete Xcode installation at `/Applications/Xcode.app`, select its
toolchain for this build only:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer bash scripts/install-personal.sh
```

This does not change the system-wide `xcode-select` setting. If Xcode is elsewhere,
adjust the path. The installer checks Swift's version and loads the manifest
before resolving dependencies or installing anything.

The installer runs the full tests, compiles the current source for your Mac,
verifies the local code signature, and installs `~/Applications/Mac Sai Personal.app`.
It preserves the previous personal build for rollback. It does not install the
upstream Homebrew cask or run a downloaded executable. Do not use
`brew install --cask mac-sai` to get these changes; that installs upstream.

The custom app has its own bundle identifiers and preference suite. Automatic
update checks and the menu-bar login widget default to off. Full Disk Access is
not granted by the installer. You can grant it manually if you need a particular
protected-area scan, and revoke it after that scan. Administrator operations
still require the standard macOS authorization prompt.

The dependency lockfile pins the GRDB revision used by the macOS build.
Use `swift package resolve --force-resolved-versions` when checking a build;
review dependency updates explicitly rather than discarding the lockfile.

## Changes

- Cleanup and Shredder pin directory descriptors, refuse symlink traversal,
  atomically stage the selected entry, and verify its identity after the move.
  Scan inode/device identity is checked when supplied. Nested symlinks in a
  deleted tree are unlinked, not followed.
- Secure overwrite refuses multiply linked files. Writes and synchronization
  failures propagate, so an incomplete overwrite is not reported as success.
- Duplicate consolidation uses pinned descriptors and copies the destination's
  metadata onto the clone, including extended attributes, resource fork, ACL and
  timestamps. It retains the original until a verified replacement can be
  published without overwriting a concurrently recreated destination.
- Malware heuristics are presented for manual review and never preselected.
  Common scripting utilities alone are not treated as malicious. Heuristic
  scans do not assert a clean/infected menu-bar protection status.
- Install scripts compile local source rather than fetching an unchecked latest
  DMG. Inherited publishing workflows are removed; the personal workflow can
  read the repository, run tests and upload inspection artifacts only.

## Limits and recovery

The private staging directories are named `.macsai-operation-*` alongside the
original item. On an ordinary failure the item is restored. If another program
recreates the original name, neither file is overwritten: the staged original is
retained, and its recovery path is reported. A process crash can leave such a
directory behind. Recover it manually before removing that directory.

These changes reduce specific filesystem races; they do not isolate the app
from another unrestricted process running as the same user or as root. No app
can guarantee protection against every concurrent filesystem mutation. Partial
permanent deletion cannot be undone if a later entry fails.

Overwriting on APFS/SSDs is best effort and cannot erase snapshots, backups, or
old physical blocks. Use FileVault and an external backup. The malware scan is
a limited heuristic tool, not an antivirus or a proof that a Mac is clean.

Personal builds are ad-hoc signed locally. They are not signed or notarized by
the upstream developer, and GitHub's inspection artifact is not a notarized
installer. Prefer the local source-build installer. No instruction here requires
disabling Gatekeeper, SIP, or quarantine protections.

The macOS workflow runs the full existing suite plus regression tests for hard
links, path replacement, nested symlinks, non-overwriting recovery, metadata
preservation and conservative malware selection. Check its result for the exact
commit you intend to install. A passing workflow is not a complete security audit.
