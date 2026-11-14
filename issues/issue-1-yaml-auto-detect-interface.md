# #1 Preserve YAML TUN interface detection

[GitHub #1](https://github.com/othercat/FlClash/issues/1)

## Scope

Start from official `v0.8.94`, commit `7e7f1f89f363c31bbb7aa5af3f34a8b5c32a7a19`.
Preserve the profile's `tun.auto-detect-interface` through the configuration
round trip, including explicit `false`. Deliver Apple Silicon macOS and
Windows 10 or later desktop packages. Personal YAML and credentials stay local.

## Preserved work

The previous main was `7c831855efedceb1a72bd0b4c18da026593d0853`.
All 57 existing `.ai` files were verified byte for byte and archived in
`archive/20261114-unfinished-customization`, commit
`ddad1c61145ca1d76ad53961e07588e308e7cda1`, now on origin.
That archive includes incomplete historical work; it is not an acceptance claim.
Main was then explicitly pointed to the requested release baseline, with the
old remote tip checked by a force-with-lease guard. The archive retains it.
The subsequent existing main commit
`bbb02d1a817f3831a2cd3895c98279eac534ebfc` only ignores local runtime artifacts;
it is preserved as the parent of this fix.

## Reproduction

The pinned core's `RawTun.AutoDetectInterface` has a YAML tag but no JSON tag.
Reading a profile converts `auto-detect-interface: false` to
`AutoDetectInterface: false`. The application writes that JSON field back to
YAML unchanged. The core ignores the renamed key and uses its default `true`.
An explicit runtime patch works, but reloading the profile loses the setting.

## Acceptance

- Exercise the actual profile generation path for explicit true/false, the
  legacy core JSON field, a missing field, and unrelated TUN options.
- Run repository analysis and tests using the release toolchain.
- Build native macOS arm64 and Windows x64 packages, preserving upstream OS
  requirements. Record checksums and actual build evidence.
- On macOS, load the compatible YAML as a standard profile without a script,
  verify the live core value, aTrust access through an explicit HTTP proxy,
  external proxy access, and Syncthing discovery/transport.
- Keep Windows build verification distinct from Windows 10 physical testing.

Implementation: normalizes the legacy JSON field at the final profile-generation
boundary without changing models, schema, the core submodule, or unrelated TUN
options. Internal build number `2026111401` identifies the custom application.

Local validation: Flutter `3.44.4`, 7 focused regression tests pass (5 failed
before the fix), all 424 repository tests pass, and
`flutter analyze --no-fatal-infos` exits successfully with only existing
informational deprecation notices. The dependency lock is unchanged.

Builds: not yet run.
Runtime acceptance: pending custom build.
Issue state: open.
