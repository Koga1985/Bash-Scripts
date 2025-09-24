# Bash-Scripts (Enterprise-ready administrative scripts)

This repository is a collection of professionally-upgraded Bash automation scripts for common infrastructure tasks and hardening workflows. The scripts are written to be safe by default, idempotent where feasible, and documented so operators can run them confidently against target systems or clusters.

## Repository layout

- `AI/Edge SEIM AI.sh` — Deploy an edge AI detector and associated systemd service and logging configuration.
- `Kasten/Kasten Install and Config.sh` — Helm-based installer for Kasten K10 (idempotent, port-forward helper).
- `Kubernetes/Install and Configure.sh` — Kubernetes bootstrap script (docker, kubeadm, networking) tailored for Ubuntu systems.
- `OpenShift/Install and Configure.sh` — Installs the OpenShift `oc` client and provides convenience steps for bootstrapping projects.
- `Storage/LUKS Encryption.sh` — Interactive, idempotent script to LUKS-encrypt block devices and optionally persist crypttab/fstab entries.
- `Storage/SAN Hardening.sh` — Template driver for SAN hardening steps with vendor-specific placeholders and safe defaults.
- `VMware/ESXi Hardening.sh` — ESXi hardening helper script that validates environment, optionally removes VIBs, and configures NTP/syslog.

Each script contains inline documentation and follows the conventions listed below.

## Conventions used by the scripts

- Dry-run by default: Scripts simulate actions unless explicitly told to make changes. Use `--apply` to actually perform changes.

- Common flags supported (most scripts):
  - `--apply` — execute changes (disable dry-run)
  - `--yes` / `-y` — skip interactive confirmations
  - `--verbose` / `-v` — enable additional debug output

- Logging: Scripts write informational logs to a log file (usually under `/var/log/` or `/var/tmp`) and print timestamped messages to stdout.
- Idempotency: Where possible scripts check current system state and perform installs/upgrades only when needed.
- Backups: Before modifying important files, scripts will create timestamped backups (typically under `/var/tmp/` by default).
- Error handling: `set -euo pipefail` and traps are used to abort safely on unexpected failures.

## Quick start / Examples

Make a script executable (if not already):

```bash
chmod +x "Kasten/Kasten Install and Config.sh"
```

Dry-run (default) — show what would happen without making changes:

```bash
sudo ./"Kasten/Kasten Install and Config.sh"
# or explicitly: sudo ./"Kasten/Kasten Install and Config.sh" --verbose
```

Apply changes (be careful!) — run with `--apply` and optionally `--yes` to skip prompts:

```bash
sudo ./"Kasten/Kasten Install and Config.sh" --apply --yes
```

Notes:

- Running these scripts typically requires root privileges (`sudo`) and the appropriate CLI tools present on the system (for example `helm`, `kubectl`, `cryptsetup`, or `esxcli`, depending on the script).
- Read the top of each script for script-specific prerequisites and variables you can override.

## Prerequisites and recommended tools

- Bash (4.x+ recommended)
- shellcheck (for linting)
- jq (used by some scripts for JSON handling when interacting with APIs)
- Platform-specific CLIs as required by each script (e.g., `helm`, `kubectl`, `oc`, `esxcli`)

Install shellcheck on Debian/Ubuntu:

```bash
sudo apt update && sudo apt install -y shellcheck
```

Run shellcheck (example):

```bash
shellcheck "Kasten/Kasten Install and Config.sh"
```

## How these scripts were improved

Across the repository each script was modernized with the following improvements:

- Strict bash settings (`set -euo pipefail`) and safe IFS handling.
- Centralized logging functions and optional `--verbose` output.
- `run_cmd()` wrappers to support dry-run mode and consistent execution.
- Idempotent checks (install vs upgrade, resource exists checks).
- Timestamped backups before overwriting important files.
- Clear operator prompts and `--yes` to skip prompts for automation.

## Contributing

If you want to contribute:

1. Fork the repository and create a feature branch.
2. Add or update scripts; keep the same conventions (dry-run default, `--apply`, logging).
3. Run `shellcheck` and basic tests where applicable.
4. Open a pull request with a clear description of the change and testing performed.

## License

This repository does not include an explicit license file. If you plan to use or redistribute these scripts, consider adding a LICENSE file (for example, MIT or Apache-2.0) to clarify permissions.

## Support / Contact

If you need help adapting a script to your environment, open an issue or add a note in the pull request describing your platform, desired behavior, and any errors/log output.

---

*Small, safe, and practical: these scripts are designed to be operator-friendly starting points — customize them to match your environment and policies before running in production.*

