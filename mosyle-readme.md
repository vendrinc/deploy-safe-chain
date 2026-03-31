# Mosyle: Safe Chain custom command

Mosyle provides a **single** custom command script per profile, unlike Kandji’s separate **Detection** and **Remediation** scripts. This repository adds **`mosyle-safe-chain.sh`**, which combines the same logic as `kandji-safe-chain-detect.sh` and `kandji-safe-chain-remediate.sh`.

Upstream product: **[Aikido Safe Chain](https://github.com/AikidoSec/safe-chain)** by **AikidoSec** (see `license.txt`).

## Behavior

| `SAFE_CHAIN_MOSYLE_MODE` | What happens |
|--------------------------|----------------|
| **`both`** (default) | Run **detection** first. If every eligible user is compliant, exit **0** and stop. If anyone is non-compliant, run **remediation** (install/update). If detection hits a **fatal** error (invalid config, GitHub API failure when required), exit **1** and **do not** remediate. |
| **`detect`** | Detection only: exit **0** if compliant, **1** if remediation is needed or detection fails. |
| **`remediate`** | Remediation only (same behavior as the Kandji remediate script; skips users who are already compliant). |

Environment variables for version policy (`SAFE_CHAIN_VERSION_POLICY`, `SAFE_CHAIN_MINIMUM_VERSION`, `SAFE_CHAIN_RELEASE_TAG`, `SAFE_CHAIN_INSTALLER_SHA256`) are the same as in the [README](README.md) for the Kandji scripts.

## Logs

Logs are separate from Kandji so you can tell MDMs apart:

| Path | Contents |
|------|----------|
| `/var/log/safe-chain-mosyle/safe-chain.log` | Main line: detection/remediation messages from root context |
| `/var/log/safe-chain-mosyle/user.log` | Per-user install command output |

## Scheduling (including daily)

In **Mosyle Manager → Custom Commands**, create or edit a profile that runs this script **as root** (or per your security model).

1. **Trigger**  
   Choose **“Only based on schedule or events”** (or equivalent) so the command is not tied to a single one-off event unless you want that.

2. **Daily schedule**  
   Under **Schedule**, enable **“Every day at”** and set the time (24-hour or AM/PM, depending on the UI). That runs the script once per day at the chosen time on enrolled Macs that match the profile scope.

3. **Event-triggered runs (optional)**  
   You can also combine with events such as **“Every ‘Device Info’ update”** or **“Every user sign-in”** if you want extra runs between daily executions. Use sparingly if you want to avoid redundant installs.

4. **Recommended default mode**  
   Leave **`SAFE_CHAIN_MOSYLE_MODE=both`** (or unset) so each run checks compliance and only installs when something is wrong.

5. **Environment variables**  
   If the Mosyle UI supports environment variables for the command, set the same pins as in Kandji (for example `SAFE_CHAIN_RELEASE_TAG`, `SAFE_CHAIN_VERSION_POLICY`). If not, you can wrap the script in a tiny launcher that `export`s those variables then `exec`s `mosyle-safe-chain.sh`.

## Upload

1. Upload **`mosyle-safe-chain.sh`** to the custom command (or host it and use a `curl | bash` stub—your org’s security policy applies).  
2. Ensure the file is executable (`chmod +x mosyle-safe-chain.sh`).  
3. Scope the profile to the right Mac groups and test on a small set.

## Parity with Kandji

| Kandji | Mosyle |
|--------|--------|
| `kandji-safe-chain-detect.sh` | `SAFE_CHAIN_MOSYLE_MODE=detect` |
| `kandji-safe-chain-remediate.sh` | `SAFE_CHAIN_MOSYLE_MODE=remediate` |
| Run detect on a schedule + remediate on separate automation | **Default** `both` in one scheduled command |
