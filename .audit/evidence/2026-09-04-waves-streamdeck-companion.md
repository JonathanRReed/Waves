# Waves Stream Deck companion verification

Date: September 4, 2026, America/Chicago. This is local preparation for Waves
1.7.1 build 19, not a final handoff or publication receipt.

## Source and baseline

The private, unarchived repository `JonathanRReed/waves-streamdeck` was cloned
from its GitHub origin into `/tmp/waves-companion-verification.ctU3vJ/checkout`.
Its default branch main resolved to `8b876e2230105a3c8fb40de0ed9141febeb0865f`.
The checkout was clean and contained no AGENTS.md or CI workflow. A local branch,
`codex/waves-1.7.1-companion-maintenance`, now holds the uncommitted repairs.

After review, the controller copied the checkout to the previously absent
`/Users/jonathanreed/Downloads/waves-streamdeck`. This is the saved working
checkout for further companion work. Its base revision, full binary diff,
lockfile, client sources, and packaged bytes match the reviewed temporary
checkout. The full uncommitted diff SHA-256 is
`921005e57fec166b1e881a71c0db432ff3deae82d9797f482e5af006f1cfbfb0`.
The temporary checkout remains available; no user directory was overwritten.

The repository uses npm and package-lock.json version 3. Its documented
`npm run pack` runs TypeScript checking, client tests, Rollup bundling, Elgato
validation, and packaging. There is no separate lint or publisher-signing script.
The initial package passed on Node 26.8.1 and the Stream Deck runtime major,
Node 24.20.0. Both runs passed six client tests and Elgato validation.

Dependency installation used `npm ci --ignore-scripts --no-audit --no-fund`.
The only baseline install script belonged to optional fsevents; these checks do
not run watch mode. No plugin linking, installation, or Mac mini changes occurred.

## Development dependency repair

The baseline full npm audit exited 1 and reported two high-severity development
dependency packages: brace-expansion 2.1.3 and fast-uri 3.1.4. Both descend from
the Elgato CLI. The production-only audit reported zero advisories, and the
bundler source map did not list either package. Exact exploitability in the
companion build workflow was not reproduced.

