# MySQL root password reset for Windows

This utility resets `root@localhost` for a MySQL Server installed as a Windows
service. It is Windows-only; it does not manage MySQL on Linux, macOS, containers,
or remote servers.

## Requirements and support

- Windows PowerShell 3.0 or later for the reset workflow. Windows PowerShell
  5.1 or later is required for the graphical reset window and automatic updater.
- Windows Forms, included with Windows PowerShell, for the reset and update
  dialogs on 5.1 or later.
- A local MySQL Windows service with `mysqld.exe`, `mysql.exe`, and
  `mysqladmin.exe` in the same `bin` directory.
- Administrator approval when the reset is run.
- A MySQL option file without `!include` or `!includedir` directives for
  automatic port detection.
- The new password must be at least 8 printable ASCII characters.

Windows PowerShell versions earlier than 5.1 automatically use the console
workflow and skip automatic update checks. If the reset window cannot be
created or displayed, the utility reports the reason and falls back to console
prompts; cancelling the window or encountering a reset error does not trigger
fallback. PowerShell earlier than 3.0 is rejected before the embedded script
is parsed.

The current verified environment is Windows PowerShell 5.1 with MySQL Server
8.0.46. Other MySQL versions, Windows architectures, and Windows releases need
validation on the target device before deployment.

## Automatic updates

On normal startup with Windows PowerShell 5.1 or later, the utility checks the
latest public GitHub release. When a newer supported release is available, a
Windows dialog lets you choose **Update and reopen** or **Not now**. Updates
are never installed silently. The utility
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

You can also double-click `mysql_reset.bat`. Choose the intended service in the
reset window; when launching from a terminal, pass `-ServiceName` explicitly to
preselect it.

Approve the Windows UAC prompt, then choose the MySQL service, enter and confirm
the new password, and check the confirmation box in the reset window. The
progress log stays visible during the reset; **Open reset log** opens the
restricted audit log in Notepad. The final window reports success or includes
the failure reason and suggested fix. Close it after reviewing the result.
The reset window starts in dark mode; use **Dark mode** to switch between dark
and light themes. After the elevated reset window is displayed, its console is
hidden so the window remains the primary interface.
The selected service is stopped while the password is changed. After a
successful reset, the script starts the service and verifies that the new
password works, even if the service was stopped before the reset. If a reset
fails, a service that was running beforehand is restored when possible; a
service that was already stopped is left stopped.

The script writes its temporary init SQL into a unique per-run directory with
restricted ACLs and removes the file after use. Passwords are never passed as
command-line arguments or written to the audit log.

Use `-Console` to use the original PowerShell prompts instead of the reset
window. Console mode and compatibility fallback keep the terminal visible. In
console mode, the result stays visible until you press Enter. A
successful reset leaves the selected service running and ready for connections.
For scripted runs, combine `-Console -NoWait` to return without waiting for a
key press. Read-only preflight never opens the reset UI or waits.

## Tests

Run the local regression checks with:

```powershell
powershell.exe -NoProfile -File .\tests\mysql_reset.tests.ps1
```

These checks cover embedded-script parsing, argument quoting, service
selection (including the interactive service picker), updater release
validation and safe file replacement, service-account ACL mapping, port
parsing, password SQL generation, reset-form validation, compatibility
fallback, console visibility ordering, dark/light theme toggling, UI progress
logging, and visible result details. The read-only batch preflight and MySQL
configuration validator should also be run on each target installation. The
regression suite does not reset a production database.

## License

No license is included. Public visibility alone does not grant permission to
reuse or redistribute this software.
