# Installing the Railway DSC Signer Suite on any Linux

This sets up the eOffice signer (NIC 4.1.8), CrisSigner and IREPSSigner, your DSC token's
driver and PDF signing, and keeps them running. Current version: **4.9.0**.

- Run every command as **your normal desktop user**, not as root. The installer asks for your
  `sudo` password itself when it needs it.
- Requires a **64-bit Intel/AMD PC (x86_64)** with a graphical desktop. The token's PIN window
  is a desktop window.
- Plug in your DSC token before you start.

There are two ways to install:

| | A. Ready-made bundle (recommended) | B. From the public repository |
|---|---|---|
| Link | <https://github.com/rajmrec2002/railway-dsc-suite-private/releases/tag/v4.9.0> | <https://github.com/rajmrec2002/railway-dsc-suite> |
| What you get | One file, `railway-dsc-suite-4.9.0.run` (334 MB), with everything inside: signers, Java, token drivers | The script and the Linux patch kit; you supply the vendors' installers |
| Access | Private: ask the maintainer to add your GitHub account | Open to everyone |

---

## Step 1: install the basic tools for your distribution

Copy the one line for your distribution into a terminal:

| Distribution | Command |
|---|---|
| Ubuntu, Debian, Linux Mint, Pop!_OS, elementary, Zorin | `sudo apt update && sudo apt install -y bash curl python3 sudo tar git` |
| Fedora, RHEL, Rocky, AlmaLinux, CentOS Stream | `sudo dnf install -y bash curl python3 sudo tar git` |
| openSUSE Leap / Tumbleweed | `sudo zypper --non-interactive install bash curl python3 sudo tar git` |
| Arch, Manjaro, EndeavourOS | `sudo pacman -S --needed --noconfirm bash curl python sudo tar git` |
| Alpine | `su -c 'apk add bash curl python3 sudo tar git'` |
| Void | `sudo xbps-install -Sy bash curl python3 sudo tar git` |

The installer adds everything else itself through the same package manager: Java, the
smart-card service (pcscd, CCID, OpenSC), NSS tools, cabextract and a PDF viewer.

---

## Step 2A: install from the ready-made bundle

**Download.** Open the
[v4.9.0 release page](https://github.com/rajmrec2002/railway-dsc-suite-private/releases/tag/v4.9.0)
while signed in to GitHub. Download `railway-dsc-suite-4.9.0.run` and
`railway-dsc-suite-4.9.0.run.sha256` into `~/Downloads`.

If you use the GitHub command-line tool (`gh auth login` done once), this does the same:

```bash
cd ~/Downloads
gh release download v4.9.0 -R rajmrec2002/railway-dsc-suite-private
```

**Check and install:**

```bash
cd ~/Downloads
sha256sum -c railway-dsc-suite-4.9.0.run.sha256      # must print: railway-dsc-suite-4.9.0.run: OK
bash railway-dsc-suite-4.9.0.run install --eoffice=4
```

The expected SHA-256 is
`c1d27feba25442f5cc38708012eb4f27432d05382e27441f282624a474f6886d`. If the check does not
print `OK`, download the file again. Do not run it.

The bundle contains vendor programs and keys. **Do not upload it or share it publicly.**

---

## Step 2B: install from the public repository

1. Get the script and the patch kit:

   ```bash
   cd ~
   git clone https://github.com/rajmrec2002/railway-dsc-suite.git
   ```

   Without git:

   ```bash
   cd ~
   curl -L https://github.com/rajmrec2002/railway-dsc-suite/archive/refs/heads/main.tar.gz | tar xz
   mv railway-dsc-suite-main railway-dsc-suite
   ```

2. Put the vendors' own installers in `~/Downloads`. They are recognised by checksum, whatever
   their file names:

   | Signer | File |
   |---|---|
   | eOffice 4.1.8 | `Digital Signer Service 4.1.8_x64.msi` (NIC) |
   | eOffice 7.0.6 (optional; carries the renewed HTTPS certificate) | `DigitalSignerService_7.0.6_Ubuntu_Installer.zip` (NIC) |
   | CrisSigner | `CrisSigner.msi` |
   | IREPSSigner | `IREPSSigner.msi` of 04-11-2026 (31.6 MB) |
   | Token driver, if your token is not a Longmai mToken | `ePass2003_Linux.zip`, `ProxKey_Linux.zip` or `InnaITDSC_Setup.zip` from the [eMudhra repository](https://www.e-mudhra.com/Repository/); Hypersecu: `HYP2003-Linux-x86_64-FIPS140-3.zip` from [hypersecu.com/india-support](https://www.hypersecu.com/india-support) |

3. Install:

   ```bash
   bash ~/railway-dsc-suite/railway-dsc-suite.sh install --eoffice=4
   ```

---

## Step 3: check and use

```bash
railway-dsc doctor      # explains every problem it finds and how to fix it
railway-dsc status      # short health summary
```

Then **restart your browser** and log out of eOffice, CRIS and IREPS and back in. When you
sign, the signer's PIN window opens. It may be behind the browser window.

To sign a PDF outside the portals:

```bash
sign-pdf letter.pdf
```

You can also right-click the file in the file manager and choose **Scripts → Sign PDF with DSC**.

## Useful options

| Option | Meaning |
|---|---|
| `--eoffice=4` / `7` / `both` | Which eOffice signer to install: 4.1.8 (railway portals), 7.0.6, or both |
| `--driver=FILE` | Use a token driver download that is not in `~/Downloads` |
| `--pin-scale=1.5` | Make the eOffice PIN window 150% larger (HiDPI screens) |
| `--no-pdf` | Leave out PDF signing |
| `--no-root` | Skip everything that needs `sudo` (some tokens then will not work) |

Run `install` again at any time, for example after a system upgrade or when you change to
a token of another make. It repairs whatever is broken and leaves the rest alone. Newly
plugged smart-card tokens are added to the system's reader list automatically. That needs
the `sudo` step to have run once.

## Upgrading

Download the newer bundle and run the same `install` command. Do not add `--no-root`. Your
settings, such as the eOffice choice and the PIN window size, are kept.

## Removing

```bash
railway-dsc uninstall            # stops and removes the services, keeps the program files
railway-dsc uninstall --purge    # also removes the program files
```

## Distribution notes

| Distribution | Status |
|---|---|
| Ubuntu 26.04 | Tested daily: eOffice, IRWCMS (CRIS) and PDF signing with a real mToken |
| Debian, Mint, Pop!_OS and other Ubuntu relatives | Same packages as Ubuntu; expected to work, not tested |
| Fedora / RHEL family | Package names are mapped; not tested. SELinux has not been checked: if a signer cannot reach the token, run `railway-dsc doctor` and report the output |
| openSUSE, Arch, Void | Package names are mapped; not tested |
| Alpine, Void with runit (no systemd) | Services run under a supervisor started from desktop autostart, not systemd. Not tested with real services |
| Non-x86_64 (ARM) | The bundled Java and token drivers are x86_64 only; needs your own Java and an ARM token driver |

If anything fails, send the output of `railway-dsc doctor` and `railway-dsc logs`.
