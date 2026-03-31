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
   - installed version matches latest GitHub release
   - shell profile files contain Safe Chain integration markers
4. Implemented latest-version awareness:
   - query GitHub releases API for `tag_name`
   - normalize leading `v` for version comparison
5. Implemented per-user remediation:
   - run installer as each user context with explicit `HOME` and user-first PATH
   - prefer `launchctl asuser ... sudo -u ...` and fallback to `sudo -u` if needed
   - use a version-pinned installer URL to avoid deprecated `SAFE_CHAIN_VERSION` flow
   - include a fallback direct binary install if installer fails due to local nvm/npm/volta cleanup edge cases
   - re-verify version + shell markers after install
6. Added logs in `/var/log/safe-chain-kandji/` for troubleshooting.

## Detect/Remediate Contract

- Detect returns:
  - `0` when all eligible users are compliant (or no eligible users are found)
  - `1` when one or more users require remediation, or if detect cannot determine latest version
- Remediate returns:
  - `0` when all required remediations succeed
  - `1` when any user remediation fails, or if latest version cannot be resolved

## Notes

- The install command used is exactly:
  - `curl -fsSL https://github.com/AikidoSec/safe-chain/releases/download/<latest-tag>/install-safe-chain.sh | sh`
- Verification logic parses `safe-chain -v` output in the same style as upstream installer logic.
- Shell integration is validated by checking user shell startup files for Safe Chain markers.