The lockfile now resolves brace-expansion 2.1.4 and fast-uri 3.1.7, within the
unchanged parent ranges. Only those two package records changed. The upstream
advisories identify patched 2.x brace-expansion from 2.1.4 and patched 3.x
fast-uri from 3.1.6. Sources: [brace-expansion advisory](https://github.com/advisories/GHSA-rgw5-rvv9-x895)
and [fast-uri advisory](https://github.com/advisories/GHSA-f65p-4m7j-42xc).

After the update, exact-lockfile installation, full and production-only audits,
and Node 24 packaging all exited 0. The package ran six tests and passed Elgato
validation. The controller independently matched both new integrity fields
against npm registry metadata. `npm audit signatures` reported 108 verified
registry signatures and 16 verified attestations. These authenticate dependency
packages, not the author or runtime behavior of the generated plugin.

The reviewed lockfile SHA-256 is
`2243713c91417a78f6517b605b1153f828b0079ef71ac96f80df6a795c6f847e`.
Implementation used GPT-5.6 Luna with low reasoning. Independent review by
GPT-5.6 Sol with low reasoning approved both spec compliance and quality.

## Protocol and recovery

Static comparison with Waves source at
`64daff18863623cba84809f8357e3a2ed2eddafa` confirmed the default socket path,
protocol version 1, newline-delimited JSON, numeric request IDs, command names,
app fields, and app-changed/apps-changed push names used by the companion.
The tests' copied fixture is not automatic cross-repository compatibility proof.

Independent review identified three transport/readiness defects. Controller
probes used the actual compiled WavesClient against real local Unix sockets:

| Probe | Original client result |
|---|---|
| Reject hello while keeping the connection open, then accept a new connection | Never retried or became ready; assertion failed. |
| Close after a partial response, then accept the next connection | Old receive bytes corrupted the new handshake; assertion failed. |
| Reject subscribe | Client reported ready; assertion failed. |

The controller probe exited 1 with zero of three tests passing. The source and
red log are retained under `/tmp/waves-companion-verification.ctU3vJ` as
recovery-probe.mjs and recovery-red.log.

The client now closes rejected or timed-out handshake connections so the
existing reconnect backoff can run. It clears partial receive bytes on close
and reports ready only after both hello and subscribe succeed on the current
connection. Five permanent real-socket regression tests cover those cases,
subscription recovery, and explicit close preventing reconnect or late ready.
The existing unknown-app test now exercises an actual error response.
README and test comments distinguish stub coverage from Swift integration.

Independent review approved the production change. Fix round 1 corrected a
remaining misleading test comment and removed a server-acceptance race from
the explicit-close test. Scoped re-review approved spec compliance and code
quality with both findings addressed and no new breakage.

The controller reran the external recovery probe after that fix: exit 0,
three tests passed, zero failed. From the saved checkout, explicit-PATH
Node 24.20.0 `npm test` passed all 11 tests in 6.27 seconds, and `npm audit
--json` exited 0 with zero known vulnerabilities. `git diff --check` passed.
The worker's final Node 24 `npm run pack` passed typecheck, all 11 tests,
Rollup, Elgato validation, and packaging. The controller independently verified
all 17 ZIP entries and the final package SHA-256:
`864f7ff8a54015b7bec59fb56a957f521b19270de7c10da93fcc791f4deda215`.

The broader observation that command failures produce generic alerts remains
for physical UX evaluation. The repair preserves the existing nullable command
methods and does not redesign the deck UI or change the wire protocol.

## Evidence and remaining work

Logs are saved locally under
`/Users/jonathanreed/Downloads/waves-streamdeck-verification-2026-09-04` and
have not been uploaded. Baseline and updated audits are retained separately.
This directory also holds the private companion diff and worker report.

| Log | SHA-256 |
|---|---|
| npm-audit.json | 3d1578c0f68e49df3cff9ac49d5583f508438b3150b3b8ebcef3dc9f05aa3d8d |
| npm-audit-updated.json | 82dab6474b3012dd8bb1f31b2e98092312b8ca7c55506afe5bca1b34ee806519 |
| npm-signatures.log | f65c541b336309697b051490a2f44a0670219bbb215107e7401e01515e6e029a |
| recovery-red.log | b1d757061443025fd6cc4d34e3490983c2afca5fccf88be7873322cbd23e1f9a |
| recovery-green-final.log | 6b42289e592dec54773e41bde4bfdced8ec0606645d99e593b563cb5f9d8ecbb |

The dependency-only package passed ZIP integrity checking. Its historical hash
is `c215d8ce054740667acadda754329a38b2553ae6a03a9fd154c996ca0d23b67c`.
Client changes invalidate that historical package for handoff. The current
package is local preparation, still using companion version 1.0.0. Final
source integration and companion release-version selection,
fresh packaging, sealed candidate/companion hashes, installation, actual Waves
interaction, and physical Mac mini dial/mute/recovery checks remain required.
No commit, push, PR, merge, installation, or publication occurred during the
initial local verification described above.

## Authorized source integration

Jonathan subsequently approved the required setup and repository integration.
The controller fetched origin, confirmed private main still resolved to the
recorded base, and reran Node 24.20.0 tests with 11 passes. The reviewed four-file
patch was committed as `94d814ba1eac7da1c3d99aeb4a92518c54dc6eae`, pushed, and
merged through [private companion PR 1](https://github.com/JonathanRReed/waves-streamdeck/pull/1).
GitHub confirmed merge commit `4e16fe567daffa3ae6405023b0322daa03f9b399`.
There were no configured hosted checks for this repository; local checks and
the recorded independent reviews supplied the verification evidence.

The saved checkout now has clean main at that exact origin/main revision. Its
tree matches the reviewed patch commit. A fresh Node 24 `npm run pack` passed
typecheck, 11 tests, Rollup, Elgato validation and packaging from merged source.
The resulting package SHA-256 is
`218fdc0aa2e39898777f95af753401b45d0c80ee9f98278ddc342c868019fa82`.
The lockfile hash remains unchanged. Package version remains 1.0.0.0.

This closes source integration and the merged-source package check. Final
version selection, sealed candidate handoff, installed interoperability and
physical Mac mini verification remain open. No plugin installation or public
release occurred.
