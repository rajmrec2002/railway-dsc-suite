# Railway DSC Signer Suite

One script that installs the three Indian Railways digital-signature (DSC) signer
services on Linux and keeps them running.

| Service | Endpoint | Used by |
|---|---|---|
| eOffice signer (NIC Digital Signer Service 7.0.6) | `https://127.0.0.1:55103` | eOffice |
| eOffice v4.1 compatibility bridge | `https://127.0.0.1:55101` | older eOffice portals |
| CrisSigner | `wss://127.0.0.1:2039` | CRIS portals |
| IREPSSigner | `wss://127.0.0.1:2175` | IREPS |

## What is and is not in this repository

Only the script is here. The signer programs themselves (the vendor jars, the Java
runtime, the bridge's TLS key and the token driver) are **not** in the repository:
they are vendor software, and the bundle is about 280 MB. The script builds that
bundle from a machine where the services already work.

## Use

On a machine where all three services already work:

    ./railway-dsc-suite.sh pack

This writes one file, `railway-dsc-suite-<date>.run` (script + payload).
Copy it to the target PC and run it as the normal desktop user:

    bash railway-dsc-suite-<date>.run install

It asks for sudo only for the system-level steps (packages, `/usr/local`, token
driver, udev rule, `/etc/hosts`). Running `install` again is safe and acts as a repair.

Package managers handled: apt, dnf/yum, zypper, pacman, apk, xbps.

Everyday commands after install:

    railway-dsc status      # health of every service, token and watchdog
    railway-dsc logs        # recent watchdog actions and service logs
    railway-dsc restart     # restart all signers
    railway-dsc heal        # run the watchdog once now
    railway-dsc uninstall   # remove services and watchdog (--purge removes programs too)

Settings live in `~/.config/railway-dsc/suite.conf` (window scale, token driver path,
bridge listen addresses).

## Self-healing

- Every service restarts itself within 5 seconds if it exits or is killed.
- A watchdog runs every 3 minutes and asks each port for a real answer
  (HTTPS `isLive`, or a WebSocket handshake). Two failed checks restart the service.
- Damaged or missing program files are restored from a kept copy
  (everything except the Java runtime).
- Duplicate eOffice signer instances are removed; the vendor login-shell autostart
  hook, which makes a second instance kill the first, is disabled at install.
- Missing service definitions are rewritten; logs over 20 MB are rotated.
- Without a systemd user session, a supervisor started from desktop autostart does
  the same job.

## Limits

- The bundled Java and the mToken driver are x86_64 only. On other CPUs a system
  Java 17 is used and the token vendor's own driver is needed.
- Only the Longmai mToken CryptoID driver is bundled. Other tokens need their
  vendor's Linux driver; common locations are auto-detected.
- The signers are Swing applications and need an X display (XWayland is fine).
- If the token holds only the user certificate, the CA chain must be written to the
  token separately; the installer does not do this.

## Test status (2026-11-14)

Tested on Ubuntu: payload checksums, install into a throwaway home directory, file
self-repair, health probes against live services, the bridge on a spare port, and
systemd validation of the generated units.

Not yet tested: a real install on a second machine, the sudo phase on non-Ubuntu
distributions, and the non-systemd supervisor running real services.
