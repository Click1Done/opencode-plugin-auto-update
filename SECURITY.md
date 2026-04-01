# Security Policy

## Supported Versions

This project currently supports the latest version on the default branch.

## Reporting a Vulnerability

Please do **not** open a public GitHub issue for suspected security vulnerabilities.

Instead, report vulnerabilities privately to the maintainer before public disclosure. Include:

- affected version or commit
- environment details (Windows version, PowerShell version, OpenCode version)
- reproduction steps
- expected impact

Until a dedicated security contact address is published, use a private communication channel with the maintainer and avoid sharing secrets, tokens, or full local logs publicly.

## Security Notes

- This tool reads and rewrites local OpenCode configuration under `%USERPROFILE%\\.config\\opencode`.
- It may restart local OpenCode processes after plugin updates.
- Logs and journals may include local file paths and package metadata. Review them before sharing.
