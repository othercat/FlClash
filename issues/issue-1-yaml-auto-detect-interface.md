# #1 Preserve YAML TUN interface detection

[GitHub #1](https://github.com/othercat/FlClash/issues/1)

## Native macOS acceptance — 2026-11-15

The user installed `0.8.94+2026111504` and enabled TUN. Installed app, arm64
core and AOT hashes match the verified package; native authorization is present.
The standard profile has no script. Its raw shared file has 112 common and
seven extension nodes, while the actual application-generated/runtime config
has all 119 nodes, 44 groups and 8,113 rules. The extension is removed before
the normal parser. gVisor, auto-route and auto-detect-interface are all enabled;
there is no fixed outbound adapter. System HTTP/HTTPS/SOCKS proxies are enabled.

Native corporate HTTPS returns 200 through both ordinary TUN and an explicit
HTTP proxy; external requests return 204 through both paths. WeChat/QQ public
websites return 200. The original default-discovery Syncthing service was
restarted for a fresh test: IPv4 announcement succeeds by uptime five seconds,
and native QUIC plus relay peer connections were observed afterward. The local
folder is idle with 282 files, needFiles/pullErrors zero. IPv6 has no usable
coverage here; the user's deferred remote pending items were not investigated.

The Microsoft scientific group defaults to Singapore; ordinary Microsoft uses
DIRECT. Transient DNS errors/10-second failures occurred immediately after the
initial reload, while direct physical/core requests succeeded once resolution
recovered. Fourteen Microsoft/auth/Office suffixes now use the existing domestic
DoH resolvers through scoped nameserver policies. The common profile uses a
classic-compatible scalar; desktop restores both resolvers. No node, group,
rule, subscription or authentication data changed in this final DNS amendment.
After applying the file through the native standard-profile UI, all 14 policies
are present in the generated config. First requests return 200 for Microsoft's
website, global login and China login via DIRECT, and 200 for Copilot via
Singapore; corporate/external regression checks still pass.

The final shared file again passes the original Clash v1.18.0 parser; actual
Go expansion equals the complete desktop reference with only the scoped DNS
amendment. The original November 9 file is unchanged. Current Mac/Windows
packages and the actual pre-upgrade build-2 application/data backup were
rechecked as available. Offline install/restore syntax, install check mode
and handoff manifests pass with the final shared-file hash. The fully merged
temporary shared-profile branch has been removed locally and on origin.

Local-only evidence: `process-root/artifacts/FlClash-issue-1/` contains
`native-yaml4-installed-state.json`, `native-yaml4-final-config.json`,
`native-yaml4-final-network.json`, `native-yaml4-final-acceptance.json`, and the
Syncthing/Microsoft comparisons. These contain no public configuration link.
New iOS/Android imports and Windows 10 physical VPN tests remain unperformed;
the user explicitly deferred their phone retest. The issue stays open for
those platform acceptance boundaries; development/delivery and Mac native
regressions are complete.

## Follow-up: one YAML for desktop and legacy mobile clients

The user requires one shared YAML for this custom desktop client, latest iOS
Shadowrocket and old Clash for Android. Separate generated mobile files are
diagnostic candidates only, not deliveries. A locally built original Clash
v1.18.0 parser confirms that VLESS nodes and list-valued DNS policies prevent
the original desktop profile from loading. Common standard fields therefore
retain supported nodes/groups and scalar DNS policies; `x-flclash-desktop`
retains the extra nodes, complete desktop group list/order and DNS policies.
No private profile or credential is included in this repository.

Both native profile validation and reading expand the extension on macOS and
Windows before the normal core parser. Rules and other profile settings are
unchanged. The final shared file must pass the classic parser, and its actual
Go desktop expansion must equal the complete working desktop profile as data.
Build identity: `0.8.94+2026111504` / `othercat-yaml4`. Phone-native import and
Windows 10 physical testing are separate acceptance boundaries.

The stack-preservation implementation `2b2f3b2781a50def8321a67a2e12e00c80282aa8`
passed both platform jobs in run
[43607901393](https://github.com/othercat/FlClash/actions/runs/43607901393),
including all 428 Flutter tests. It was merged normally into main at
`3580a1534c36f887eef08da998c94325f1dee810` and pushed. The new branch
`richardli/fix/1-shared-client-yaml` starts at that integration commit. Build 3
was downloaded and verified but is not installed; build 2 remains live with a
temporary gVisor patch until the complete shared-file build is ready.

Local validation: `go test . ./profilecompat ./routeiface` passes on macOS,
including the actual getter/validation boundary, ordering, scalar identity,
duplicate/invalid-extension rejection and credential-free errors. Analysis
passes with the same 10 existing informational notices. The real private shared
candidate passes original Clash v1.18.0 with all 8,113 rules (including 102
process rules); unknown desktop fields are ignored. Actual Go expansion is
equal to the entire working desktop reference: 119 nodes, 44 groups, rules,
DNS, providers and authentication fields. The shared file has 112 common nodes
and 41 common groups; its seven VLESS nodes remain available on custom desktop.
The original November 9 profile remains byte-identical. Evidence is local-only
in the parent task's `classic-shared-verified.json` and
`desktop-shared-equivalence.json`, not a public configuration attachment.

The freshly fetched origin/main contains the complete prior build-3 tip with
no missing commits. Its temporary branch was deleted locally and on origin;
the permanent unfinished-work archive remains. No worktree was created.

The user confirms the original November 9 YAML imports into their Shadowrocket
with policy groups and routing rules visible. This supports retaining that
standard structure, but the new shared file/extension is still awaiting their
phone retest; it is not recorded as a new mobile-native pass.

Implementation: `d76c7ab4930e302bd1e172dd57db5449d21541c0`.
[Build 43614679135](https://github.com/othercat/FlClash/actions/runs/43614679135)
completed successfully on both platforms: analysis, all 428 Flutter tests,
native profile/extension/route tests and packaging. Both artifact ZIP digests
match GitHub, inner checksum manifests match, Mac signature/arm64 core checks
pass, and the Windows ZIP's 72 members pass CRC with x64 app/core/helper/Flutter
components. Actual Windows 10/phone use remains untested.

- Mac DMG SHA-256:
  `3c36ff179b402ef6c04a524e4bad41bf4ad2a9355966c2482978698a25c3b838`.
- Windows ZIP SHA-256:
  `046c706b0bd01865298b015dca6e90d47461908540515ea5726af81f18b57cd2`.

The one shared YAML has been published locally with a verified backup of its
desktop predecessor. The running build-2 imported profile is unchanged until
offline upgrading. The build-4 installer verifies the application, core,
signature and exact shared profile; it backs up the prior application/data,
replaces the app and atomically imports that same file before opening. Syntax
and check mode pass; no native replacement has happened yet. The companion
restore entry also restores the pre-upgrade imported profile. All packages,
private configuration and install helpers stay outside Git.

Shared-profile integration: ordinary merge
`6092be6edaeec8b7151f0311976f6d0c14c54ed1` is pushed to main; final feature tip
`7a38df9ea2e9f41d81a5f3d31b543c3289be092c` and implementation `d76c7ab4` are
reachable from freshly fetched origin/main. The merge tree equals the feature
tree and no feature commits are missing. The old-work archive is still
`ddad1c61145ca1d76ad53961e07588e308e7cda1`. No worktree exists. The temporary
shared-profile branch is eligible for cleanup; native build-4 acceptance is
pending and the issue remains open. The older, uninstalled build-3 install
entry was renamed with a disabled timestamp; its package/restore/evidence are
retained. The build-4 installer and handoff checksum checks pass without
changing the current installed application.

## Follow-up: preserve the YAML TCP stack

Build `2026111402` is installed and its native full-TUN, corporate explicit-proxy
and ordinary external HTTPS checks pass. A remaining Syncthing default discovery
announcement was isolated with real service requests: the authenticated IPv4 POST
times out with the mixed stack, succeeds with TUN disabled, and succeeds with
full TUN using gVisor (six seconds after a service restart). Native queries,
relay transport and the local folder are otherwise healthy. MTU 1500 did not
resolve the problem; the original MTU was restored. DNS/proxy-only trials did
not resolve the authenticated request and were rolled back. Evidence is local:
`process-root/artifacts/FlClash-issue-1/syncthing-stack-trial.json` and
`syncthing-tun-off-baseline.json`.

The profile generation task unconditionally replaces `tun.stack` with the GUI
default, so a YAML-only stack remedy does not survive native loading. Preserve
an explicitly supplied stack (including the core's exported `gVisor` spelling)
and use the application value only when the profile omits it. The interface
detection fix, native route finder and pinned core remain unchanged. Native
package acceptance of this final field-preservation change is pending.

Validation: three explicit-stack cases fail before the one-line fix; all 11
profile field tests pass afterward. All 428 Flutter tests pass, and analysis
exits successfully with only the same 10 existing informational notices. Build
identity is `2026111403` / `othercat-yaml3`; dependency locks and Go source are
unchanged from the already compiled and tested route-aware second version.

Follow-up branch: `richardli/fix/1-yaml-tun-stack`, from freshly fetched main
`e7bdec1eada7e24ead4ede9ae9fcb20184178bbf`. The prior implementation was merged
normally; tip `1a16470e51231bc00f9d2350189c40f4b40c1b26` and its merge are
reachable from current origin/main, with no missing commits and an identical
merge tree. Its temporary branch was removed locally and on origin; the
permanent archive branch and all prior evidence/backups remain.

## Native regression: full TUN loses connectivity

The user installed build `2026111401` and completed native authorization, then
reported that enabling TUN broke networking across browsers, WeChat and QQ.
They disabled TUN to recover. This supersedes the pending-installation status
below; native acceptance has failed and this issue remains open.

The profile now correctly applies `auto-detect-interface: false`, but desktop
FlClash keeps `auto-route: true`. Without an explicit outbound interface this
allows outbound sockets to enter the full TUN again. A bounded native trial
with automatic rollback enabled TUN and automatic interface detection: direct
TUN and explicit-proxy gstatic requests both returned HTTP 204. The trial
restored the original disabled TUN state. Evidence is local-only:
`process-root/artifacts/FlClash-issue-1/tun-auto-detect-recovery-trial.json`.

Follow-up branch: `richardli/fix/1-tun-routing-coexistence`, from freshly fetched
`main` at `aa8728dd4fa6d5898e940088aa059c83c3fb2c45`. Preserve the upstream TUN
loop guard and YAML flag semantics. Resolve outbound interfaces using the OS
route for the destination, so dynamically installed VPN routes can win over
the default physical interface. Keep the pinned core submodule unchanged.
Test real full TUN, reload/toggle behavior, and VPN access; successful builds
alone are insufficient. Windows physical acceptance remains outstanding.
The user explicitly deferred the remote Syncthing 5060 pending-item status.

Follow-up implementation: install a destination-route-aware interface inventory
once at desktop core initialization, beneath the existing TUN listener lifecycle.
macOS uses bounded RTM_GET requests with unique sequences; Windows uses
GetBestInterfaceEx. Leave unspecified/local addresses and lookup failures to the
upstream inventory, and return the application's own TUN unchanged so the existing
detector rejects it. No custom VPN names, routes or credentials enter the product.
The YAML flag and explicit outbound interfaces retain their semantics.

Local validation for build `2026111402`: native route tests, including concurrent
lookups and live macOS loopback lookup, pass; the complete desktop core builds
with Go 1.26.4 and `CGO_ENABLED=0`. Flutter 3.44.4 analysis succeeds with the same
10 existing informational notices, and all 424 Flutter tests pass. Exclude the
ignored process/delivery artifact roots from Dart analysis: downloaded diagnostic
packager source under process-root otherwise generates unrelated analysis errors.
The core submodule, Go module/sum and Flutter lock remain unchanged.

Toolchain note: the runtime-assistant's all-module offline preparation rejected
the upstream graph for an unused missing checksum. Its verified Go 1.26.4 runtime
was selected separately, and actual package tests/core compilation ran against
the existing module cache with `-mod=readonly`; no dependency lock was changed.
Personal YAML, its imported profile and generated runtime were backed up, then
only `auto-detect-interface` was changed to `true`. TUN remains disabled pending
the corrected native build and VPN acceptance.

Follow-up implementation commit: `0264233c5798c8484ff90e99d89a44a966f11695`.
[Second-version CI](https://github.com/othercat/FlClash/actions/runs/43599325098)
passed analysis, all Flutter tests, native route tests and packaging on both
macOS arm64 and Windows x64. The downloaded artifact digests and packaged
checksum manifests match. Version is `0.8.94+2026111402` / `othercat-yaml2`.

- Mac DMG: `0372208ddcfc28cde15f2f19f26609d0424abf1ce0b0cef055936a7b430b4fe1`.
  Extracted app signature verified; the core is arm64 and has SHA-256
  `a982cf904fc0d68721ac2fcaf9c441d413eed2463b35cf97f091d64b200e4227`.
- Windows ZIP: `eb1fdcc12b1f10a59f7dd5cb1e17f40ed19039f9ecab8bc6ef10e1f1c5c22044`.
  All 72 entries pass CRC; application, core and helper service are x64, and
  the Flutter DLL is included. Windows 10 physical testing remains unperformed.

The user renewed aTrust login. Its corporate route now uses a separate adapter.
A local isolated integration test, compiled against the unchanged upstream TUN
detector and the new route finder, ran under a live full TUN: public destinations
were rejected as own-TUN and fell back to the physical interface; the corporate
destination selected the VPN and actual mihomo outbound dialing returned HTTPS
200. Native TUN and explicit-proxy external requests returned 204. TUN was then
restored off by the bounded trial. Local-only evidence:
`process-root/artifacts/FlClash-issue-1/native-full-tun-vpn-route-yaml2.json`
and its companion log. This tests real route/dialer behavior, not an installed
second-version application, whose native acceptance remains pending.

Local deliveries are in `delivery-root/artifacts/FlClash-issue-1/macos-yaml2/`
and `windows-yaml2/`. The second offline installer and previous-app restore
entry passed zsh syntax checks; installer check mode verifies the actual build,
app/core hashes and signature. The original installer is retained with a
`.disabled-` suffix to avoid reinstalling the failed first candidate. Old packages,
backups and the original-version restore entry remain available. No second app
replacement has been performed yet.

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

## Integration and cleanup

Ordinary merge into `main`:
`370350cdc4d6362fcdcb518ac37b6a6ee4a9bb29`, pushed to origin.
Final feature tip: `b54ca3c43cbdb515a0665bc6b91ac87890369075`.
The freshly fetched remote main contains that tip, has no missing commits, and
the merge tree matches it exactly. The temporary fix branch was deleted locally
and on origin after these checks. The permanent unfinished-work archive remains.
No worktree was created. Local evidence/backups and the offline install/restore
helpers remain outside Git. Runtime acceptance is still pending, and this issue
remains open.
