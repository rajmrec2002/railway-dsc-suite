# Railway DSC Signer Suite

One script that installs, repairs and keeps running the three Indian Railways
digital-signature (DSC) signer services on Linux. It is written for Ubuntu and also
handles Debian/Mint/Pop!_OS, Fedora/RHEL, openSUSE, Arch, Alpine and Void.

| Service | Endpoint | Used by |
|---|---|---|
| eOffice signer: NIC DSC Signer Service **4.1.8** | `https://eoffsigner.eoffice.gov.in:55101` | eOffice portals configured for signer 4.1 (e.g. `*.eoffice.railnet.gov.in`) |
| CrisSigner | `wss://127.0.0.1:2039` | CRIS portals |
| IREPSSigner | `wss://127.0.0.1:2175` | IREPS |

## Quick start (Ubuntu)

1. Download the official **eOffice DSC Signer Service 4.1.8 Windows installer**
   (`Digital Signer Service 4.1.8_x64.msi`) into `~/Downloads`. The program inside
   is plain Java and runs unchanged on Linux.
2. Also keep NIC's **7.0.x Ubuntu installer zip** in `~/Downloads`, if you have it.
   It carries NIC's renewed HTTPS certificate, because the one inside 4.1.8 expired on
   21-06-2026. Without a valid certificate, browsers refuse to talk to the signer.
3. Install your token's Linux driver (for the Longmai mToken: `/usr/lib/libcryptoid_pkcs11.so`).
4. Run, as your normal desktop user:

       bash railway-dsc-suite.sh install

   It asks for `sudo` only for system steps: packages, `/etc/hosts`, the udev rule and the token driver.
5. Log out of eOffice and log in again. When you sign, NIC's small **PIN window**
   appears. It may sit behind the browser.

Run `install` again at any time. It repairs whatever is broken and leaves healthy
parts alone (`repair` is the same command).

## Commands

    railway-dsc doctor      # check everything; explains each problem and its fix
    railway-dsc status      # health of every service, token and watchdog
    railway-dsc install     # install / repair   (--msi=FILE, --no-root, --no-download)
    railway-dsc logs        # recent watchdog actions and signer logs
    railway-dsc restart     # restart all signers
    railway-dsc heal        # run the watchdog once now
    railway-dsc trust       # re-add the signer certificates to all browser stores
    railway-dsc pack        # build a portable one-file installer from this machine
    railway-dsc uninstall   # remove services (--purge also removes program files)

## Portable installer for other PCs

On a machine where the signers work, run `railway-dsc pack`. It writes
`railway-dsc-suite-<date>.run` (about 310 MB), which contains the script, the three
signers, a Java 8 and a Java 17 runtime, and the mToken driver. Copy that file to
another PC and run `bash railway-dsc-suite-<date>.run install`. No internet access is
needed. The file contains vendor TLS keys, so it is created readable by the owner only.
Don't publish it.

## What the script does for eOffice 4.1.8 on Linux

NIC's jar is never modified. Everything is done around it:

| Problem on Linux | Fix |
|---|---|
| eOffice portals configured for signer "4.1" reject 7.x (no `/signing/textSigning`, DSC-02 "Purpose is not defined") | runs 4.1.8, which speaks the 4.1 protocol on port 55101. eOffice compares only "4.1", so 4.1.8 is accepted |
| 4.1.8 uses the Java-8-only `SunPKCS11(String)` API | Java 8 runtime with GUI libraries: package `openjdk-8-jre`, the bundled one, or Eclipse Temurin 8 |
| On Linux the signer looks for a file named `pkcs11cfg` in its working directory | writes one that points at the detected token driver |
| Its built-in HTTPS certificate expired on 21-06-2026 | uses NIC's renewed certificate (valid to 2028) via `--server.ssl.key-store`, taken from a 7.0.x package |
| Ubuntu's Java 8 loads a missing GNOME accessibility bridge, and every Swing window, including the PIN prompt, crashes (`AWTError: Assistive Technology not found`; shows up as HTTP 406 / NullPointerException) | `-Djavax.accessibility.assistive_technologies=` |
| The signer answers 401 "Invalid Request." to any Host other than `eoffsigner.eoffice.gov.in` | `/etc/hosts` maps that name to loopback |
| The signer listens on all network interfaces by default | binds it to the loopback address only (`--server.address`) |
| Old setups (7.0.6 service, v4 compatibility bridge on 55101, vendor `/etc/profile.d` autostart hook) conflict | disabled automatically; their files are kept |

