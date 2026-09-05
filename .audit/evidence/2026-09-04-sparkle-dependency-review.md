# Sparkle dependency review

Reviewed on 2026-09-04 at Waves revision 9d18947.

## Observed dependency

Package.resolved pins Sparkle 2.9.5 at 79bc9e872948e47877e76f194cb0c8e0412b0b90. The local dependency checkout matches. Its Package.swift selects the 2.9.5 binary archive and checksum. Waves' production UpdaterService.swift initializes SPUStandardUpdaterController at lines 29-34. script/build_and_run.sh embeds that framework at lines 874-882.

GitHub's release API identifies Sparkle 2.9.6, published 2026-08-17, as latest. The upstream advisory API lists two high-severity advisories patched in that release.

## Static triage

1. [GHSA-3x7w-j75x-ppq5](https://github.com/sparkle-project/Sparkle/security/advisories/GHSA-3x7w-j75x-ppq5): needs review, medium confidence, unresolved queue rank 1. Versions through 2.9.5 are affected. The checked-out AppInstaller.m validates the resolved download path at line 486 but moves the original path at line 552. This matches the reported race. The affected framework ships in Waves, but this review did not establish or reproduce the exact system-domain exploit and filename preconditions for Waves.

2. [GHSA-4v99-qgq9-6pxp](https://github.com/sparkle-project/Sparkle/security/advisories/GHSA-4v99-qgq9-6pxp): needs review, medium confidence, unresolved queue rank 2. Versions 2.2.0 through 2.9.5 are affected. The checked-out SUInstallerLauncher.m selects a console-user cache for root execution and performs cleanup and directory creation at lines 542-553. Waves is a GUI utility; a supported root-running updater configuration was not established. Dependency presence does not prove that prerequisite.

The repository SECURITY.md includes local file handling in scope. Package and production updater code establish shipped use. They do not establish that either privileged exploit is reachable in a supported Waves configuration. No exploit, app, test, or build was run during this static triage.

## Required follow-up

Upgrade to the upstream patched 2.9.6 release and enforce that minimum in Package.swift. Resolve only the intended dependency, preserve the Swift Testing toolchain pin, then check updater tests, build compatibility, and package embedding. Record the resolved revision and binary checksum. Do not call either exploit reproduced or the deep security scan complete.

The installed 1.7.0 baseline must remain untouched. Any candidate dependency change invalidates downstream candidate measurements.

Sources were fetched through read-only GitHub REST calls for releases/latest and security-advisories. [Upstream 2.9.6 release notes](https://github.com/sparkle-project/Sparkle/releases/tag/2.9.6) describe the installer and root-cache fixes.

## Task 9 verification

The focused pre-change assertion rejected the 2.8.0 manifest minimum and resolved Sparkle 2.9.5, exiting 1 as expected. After changing the manifest, `swift package resolve sparkle --version 2.9.6` resolved Sparkle 2.9.6 at upstream tag revision `ac2def288cbff5cfc7df3ffef6abdf45b72bcb0a`. The exact binary target is `https://github.com/sparkle-project/Sparkle/releases/download/2.9.6/Sparkle-for-Swift-Package-Manager.zip` with checksum `8d5fb41d960b43f4a68aa14126bf62b098544ec8d191cdcc73eb14e63a8e7606`.

The literal pre-edit assertion was:

```sh
python3 - <<'PY'
import json, pathlib, re
p=pathlib.Path('Package.swift').read_text(); r=json.loads(pathlib.Path('Package.resolved').read_text())
min_ok=bool(re.search(r'Sparkle\", from: \"2\\.9\\.6\"',p))
pin=next(x for x in r['pins'] if x['identity']=='sparkle')['state']
ok=min_ok and pin.get('version')=='2.9.6'
print(f'before_assertion: manifest_min_2.9.6={min_ok} resolved_version={pin.get("version")} revision={pin.get("revision")} expected_pass={ok}')
raise SystemExit(0 if ok else 1)
PY
```

Captured output: `before_assertion: manifest_min_2.9.6=False resolved_version=2.9.5 revision=79bc9e872948e47877e76f194cb0c8e0412b0b90 expected_pass=False`; `before_assertion_exit=1`.

The literal post-edit assertion was:

```sh
python3 - <<'PY'
import json,re,pathlib,subprocess
p=pathlib.Path('Package.swift').read_text(); d=json.loads(pathlib.Path('Package.resolved').read_text()); s=next(x['state'] for x in d['pins'] if x['identity']=='sparkle')
manifest=bool(re.search(r'Sparkle\", from: \"2\\.9\\.6\"',p)); tag=subprocess.check_output(['git','ls-remote','https://github.com/sparkle-project/Sparkle.git','refs/tags/2.9.6'],text=True).split()[0]
ok=manifest and s.get('version')=='2.9.6' and s.get('revision')==tag
print('after_assertion:',manifest,s.get('version'),s.get('revision'),'upstream_tag=',tag,'pass=',ok)
raise SystemExit(0 if ok else 1)
PY
```

Captured output: `after_assertion: True 2.9.6 ac2def288cbff5cfc7df3ffef6abdf45b72bcb0a upstream_tag= ac2def288cbff5cfc7df3ffef6abdf45b72bcb0a pass= True`; exit 0. The Swift Testing revision remained `18c42c19cac3fafd61cab1156d4088664b7424ae`, and Swift Syntax remained `0687f71944021d616d34d922343dcef086855920`.

Captured updater test completion lines:

```text
✔ Test updaterExplicitCheckDispatchesOnlyToInjectedDriver() passed after 0.001 seconds.
✔ Test updaterStartPolicyFollowsFeedConsentAndUnavailableChecksAreSurfaced() passed after 0.001 seconds.
✔ Test updaterAvailabilityAndAutomaticPreferenceSynchronizeBothDirections() passed after 0.001 seconds.
✔ Test updaterDriverFailureIsSurfacedWithoutAProductionFeed() passed after 0.001 seconds.
◇ Test run with 4 tests passed after 0.003 seconds.
```

This records dependency and build/test evidence only. Package embedding, signing, notarization, app launch, and actual update installation were not reverified here. The two advisories remain unproven as exploitable through a supported Waves configuration.
