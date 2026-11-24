# MySQL root password reset for Windows

This utility resets `root@localhost` for a MySQL Server installed as a Windows
service. It is Windows-only; it does not manage MySQL on Linux, macOS, containers,
or remote servers.

## Requirements and support

- Windows PowerShell 5.1, included with supported Windows client and server
  installations.
- Windows Forms, included with Windows PowerShell, for the update dialog.
- A local MySQL Windows service with `mysqld.exe`, `mysql.exe`, and
  `mysqladmin.exe` in the same `bin` directory.
- Administrator approval when the reset is run.
- A MySQL option file without `!include` or `!includedir` directives for
  automatic port detection.
- The new password must be at least 8 printable ASCII characters.

The current verified environment is Windows PowerShell 5.1 with MySQL Server
8.0.46. Other MySQL versions, Windows architectures, and Windows releases need
validation on the target device before deployment.

## Automatic updates

On normal startup, the utility checks the latest public GitHub release. When a
newer supported release is available, a Windows dialog lets you choose **Update
and reopen** or **Not now**. Updates are never installed silently. The utility
downloads only the `mysql_reset.bat` asset from this repository's HTTPS release
URL and verifies its size, version, and SHA-256 digest against GitHub release
metadata before replacing anything.

The replacement is limited to the currently running `mysql_reset.bat` in a
folder writable by your Windows user. It keeps a rollback copy until the new
launcher has been started, then removes the old copy. If the folder is protected
(for example, under `Program Files`), the update is refused and the current
version remains unchanged; move the script to a user-writable folder to enable
in-place updates. If the network or release metadata is unavailable, the utility
reports the problem and continues with the current version.

After an update, the new version starts its normal reset flow. It still requires
the usual service choice, password entry, and final reset confirmation. Versions
prior to `1.1.0` do not contain the updater; download `mysql_reset.bat` from the
latest release once to enable future update checks. Use `-SkipUpdateCheck` to
skip the startup check.

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

After a reset, cancellation, or failure, the result stays visible until you
press Enter. A service that was stopped before the reset remains stopped; start
it in Services before connecting. For scripted runs, pass `-NoWait` to return
without waiting for a key press. Read-only preflight never waits.

## Tests

Run the local regression checks with:

```powershell
powershell.exe -NoProfile -File .\tests\mysql_reset.tests.ps1
```

These checks cover embedded-script parsing, argument quoting, service
selection (including the interactive service picker), updater release
validation and safe file replacement, service-account ACL mapping, port
parsing, and password SQL generation. The read-only batch preflight and MySQL
configuration validator should also be run on each target installation. The
regression suite does not reset a production database.

## License

No license is included. Public visibility alone does not grant permission to
reuse or redistribute this software.