## Look and scaling

- **CrisSigner and IREPSSigner** ask Java for the "Windows" look, which does not exist on
  Linux. The suite puts a small stand-in first on their class path. It is GTK
  underneath (source in `extras/gtk-look/`), so their windows follow the desktop theme
  (e.g. Ubuntu's Yaru) and fonts.
- **Scale follows the desktop automatically** (`DSC_UI_SCALE=auto`). It is read from
  `Xft.dpi` (GNOME sets 192 for 2x with native XWayland scaling, and 96 when the
  compositor scales X apps itself), then `GDK_SCALE`, then GNOME's `scaling-factor`.
  Java's GTK look would otherwise size text from the desktop DPI *and* apply the
  scale again, giving double-size text. The stand-in corrects this, so text matches
  native apps.
- To change this, edit `~/.config/railway-dsc/suite.conf` (`DSC_UI_SCALE=2`,
  `DSC_LOOK=metal`) and run `railway-dsc install`.
- **The eOffice PIN window** runs on Java 8, which cannot scale Swing on Linux, so it
  keeps NIC's fixed pixel size. It is small on HiDPI screens but works.

## Self-healing

- Every service restarts within 5 seconds if it exits or is killed.
- A watchdog runs every 3 minutes. It asks each port for a real answer (HTTPS
  `isLive` with the right Host header, or a WebSocket handshake) and restarts a
  service after two failed checks.
- Damaged or missing program files are restored from a kept copy.
- Duplicate signer instances and resurrected legacy services are removed.
- Missing service definitions are rewritten, and logs over 20 MB are rotated.
- An expired certificate, a missing hosts entry or a returning vendor hook triggers
  a once-a-day desktop notification.
- Without a systemd user session, a supervisor started from desktop autostart does
  the same job.

## Troubleshooting

Start with `railway-dsc doctor`. Common messages from the portals:

| Message | Meaning |
|---|---|
| "Unable to connect with DSC service application. Verify Network." | nothing is answering on 55101. Run `railway-dsc status` |
| "Either Response size is heavy or it is a Browser compatibility issue" | the signer answered with an HTTP error (often 401 Host mismatch, or a crashed PIN window). Run `railway-dsc doctor` |
| "Mismatch in DSC version" | the portal expects another signer version (e.g. 7.x); check the portal's `dscVersion` |
| "Please check the signer service: [object Event]" (CRIS/IREPS) | the browser refused the local certificate. Run `railway-dsc trust`; in Firefox also open `https://127.0.0.1:2039` once and accept |

Don't click **Register DSC** repeatedly while debugging: each click deactivates the
currently active registration.

## What is and is not in this repository

Only the script is here. The signer programs, Java runtimes, TLS keys and token
drivers are vendor software and are **not** included. The script takes them from the
official installers, from a `.run` bundle you build yourself, or from an existing
installation.

## Test status (2026-11-15, Ubuntu 26.04)

- eOffice 4.1.8 set up this way signed and forwarded a file on a railway eOffice portal.
- Tested in a throwaway home directory:
  - install from the MSI;
  - `pack` and installing from the `.run`;
  - Java runtimes from the payload;
  - the Temurin download lookup;
  - the generated launcher on a spare port (loopback-only binding, probe, CA-verified HTTPS);
  - `doctor` against the live services.
- Not yet tested: the sudo phase on non-Ubuntu distributions, and the non-systemd
  supervisor running real services.
