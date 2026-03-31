# Safe Chain Kandji/Iru Deployment Instructions

## Goal

Deploy Aikido Safe Chain per-user on macOS devices managed by Iru (Kandji), even though Kandji scripts run at the machine/root level.

## What Was Built

- `kandji-safe-chain-detect.sh`
- `kandji-safe-chain-remediate.sh`
- `README.md` (implementation and usage guide)

## Plan Executed

1. Reviewed prior script style in `sample/` to match operational patterns:
   - root-level execution
   - explicit logging
   - clear exit code behavior for detect/remediate flow
2. Designed user enumeration for local profiles:
   - enumerate local users from `dscl`
   - include only real local user accounts (`uid >= 500`, valid home directory, non-login-disabled shell)
3. Added compliance checks per profile:
   - `~/.safe-chain/bin/safe-chain` exists and is executable
   - version policy via `SAFE_CHAIN_VERSION_POLICY` / `SAFE_CHAIN_MINIMUM_VERSION` (see README)
   - shell profile files contain Safe Chain integration markers
4. Implemented version awareness:
   - `latest`: query GitHub releases API for `tag_name`; require installed version to match after normalizing leading `v`
   - `minimum`: compare installed version to `SAFE_CHAIN_MINIMUM_VERSION` only (no API in detect); remediate fetches latest tag only when an install is required
   - dotted semver-style comparison (e.g. `1.2.2` vs `1.4.6`) using `sort -V` after normalization
5. Implemented per-user remediation:
   - run installer as each user context with explicit `HOME` and user-first PATH
   - prefer `launchctl asuser ... sudo -u ...` and fallback to `sudo -u` if needed
   - use a release-tagged installer URL (`releases/download/<tag>/install-safe-chain.sh`)
   - include a fallback direct binary install if installer fails due to local nvm/npm/volta cleanup edge cases
   - re-verify version + shell markers after install (rules depend on `latest` vs `minimum`)
6. Added logs in `/var/log/safe-chain-kandji/` for troubleshooting.

## Detect/Remediate contract

- Detect returns:
  - `0` when all eligible users are compliant (or no eligible users are found)
  - `1` when one or more users require remediation, or when `latest` mode cannot determine the latest version (or policy variables are invalid)
- Remediate returns:
  - `0` when all required remediations succeed
  - `1` when any user remediation fails, or when a release tag cannot be resolved for an install that is needed (or policy variables are invalid)

## Notes

- The install command pattern is:
  - `curl -fsSL https://github.com/AikidoSec/safe-chain/releases/download/<tag>/install-safe-chain.sh | sh`
- Verification parses `safe-chain --version` first, then `safe-chain -v`, matching output of the form `Current safe-chain version: <version>`.
- Shell integration is validated by checking user shell startup files for Safe Chain markers.
