# Changelog

## 1.1.2 - 2026-11-24

### Fixed

- Retry temporary MySQL connection-refused responses during server startup
  instead of treating native-command stderr as a fatal PowerShell error.

## 1.1.1 - 2026-11-24

### Fixed

- Keep reset success, cancellation, and failure results visible until
  acknowledged instead of closing the console immediately.
- Explain when the MySQL service remains stopped because it was stopped before
  the reset, and add a no-wait option for scripted runs.

## 1.1.0 - 2026-11-24

### Added

- On-start update checks with a native Windows dialog and explicit user consent.
- HTTPS release downloads with strict version, size, and SHA-256 validation,
  safe replacement with rollback, and automatic relaunch.
- A GitHub Actions release workflow that attaches the versioned launcher asset.

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
