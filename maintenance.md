# Maintenance

Do this every couple of months, and before any release. Most of it is checking that pinned versions are still current and that Windows has not changed under the tool.

## 1. Check CI is green

1. Open the Actions tab and look at the latest `CI` run on `main`.
2. If it has not run in a while, push an empty commit or use "Re-run all jobs", since `windows-latest` moves to new images on its own and that is where breakage shows up first.

## 2. Bump the pinned versions

Everything is pinned on purpose so a release never changes without a commit saying so. That means it goes stale unless you bump it.

### Modules: `tools/versions.psd1`

1. Check the newest version of each on the PowerShell Gallery: `ps2exe`, `Pester`, `PSScriptAnalyzer`. From any Windows PowerShell: `Find-Module ps2exe, Pester, PSScriptAnalyzer | Select Name, Version`.
2. Change the version in `tools/versions.psd1`.
3. Push to a branch and let CI run. A new PSScriptAnalyzer can add Error-level rules, so read its output.
4. Pester 6 exists. The tests are written for Pester 5 and are pinned to 5.x. Moving to 6 means reading its migration notes first.
5. A new ps2exe changes the exe stub, which can change how Defender treats it. After bumping it, scan the CI artifact on VirusTotal before tagging.

### Actions: the `uses:` lines in `.github/workflows/*.yml`

Each action is pinned to a commit SHA with the tag in a comment above it. To bump one:

1. Find the newest tag on the action's GitHub releases page (`actions/checkout`, `actions/upload-artifact`, `actions/attest-build-provenance`, `signpath/github-action-submit-signing-request`).
2. Get its commit SHA. On Linux, or whichever system has git: `git ls-remote https://github.com/actions/checkout.git 'refs/tags/v7.0.1^{}'`. If that prints nothing the tag is not annotated, so drop the `^{}`.
3. Replace the SHA and the version comment. Read the action's changelog for renamed inputs or outputs, since `upload-artifact`'s `artifact-id` output feeds the signing step.

Dependabot can open these bumps for you if you add `.github/dependabot.yml` with the `github-actions` ecosystem. It understands SHA pins with version comments.

## 3. Re-test on current Windows

Windows updates have changed disk mounting behavior before. Once per cycle, on an up-to-date Windows 11 machine (and Windows 10 22H2 while it still matters):

1. Run `tests\Integration.ps1` from an elevated prompt against the latest release exe: `powershell -NoProfile -File tests\Integration.ps1 -Exe C:\path\VHDOneClick.exe`.
2. Mount one real Macrium image as a standard user who elevates with a separate admin account. Open a profile in Explorer with no prompt.
3. Look at the newest log in `VHDOneClick-logs` for warnings you have not seen before.

If you have not yet, confirm the three things the spec flagged as unverified, and note results in `changes.md`:

- `Set-Disk -Guid` fixes a signature collision (mount an image on the machine it came from).
- `diskpart` over stdin works. Search the log for "retrying with a script file"; if it shows up every time, stdin does not work on that build.
- `icacls` propagation from a profile root reaches children that inherit, and the `/T /L` repair does not walk through junctions. The integration test's host-ACL check covers this.

Fill in the Performance table in `README.md` the first time you have a large profile to measure.

## 4. Signing

1. If SignPath is not set up yet, apply at signpath.org. Requirements at the time of writing: OSI license (GPL-3.0 is fine), public repo, MFA on GitHub and SignPath, builds from CI.
2. Once approved, add the secret `SIGNPATH_API_TOKEN` and the variable `SIGNPATH_ORGANIZATION_ID` in Settings > Secrets and variables > Actions. Set `SIGNPATH_PROJECT_SLUG` and `SIGNPATH_SIGNING_POLICY_SLUG` too if yours are not `VHDOneClick` and `release-signing`.
3. In SignPath, the artifact configuration has to sign `VHDOneClick.exe` inside the zip GitHub uploads, since `upload-artifact` always zips.
4. The next tag signs automatically. Without the secret, releases still build, unsigned, and the notes say so.

Check the SignPath token has not expired. A failed signing step fails the release, which is what you want.

## 5. Repo settings that live outside the files

- Tag protection: Settings > Rules > Rulesets, new tag ruleset targeting `v*`, restrict creation, update and deletion to maintainers. Anyone who can push a `v*` tag can publish a release.
- MFA on the GitHub account, since SignPath requires it.

## 6. Cutting a release

1. Add an entry to `changes.md`.
2. Commit with a conventional prefix where it fits (`fix:`, `security:`, `feat:`, `perf:`). Those become headings in the release notes. Anything else lands under Other. `docs:`, `ci:` and `chore:` are left out unless they are all there is.
3. Tag and push: `git tag v2.0.1` then `git push origin v2.0.1`. Or create the tag in the GitHub web UI under Releases > Draft a new release > Choose a tag, then cancel the draft, since the workflow makes the release.
4. Tags with `-rc` or `-beta` become pre-releases.
5. Watch the Release run. When it finishes, scan `VHDOneClick.exe` on VirusTotal and add the result link to the release description.
6. If Defender flags it, submit it at Microsoft's security intelligence submission portal as a false positive and note that in the release.

## 7. If the hosted runner cannot mount VHDX

The integration step will fail on mount. Set the repository variable `SKIP_INTEGRATION` to `true`, and run `tests\Integration.ps1` on a local Windows VM before each tag instead. DO NOT skip it without running it somewhere, since it is the only automated check that host ACLs survive the junction cases.
