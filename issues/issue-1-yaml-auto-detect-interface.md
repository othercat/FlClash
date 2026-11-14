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

Builds: [first CI run](https://github.com/othercat/FlClash/actions/runs/43581443337)
passed analysis and all tests on both operating systems. The macOS arm64 DMG was
generated successfully. Windows native compilation succeeded, then Inno Setup
failed at the installer icon path. Deliver the upstream-supported complete ZIP
bundle for Windows; it includes the application, core, libraries and TUN helper.
The optional installer failure is retained in local evidence; no installer is
claimed as delivered.

[Final CI run](https://github.com/othercat/FlClash/actions/runs/43583525036)
successfully passed analysis, tests and packaging for macOS arm64 and Windows
x64 at `b947c0940fb446c1d6db690df3c16618989f05e1`.

Validated local deliveries:

- macOS DMG: `ab890615ed75df1bbaa6689f9dc6aadb2a985c792fdf0026a76d49b64cf5deea`,
  built at `0f60404c9f587620360504e9b9558e00e68fd00d` in the first run. Signature
  verification passed, and the core is native arm64. The later commit only
  changes packaging instructions, workflow and this issue; application/core/macOS
  source and dependency locks are unchanged. This already validated package is
  retained for the local installation handoff.
- Windows portable ZIP:
  `c357850627ac75094fca3f1ac965749c69de594ad2aff001b4422e4ac6b4d2af`,
  built at `b947c0940fb446c1d6db690df3c16618989f05e1`. All 72 entries are present;
  the app, core and TUN helper have x64 PE headers, and the Flutter framework DLL
  is included. Build metadata and checksum manifests accompany both packages.

Runtime acceptance: pending the user installing the Mac candidate and completing
native administrator authorization. A local offline installer has been syntax
checked and validated in check mode; application/data backups are prepared.
The original current application's privileged core cannot be replaced with an
authorized new core without the user's native system authentication. Windows 10
physical testing is not performed. Do not infer VPN/data-sync acceptance from
build success.
Issue state: open.
