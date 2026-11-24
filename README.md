# MySQL root password reset for Windows

This utility resets `root@localhost` for a MySQL Server installed as a Windows
service. It is Windows-only; it does not manage MySQL on Linux, macOS, containers,
or remote servers.

## Requirements and support

- Windows PowerShell 5.1, included with supported Windows client and server
  installations.
- A local MySQL Windows service with `mysqld.exe`, `mysql.exe`, and
  `mysqladmin.exe` in the same `bin` directory.
- Administrator approval when the reset is run.
- A MySQL option file without `!include` or `!includedir` directives for
  automatic port detection.
- The new password must be at least 8 printable ASCII characters.

The current verified environment is Windows PowerShell 5.1 with MySQL Server
8.0.46. Other MySQL versions, Windows architectures, and Windows releases need
validation on the target device before deployment.

## Preflight

Run this first from Command Prompt or PowerShell. It is read-only and does not
request elevation:

```powershell
.\mysql_reset.bat -Preflight -ServiceName MySQL80
```

Preflight checks the selected service, service account, MySQL executables,
option-file path, and configured server port. If multiple MySQL services exist,
select the intended one explicitly with `-ServiceName`.

## Reset

```powershell
.\mysql_reset.bat -ServiceName MySQL80
```

You can also double-click `mysql_reset.bat`. If more than one MySQL service is
found, choose the intended service from the numbered list. When launching from a
terminal, pass `-ServiceName` explicitly.

Approve the Windows UAC prompt, enter and confirm the new password in the
elevated PowerShell window, then confirm the reset. The selected service is
stopped while the password is changed. The script restores its original
Running/Stopped state and reports explicitly if restoration fails.

The script writes its temporary init SQL into a unique per-run directory with
restricted ACLs and removes the file after use. Passwords are never passed as
command-line arguments or written to the audit log.

## Tests

Run the local regression checks with:

```powershell
powershell.exe -NoProfile -File .\tests\mysql_reset.tests.ps1
```

These checks cover embedded-script parsing, argument quoting, service
selection (including the interactive service picker), service-account ACL
mapping, port parsing, and password SQL generation. The read-only batch
preflight and MySQL configuration validator should also be run on each target
installation. The regression suite does not reset a production database.

## License

No license is included. Public visibility alone does not grant permission to
reuse or redistribute this software.
