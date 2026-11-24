# Changelog

## 1.0.1 - 2026-11-24

### Fixed

- Double-click runs now offer an explicit numbered choice when multiple MySQL
  services are installed, instead of exiting before password entry.

## 1.0.0 - 2026-11-24

### Added

- Windows MySQL `root@localhost` password reset through the service's configured
  MySQL installation.
- Read-only preflight and regression checks.
- Explicit service selection when multiple MySQL services are installed.
- Per-run restricted ACLs and cleanup for the temporary password SQL file.
- GitHub Actions coverage for Windows PowerShell 5.1 and PowerShell 7 on
  Windows Server 2022 and 2025 runners.
