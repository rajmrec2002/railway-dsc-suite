# Railway DSC Signer Suite

> **Unofficial.** Not made, endorsed or supported by NIC, CRIS, eMudhra or Indian Railways.
> It installs those vendors' own signer programs, which you must obtain yourself, and
> makes them work on Linux. See [NOTICE](NOTICE).

One script that installs, repairs and keeps running the three Indian Railways
digital-signature (DSC) signer services on Linux. It is written for Ubuntu and also
handles Debian/Mint/Pop!_OS, Fedora/RHEL, openSUSE, Arch, Alpine and Void.

| Service | Endpoint | Used by |
|---|---|---|
| eOffice signer: NIC DSC Signer Service **4.1.8** | `https://eoffsigner.eoffice.gov.in:55101` | eOffice portals configured for signer 4.1 (e.g. `*.eoffice.railnet.gov.in`) |
| eOffice signer: NIC DSC Signer Service **7.0.6** (optional) | `https://eoffsigner.eoffice.gov.in:55103` | eOffice portals configured for signer 7.x |
| CrisSigner | `wss://127.0.0.1:2039` | CRIS portals |
| IREPSSigner | `wss://127.0.0.1:2175` | IREPS |

It also sets up **signing PDFs with the same DSC token** outside the portals (see
[Signing PDFs](#signing-pdfs)).

## Quick start on a new PC (Ubuntu)

1. Download this repository (green **Code** button → *Download ZIP*) and unpack it, or
   `git clone` it.
2. Put the vendors' installers in `~/Downloads`:

   | Signer | File (exact version the kit is made for) |
   |---|---|
   | eOffice 4.1.8 | `Digital Signer Service 4.1.8_x64.msi` (NIC) |
   | eOffice 7.0.6 (optional) | `DigitalSignerService_7.0.6_Ubuntu_Installer.zip` (NIC). It also carries the renewed HTTPS certificate 4.1.8 needs |
   | CrisSigner | `CrisSigner.msi`, SHA-256 `aaa1c7aa…` |
   | IREPSSigner | `IREPSSigner.msi` of 04-11-2026, SHA-256 `1969e090…` (31.6 MB) |

3. Install your token's Linux driver (Longmai mToken: `/usr/lib/libcryptoid_pkcs11.so`).
4. In the unpacked folder, run as your normal desktop user:

       bash railway-dsc-suite.sh install

The installers are recognised by checksum, whatever their file names. CRIS and IREPS
are built from their Windows installers plus the [Linux patch kit](#linux-patch-kit-for-cris-and-ireps).
If only `CrisSigner.msi` is present, its extra open-source libraries are downloaded
from Maven Central, each pinned by checksum.

## Quick start on a PC that already has the signers (Ubuntu)

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

## DSC tokens and drivers

The suite works with any user's DSC: certificates are read from the token at signing
time, and nothing user-specific is stored or bundled. Each signer is pointed at the
driver that matches the **token plugged in** (checked whenever a signer starts):

| Token (USB vendor) | Driver used | Status |
|---|---|---|
| Longmai **mToken** CryptoID (055c) | `/usr/lib/libcryptoid_pkcs11.so` (in the `.run` bundle) | tested |
| Feitian **ePass2003 / ePass2003 Auto** (096e) | Feitian's `libcastle.so.1.0.0` or eMudhra's `libcastle_v2.so.1.0.0` if available, otherwise **OpenSC** (installed automatically, open source) | not tested with a real token |
| **Hypersecu HYP2003** (2ccf:080a) | Hypersecu's own `libcastle_v2.so.1.0.0` (OpenSC does not drive it); the suite adds the token to the smart-card reader list | reported working on one PC with manual steps; suite automation not tested with a real token |
| Precision **InnaIT KeyDSC** (338c) | Precision's `libInnaITPKCS11Driver.so`; the suite adds the token to the smart-card reader list | not tested with a real token |
| WatchData **ProxKey** / TrustKey (163c) | WatchData's `libwdpkcs_SignatureP11.so`, run against Ubuntu's own smart-card service | not tested with a real token; see below |
| SafeNet eToken (0529), Gemalto/Thales IDPrime (08e6), JaCarta (24dc), smart-card readers | vendor driver if installed; OpenSC for Gemalto cards and readers | not tested |

**Vendor drivers.** Download the Linux driver from the
[eMudhra repository](https://www.e-mudhra.com/Repository/) (Token Drivers: `ePass2003_Linux.zip`,
`ProxKey_Linux.zip`, Precision InnaIT `InnaITDSC_Setup.zip`), or get Hypersecu's
`HYP2003-Linux-x86_64-FIPS140-3.zip` from [hypersecu.com/india-support](https://www.hypersecu.com/india-support). Leave it in `~/Downloads` and run `railway-dsc install`.
The private `.run` bundle already carries the known builds.

- Only the PKCS#11 library is taken, after its SHA-256 is checked against the builds the suite
  knows. The vendors' installers are **not** run: they add world-writable udev rules, init
  scripts, autostart entries or their own smart-card daemon. A build the suite does not know
  is used only when named: `railway-dsc install --driver=FILE` (`--epass-zip=FILE` still works).
- Drivers are installed to `/usr/lib/railway-dsc/<vendor>/` (ProxKey:
  `/usr/lib/WatchData/ProxKey/lib/`), so clearing `~/Downloads` does not break them.
- **Hypersecu / InnaIT:** Ubuntu's CCID driver does not list these tokens yet, so the suite adds
  their USB ids to `ifd-ccid.bundle/Contents/Info.plist` (backup `Info.plist.bak-railway-dsc`) and
  restarts `pcscd`. A `libccid` package update undoes this; `railway-dsc doctor` notices, and
  `railway-dsc install` adds them again.
- **ProxKey:** the driver expects WatchData's own copy of pcsc-lite and the old `libxml2.so.2`.
  The suite puts two links in `/usr/lib/WatchData/pcsc/` (the driver's built-in library path,
  so nothing else on the system is affected): to the system `libpcsclite.so.1`, and to
  `libxml2.so.16`, which still has the 7 functions the driver uses. That covers the CCID
  ProxKeys (163c:0407/0417/0418), which Ubuntu's CCID driver already knows. The HID/UDK
  models (0402/0412/0620/5471) need WatchData's own daemon, which the suite does not install.
- **Two different tokens:** the first one plugged in wins. `P11_LIB=/path/to/driver.so` in
  `~/.config/railway-dsc/suite.conf` picks one, but it is ignored while a token of another
  make is plugged in (`doctor` says so). `P11_FORCE=1` uses it anyway.
- `railway-dsc doctor` shows, for each plugged token, which driver will be used or what
  to install.

## Choosing the eOffice signer version

Different eOffice portals ask for different signer versions. `install` asks which one
you need, or you can choose directly:

    railway-dsc install --eoffice=4      # 4.1.8 only (default; portals set to "4.1", port 55101)
    railway-dsc install --eoffice=7      # 7.0.6 only (portals set to "7.x", port 55103)
    railway-dsc install --eoffice=both   # both side by side; their ports do not clash

The choice is saved as `DSC_EOFFICE` in `~/.config/railway-dsc/suite.conf`. Switching
turns off the version you no longer want but keeps its files. Not sure which one you
need? Choose `both`. With the wrong signer, a portal says "Unable to connect with DSC
service application" or "Mismatch in DSC version".

7.0.6 comes from NIC's `DigitalSignerService_7.0.6_Ubuntu_Installer.zip` in `~/Downloads`
(or `--zip7=FILE`, the unpacked folder, or an existing `/usr/local` install). It is
checksum-pinned and runs unmodified on Java 17 (NIC's bundled `jre.zip` is used when no
Java 17 is installed). Like 4.1.8, it is bound to the loopback address only.

## Commands

    railway-dsc doctor      # check everything; explains each problem and its fix
    railway-dsc status      # health of every service, token and watchdog
    railway-dsc install     # install / repair   (--eoffice=4|7|both, --msi=FILE, --zip7=FILE, --no-pdf, --no-root, --no-download)
    railway-dsc logs        # recent watchdog actions and signer logs
    railway-dsc restart     # restart all signers
    railway-dsc heal        # run the watchdog once now
    railway-dsc trust       # re-add the signer certificates to all browser stores
    railway-dsc pack        # build a portable one-file installer from this machine
    railway-dsc uninstall   # remove services (--purge also removes program files)

## Signing PDFs

`install` also sets up PDF signing with the token (leave it out with `--no-pdf`):

- **Document Viewer (GNOME Papers)** is installed. It signs PDFs itself: open the PDF,
  choose to add a digital signature, draw the box, enter the token PIN, pick your
  certificate, then **Save Signed File**.
- **`sign-pdf`**: `sign-pdf letter.pdf [--reason R] [--location L] [--page N | --pages all|first|last|1,3,5-7] [--pos br|bl|tr|tl | --box l,t,r,b] [--draw|--no-draw] [--invisible]`
  writes `letter_signed.pdf` (PAdES, SHA-256, visible box at the bottom right of the last
  page by default) and checks it with `pdfsig`. The same is available as the app
  **Sign PDF with DSC** (also under *Open With* for PDFs) and in Files under
  right-click > *Scripts*. The PIN is asked for each time and never stored.

What the install changes for this:

| Change | Why |
|---|---|
| The token's PKCS#11 driver is registered in `~/.pki/nssdb` | Document Viewer finds certificates through NSS |
| **CCA India 2022** is trusted in `~/.pki/nssdb` for signatures only (`,C,`; fingerprint pinned) | so DSC signatures show as signed by a trusted issuer |
| A few lines in `/etc/apparmor.d/local/usr.bin.papers` (and `usr.bin.evince`) let the viewer read the USB device list and open USB device files | Ubuntu's AppArmor profile blocks it; the mToken driver then fails to start libusb and **crashes Document Viewer whenever a signed PDF is opened**. Only AppArmor's extra limit is lifted: normal file permissions still decide which USB devices the viewer can open (the suite's udev rule grants the token). Leave it out with `--no-pdf` |
| `~/.local/share/dsc-pdfsign` (pyHanko in a Python venv), `~/.local/bin/sign-pdf`, an app entry and a Files script | `sign-pdf` |

A `.run` bundle carries pyHanko as wheels for the packing machine's Python, so the install
works offline on the same Ubuntu release; on another Python it downloads pyHanko from PyPI.

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
| **DSCSN05** after the certificate is found: on Linux the signer reads the DSC's chain only from the token and silently drops a DSC whose chain has two certificates or fewer (Windows fills the chain from its certificate store) | a small agent (`-javaagent`, source in `extras/chain-fill/`) fills in the CA certificates. See [DSCSN05](#dscsn05-the-certificate-chain) |

### DSCSN05: the certificate chain

eOffice answers DSCSN05 when the signer sends no certificate for the DSC registered on the
server. NIC's 4.1.8 code (`in.gov.nic.dsc.util.c`, getAllCertificates) drops a DSC without a
message when `getCertificateChain()` returns two certificates or fewer. On Windows that chain
comes from the Windows certificate store. On Linux it comes from the token alone, and many
tokens hold only the DSC itself, or the DSC and its Sub-CA.

The suite's chain agent offers the `PKCS11` key store type ahead of SunPKCS11 and passes every
call through to it. The only change is in `getCertificateChain()`: a chain with two certificates
or fewer is completed from these sources, in order:

1. CA certificates stored on the token.
2. The CA files in `~/.local/share/railway-dsc/ca/`. The suite ships the CCA India 2022 and
   2022 SPL roots from cca.gov.in and the eMudhra 2022 CAs; you can add your own `.cer`, `.crt`
   or `.pem` files there.
3. The issuer named in the certificate's own "CA Issuers" (AIA) address, downloaded over the
   internet and kept in `ca/fetched/`. This covers every Indian licensed CA (eMudhra, Capricorn,
   ProDigiSign, (n)Code, Vsign, …) without bundling each one.

A CA certificate is added only if its signature over the certificate below it verifies. The
completed chain is used only if it ends at a pinned CCA India root (SHA-256 fingerprints in
`ChainFillAgent.java`). A forged "CCA India 2022" root is refused. A chain the token already
completes is returned unchanged. Nothing is switched off: validity, revocation and the DSC
registration are still checked by the eOffice server. The token is only read and never written,
and NIC's jar is not changed. To turn the agent off, set `DSC_CHAIN_FILL=no` in `suite.conf`.

`railway-dsc doctor` shows how many certificates the token holds (public objects only, no PIN)
and the serial number of each signing DSC. It also shows the agent's last result from the
signer log. If DSCSN05 remains after the chain has been completed, the DSC on the token is not
the one registered in eOffice, and it has to be registered again there.

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
- **The eOffice 4.1.8 PIN window** runs on Java 8, which cannot scale Swing on Linux.
  A small agent of the suite (`-javaagent`, source in `extras/swing-scale/`) enlarges
  its windows as they open: fonts, fixed-position fields and window size. NIC's jar is
  not changed. The size follows the desktop by default; choose your own with
  `railway-dsc install --pin-scale=1.5` (150%), or `DSC_EOFFICE_SCALE` in suite.conf.

## Self-healing

- Every service restarts within 5 seconds if it exits or is killed.
- A watchdog runs every 3 minutes. It asks each port for a real answer (HTTPS
  `isLive` with the right Host header, or a WebSocket handshake) and restarts a
  service after two failed checks.
- It also checks that each signer can still open its PIN window. A signer that
  started while the login was still settling can keep a display that later
  disappears. It still answers on its port, but every signing fails ("Could not
  initialize class sun.awt.X11GraphicsEnvironment" in its log), and Java cannot
  recover from that by itself. The watchdog does a real X handshake with the
  signer's own `DISPLAY`/`XAUTHORITY`, looks for that Java error in the signer's
  log for its current run, and restarts the signer when either check fails and
  the desktop display works. The launcher also only starts a signer on a display
  that passes the same handshake.
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
| "Either Response size is heavy or it is a Browser compatibility issue" | the signer answered with an HTTP error: often a 401 Host mismatch, or a PIN window that cannot open because the signer lost its display (doctor: "cannot open its PIN window"; fixed by `railway-dsc restart`, and by the watchdog within 3 minutes). Run `railway-dsc doctor` |
| "DSCSN05" | no usable DSC from the token: usually the token lacks the CA certificates (completed by the suite's chain agent), otherwise the DSC is not the one registered in eOffice. See [DSCSN05](#dscsn05-the-certificate-chain) and `railway-dsc doctor` |
| "Mismatch in DSC version" | the portal expects another signer version (e.g. 7.x); check the portal's `dscVersion` |
| "Please check the signer service: [object Event]" (CRIS/IREPS) | the browser refused the local certificate. Run `railway-dsc trust`; in Firefox also open `https://127.0.0.1:2039` once and accept |
| Document Viewer closes as soon as a signed PDF is opened | AppArmor blocks the token driver. Run `railway-dsc install` (or see `railway-dsc doctor`, section *PDF signing*) |

Don't click **Register DSC** repeatedly while debugging: each click deactivates the
currently active registration.

## Linux patch kit for CRIS and IREPS

eMudhra ships CrisSigner and IREPSSigner only as Windows installers. The Java programs
inside them need a few changes to run on Linux. `kit/` holds **only those changed
parts** (about 1.4 MB) and a recipe:

| Part | What changed |
|---|---|
| main program (`*_app.jar`, from the installer's `.exe`) | 6 classes of the bundled Java-WebSocket server (TLS handshake errors no longer kill the server); a stand-in for the Windows look-and-feel |
| `docsigner4.4_Cris.jar`, `pdfwebsigner4.5_CRIS.jar` | PKCS#11/token handling for Linux tokens (e.g. Longmai mToken), PIN prompts that stop before a token lockout, token-details actions, response logging clipped to 120 characters |
| `sunmscapi.jar` (CRIS-only installs) | replaced by a 1-class stub (`kit/stubs/src`). The vendor copy is an Oracle JRE part, used only on Windows code paths |

`kit/kittool.py apply` rebuilds the Linux folder from **your** installer and checks
every entry of every jar against SHA-256 values recorded from a working installation.
A different installer version is refused. The kit contains no vendor file that is
unchanged, and no key or certificate: those come from your own installer.

Review before publishing (2026-11-15): no new network destinations, no new shell
commands (only a Windows registry query, which does nothing on Linux), and the PIN is
held in memory only. This was a targeted review of the changed classes, not a full
audit.

Maintainers rebuild the kit on a working machine with
`python3 -I kit/kittool.py build --app cris|ireps --msi … [--aux-msi …] --linux-dir … --out kit/<app>`.

## What is and is not in this repository

The scripts, the patch kit (changed classes only), and two small stubs written for this
project are here. The signer programs, Java runtimes, TLS keys and token drivers are
vendor software and are **not** included. The suite takes them from the official
installers, from a `.run` bundle you build yourself, or from an existing installation.

## Test status (2026-11-15, Ubuntu 26.04)

- Fresh-PC test: in a throwaway home with only the vendor installers in `~/Downloads`,
  install set up eOffice 4.1.8 and 7.0.6, CrisSigner and IREPSSigner. The rebuilt CRIS
  and IREPS were content-identical to the working copies, and started and answered on
  ports 2039/2175 (including the CRIS-only variant with Maven libraries and the stub).
  Signing through the rebuilt CRIS/IREPS has not been tried yet.

- eOffice 4.1.8 set up this way signed and forwarded a file on a railway eOffice portal.
- Tested in a throwaway home directory:
  - install from the MSI;
  - `pack` and installing from the `.run`;
  - Java runtimes from the payload;
  - the Temurin download lookup;
  - the generated launcher on a spare port (loopback-only binding, probe, CA-verified HTTPS);
  - `doctor` against the live services.
- PDF signing (4.6.0): Document Viewer stopped crashing on signed PDFs once the AppArmor
  lines were added; `sign-pdf` and the bundle's offline pyHanko install were tested with a
  throwaway certificate in a throwaway home. Signing with a real token and PIN, through
  `sign-pdf` or Document Viewer, has not been tried yet.
- Display check (4.6.1): the X handshake probe accepted the session display and rejected
  a vanished display (`:1024`), a missing cookie and a missing auth file; the watchdog
  (dry run) chose to restart a signer on `:1024` and did nothing when no desktop display
  worked; the launcher picked the session display over an inherited stale one. Found
  when eOffice signing failed with the message above after a re-login on 2026-11-15.
- Token drivers (4.7.0): the eMudhra and Hypersecu downloads were unpacked and checked by
  checksum in a throwaway home, and a second run changed nothing. On this laptop the sudo
  phase installed the drivers and added the InnaIT ids to the CCID list, with a consistent
  backup. The ProxKey driver finds its libraries through the compatibility links. None of
  the new drivers has been tried with a real token.
- DSCSN05 chain agent (4.7.0): it completed eMudhra chains offline and by downloading from
  the CA's own address; it refused a forged "CCA India 2022" root; a wrong PIN still gives
  NIC's "load failed"; the token's key still signs through the wrapper; the real 4.1.8
  signer starts and runs with it. Not yet tried with a token that holds a short chain.
- Not yet tested: the sudo phase on non-Ubuntu distributions, and the non-systemd
  supervisor running real services.
