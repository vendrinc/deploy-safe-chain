# Kandji / Iru Safe Chain Deployment Scripts

This repository contains macOS scripts to deploy Aikido Safe Chain per-user in an Iru (Kandji) environment where scripts execute at machine scope.

## Files

- `kandji-safe-chain-detect.sh`  
  Kandji detection script. Enumerates local user profiles and checks Safe Chain compliance per user.
- `kandji-safe-chain-remediate.sh`  
  Kandji remediation script. Installs or updates Safe Chain per user when non-compliant.
- `instructions.MD`  
  Build plan and implementation notes.

## Version policy (environment variables)

Both scripts read the same policy variables (set them in Kandji as custom script environment variables or export them in a wrapper). Remediation-only variables apply only to `kandji-safe-chain-remediate.sh`.

| Variable | Default | Meaning |
|----------|---------|---------|
| `SAFE_CHAIN_VERSION_POLICY` | `latest` | How strictly version is enforced. |
| `SAFE_CHAIN_MINIMUM_VERSION` | *(empty)* | Required when `SAFE_CHAIN_VERSION_POLICY=minimum`. Must be a dotted numeric version (e.g. `1.4.6`); invalid values are rejected after normalization. |
| `SAFE_CHAIN_RELEASE_TAG` | `1.4.6` | **Pinned** GitHub release tag for download URLs (use the exact tag from [releases](https://github.com/AikidoSec/safe-chain/releases)). When non-empty, **skips the GitHub API** for `latest` policy (detect/remediate compare against this tag). With `minimum` policy, installs use this tag when set; if empty, the API resolves **latest** at install time. To **track GitHub latest** instead of pinning, set an explicit empty value: `export SAFE_CHAIN_RELEASE_TAG=""` (the scripts use bash `${VAR-default}` so empty overrides the default). |
| `SAFE_CHAIN_INSTALLER_SHA256` | *(empty)* | **Remediate only.** Optional 64-character hex SHA-256 of `install-safe-chain.sh` for the pinned release. When set, the installer is downloaded to a temp file, verified with `sha256sum -c` or `shasum -a 256 -c`, then executed. **Requires** `SAFE_CHAIN_RELEASE_TAG` so the artifact is fixed. If unset, the script uses `curl … \| sh` (no checksum). |

### `latest` (default policy; default pin `1.4.6`)

- **Detect:** If `SAFE_CHAIN_RELEASE_TAG` is **empty**, calls the GitHub API for the current release tag and requires each user’s installed version to **match** that tag (after normalizing a leading `v`). If **`SAFE_CHAIN_RELEASE_TAG` is non-empty** (default `1.4.6`), skips the API and requires a match to the pinned tag. Shell integration markers are always required.
- **Remediate:** Resolves the target tag once at startup (API or pin), then installs or upgrades anyone who is not on that version or is missing shell integration.

### `minimum`

- **Detect:** Does **not** call GitHub. Each user must have a binary whose version is **greater than or equal to** `SAFE_CHAIN_MINIMUM_VERSION` (dotted numbers such as `1.2.2` vs `1.4.6`), plus shell integration markers.
- **Remediate:** Only runs an install when the user has no binary, is **below** the minimum version, or lacks shell integration. The install uses `SAFE_CHAIN_RELEASE_TAG` if set; otherwise it resolves **latest** from the API when an install is needed.

Invalid `SAFE_CHAIN_VERSION_POLICY`, `minimum` without a valid `SAFE_CHAIN_MINIMUM_VERSION`, unsafe/invalid release tags, or `SAFE_CHAIN_INSTALLER_SHA256` without `SAFE_CHAIN_RELEASE_TAG` causes a logged error and a non-zero exit.

## Compliance criteria (per user)

A user is compliant when all of the following hold:

1. `~/.safe-chain/bin/safe-chain` exists and is executable.
2. **Version:** Under `latest`, installed version equals the resolved tag (GitHub **latest** or **`SAFE_CHAIN_RELEASE_TAG`**). Under `minimum`, installed version is not less than `SAFE_CHAIN_MINIMUM_VERSION` (comparison uses dotted numeric versions such as `1.2.2` vs `1.4.6`).
3. Shell profile files contain Safe Chain integration markers (so shell aliases/hooks are present).

## Detect script behavior

`kandji-safe-chain-detect.sh`:

- Enumerates local user accounts via `dscl`.
- Filters to real profiles:
  - UID >= 500
  - valid home directory
  - shell is not `false`/`nologin`
- If `SAFE_CHAIN_VERSION_POLICY=latest` and `SAFE_CHAIN_RELEASE_TAG` is **empty**, fetches latest version from:
  - `https://api.github.com/repos/AikidoSec/safe-chain/releases/latest`
- If `SAFE_CHAIN_VERSION_POLICY=latest` and `SAFE_CHAIN_RELEASE_TAG` is **non-empty** (default `1.4.6`), uses that tag only (no API call).
- Compares installed vs required version per user (see version policy above).
- Returns:
  - `0` if all eligible users are compliant (or no eligible users are found)
  - `1` if any user needs remediation, or if `latest` mode cannot fetch the latest version

## Remediate script behavior

`kandji-safe-chain-remediate.sh`:

- Uses the same user enumeration and compliance rules as detect.
- For non-compliant users, runs install as that user using:
  - `https://github.com/AikidoSec/safe-chain/releases/download/<tag>/install-safe-chain.sh`  
  With optional **SHA-256**: download to a temp file, verify, then `sh` (see `SAFE_CHAIN_INSTALLER_SHA256`). Without a checksum, `curl … | sh` is used.  
  Unpinned **latest** is equivalent to the [latest installer redirect](https://github.com/AikidoSec/safe-chain/releases/latest/download/install-safe-chain.sh) once `<tag>` is resolved.
- In `minimum` mode, the GitHub API is called only when at least one user actually needs an install.
- Ensures user context includes correct `HOME` and a PATH with `~/.safe-chain/bin` first.
- Includes a fallback direct-binary install path if the upstream installer fails due to local package-manager cleanup edge cases.
- Re-validates version and shell markers after install (`latest`: must match resolved tag; `minimum`: must be at least the configured minimum).
- Returns:
  - `0` if all required remediations succeed
  - `1` if any remediation fails

## Version detection

Installed version is read from `safe-chain --version`, falling back to `safe-chain -v`, parsing the line:

`Current safe-chain version: <version>`

Versions are compared as dotted numbers (leading `v` on tags or variables is stripped).

## Logging

Logs are written to:

- Detect: `/var/log/safe-chain-kandji/detect.log`
- Remediate (root): `/var/log/safe-chain-kandji/remediate_root.log`
- Remediate (user execution output): `/var/log/safe-chain-kandji/remediate_user.log`

## Kandji wiring

1. Upload `kandji-safe-chain-detect.sh` as the Detection script.
2. Upload `kandji-safe-chain-remediate.sh` as the Remediation script.
3. Ensure scripts run as root (standard Kandji custom script flow).
4. Optionally set policy and pin variables (`SAFE_CHAIN_VERSION_POLICY`, `SAFE_CHAIN_MINIMUM_VERSION`, `SAFE_CHAIN_RELEASE_TAG`, `SAFE_CHAIN_INSTALLER_SHA256`) so detect and remediate stay aligned.

## Upstream project

- Safe Chain repo: [AikidoSec/safe-chain](https://github.com/AikidoSec/safe-chain)
