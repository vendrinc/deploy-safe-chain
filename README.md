# Kandji / Iru Safe Chain Deployment Scripts

This repository contains macOS scripts to deploy Aikido Safe Chain per-user in an Iru (Kandji) environment where scripts execute at machine scope.

## Files

- `kandji-safe-chain-detect.sh`  
  Kandji detection script. Enumerates local user profiles and checks Safe Chain compliance per user.
- `kandji-safe-chain-remediate.sh`  
  Kandji remediation script. Installs or updates Safe Chain per user when non-compliant.
- `instructions.MD`  
  Build plan and implementation notes.

## Compliance Criteria (Per User)

A user is considered compliant when all conditions are true:

1. `~/.safe-chain/bin/safe-chain` exists and is executable.
2. Installed Safe Chain version equals the latest GitHub release tag.
3. Shell profile files contain Safe Chain integration markers (so shell aliases/hooks are present).

## Detect Script Behavior

`kandji-safe-chain-detect.sh`:

- Enumerates local user accounts via `dscl`.
- Filters to real profiles:
  - UID >= 500
  - valid home directory
  - shell is not `false`/`nologin`
- Fetches latest version from GitHub API:
  - `https://api.github.com/repos/AikidoSec/safe-chain/releases/latest`
- Compares installed vs latest versions per user.
- Returns:
  - `0` if all eligible users are compliant
  - `1` if any user needs remediation or latest version cannot be fetched

## Remediate Script Behavior

`kandji-safe-chain-remediate.sh`:

- Uses same user enumeration + compliance checks as detect.
- For users that are not compliant, runs install as that user using a version-pinned installer URL:
  - `curl -fsSL https://github.com/AikidoSec/safe-chain/releases/download/<latest-tag>/install-safe-chain.sh | sh`
- Ensures user context includes correct `HOME` and a PATH with `~/.safe-chain/bin` first.
- Includes a fallback direct-binary install path if the upstream installer fails due to local package-manager cleanup edge cases.
- Re-validates version and shell markers after install.
- Returns:
  - `0` if all required remediations succeed
  - `1` if any remediation fails

## Logging

Logs are written to:

- Detect: `/var/log/safe-chain-kandji/detect.log`
- Remediate (root): `/var/log/safe-chain-kandji/remediate_root.log`
- Remediate (user execution output): `/var/log/safe-chain-kandji/remediate_user.log`

## Kandji Wiring

1. Upload `kandji-safe-chain-detect.sh` as the Detection script.
2. Upload `kandji-safe-chain-remediate.sh` as the Remediation script.
3. Ensure scripts run as root (standard Kandji custom script flow).

## Upstream Project

- Safe Chain repo: [AikidoSec/safe-chain](https://github.com/AikidoSec/safe-chain)
