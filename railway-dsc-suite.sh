#!/usr/bin/env bash
# ==============================================================================
#  Railway DSC Signer Suite 4 - install, repair and keep alive the three
#  Indian Railways digital-signature (DSC) signer services on Linux.
#
#    eOffice  NIC DSC Signer Service 4.1.8   https://eoffsigner.eoffice.gov.in:55101
#    CRIS     CrisSigner                     wss://127.0.0.1:2039
#    IREPS    IREPSSigner                    wss://127.0.0.1:2175
#
#  Written for Ubuntu (tested on 26.04); works on Debian/Mint/Pop, Fedora/RHEL,
#  openSUSE, Arch, Alpine and Void with the same commands.
#
#  Where the program files come from (first match wins, per component)
#    1. a payload attached to this script      (railway-dsc-suite-<date>.run, see "pack")
#    2. the official Windows installer of the eOffice signer
#       ("Digital Signer Service 4.1.8_x64.msi" - pass --msi=FILE or keep it in ~/Downloads);
#       the jar inside it is plain Java and runs unchanged on Linux
#    3. what is already installed on this machine (install = repair)
#
#  Why 4.1.8 and not 7.x for eOffice: eOffice portals still configured for signer
#  "4.1" (port 55101, /signing/textSigning ...) reject 7.x; 4.1.8 speaks that protocol.
#  The Linux-specific fixes this script applies (all without modifying NIC's jar):
#    - Java 8 runtime (4.1.8 uses the Java-8-only SunPKCS11(String) API)
#    - "pkcs11cfg" in the working directory pointing at the token's PKCS#11 driver
#    - NIC's renewed HTTPS certificate (the one inside 4.1.8 expired 21-06-2026)
#    - -Djavax.accessibility.assistive_technologies= (Ubuntu's Java 8 otherwise
#      crashes every Swing window, including NIC's PIN prompt)
#    - /etc/hosts: eoffsigner.eoffice.gov.in -> loopback (the signer rejects any
#      other Host header with 401 "Invalid Request.")
#
#  Commands: install|repair | doctor | status | heal | start|stop|restart | logs |
#            trust | pack | uninstall | help
#
#  PDF signing (4.6): installs GNOME Document Viewer (Papers), lets it reach the token
#  (AppArmor + NSS), trusts the CCA India root for signatures, and adds "sign-pdf" plus a
#  "Sign PDF with DSC" app / Files right-click entry.
# ==============================================================================
set -u
set -o pipefail

SUITE_VERSION="4.6.0"
MARKER="__PAYLOAD_BELOW__"
SELF="$(readlink -f "${BASH_SOURCE[0]}")"

# ------------------------------------------------------------------ layout ---
HOSTS_NAME="eoffsigner.eoffice.gov.in"
HOSTS_ADDR="127.0.5.1"                 # used only when /etc/hosts has no entry yet
EOFFICE_VER="4.1.8"
EOFFICE_JAR_NAME="DigitalSignerService4.1.8.jar"
EOFFICE_JAR_SHA="a20f56ac01ff2ea5c548c94f05eb5e11900e9f34d31de2a999337e613251a300"
EOFFICE_PORT=55101
# SHA-256 of NIC's private "eOfficeCA2022" root (same in the 4.1.8 MSI's Pre-Requisites/eOfficeCA2022.cer
# and in every 7.0.x package). Only a keystore whose chain ends in exactly this CA is accepted,
# because that CA gets added to the browsers' trust stores.
EOFFICE_CA_SHA256="28:D3:F3:52:E1:76:05:16:5C:BD:C2:75:EB:4C:63:B2:55:FF:63:88:AC:5A:A2:CE:1A:84:A0:97:D4:A3:E1:40"
# eOffice signer 7.0.6 (optional; for portals configured for the 7.x signer)
E7_VER="7.0.6"
E7_JAR_NAME="DigitalSignerService-7.0.6.jar"
E7_JAR_SHA="a075dac39184e419135adf144a8956b47e158c92d900acb25434ad686be3d5f6"
E7_JRE_ZIP_SHA="5dfa0e408f0e0ef76f8805d731a9f04dbf865ecf83d9fa4c174615b30345f501"
E7_PORT=55103
LEGACY_706_DIR="/usr/local/DigitalSignerService-7.0.6"
VENDOR_HOOK="/etc/profile.d/DSC706-start.sh"
MTOKEN_LIB="/usr/lib/libcryptoid_pkcs11.so"
UDEV_RULE="/etc/udev/rules.d/90-dsc-tokens.rules"
LEGACY_UNITS="eofficesigner eofficesigner-proxy"     # 7.0.6 signer and the old v4 bridge
# PDF signing: the Indian root CA (public; https://cca.gov.in), pinned; pyHanko versions tested
CCA_ROOT_SHA256="9A:3F:D3:17:67:98:E8:42:DD:CB:12:C2:62:F1:1C:FA:CC:A7:0A:8B:84:C6:EA:6F:DA:30:84:2A:95:A9:4C:D8"
PYHANKO_REQ="pyhanko[pkcs11]==0.38.1"
AA_BEGIN="# --- railway-dsc: DSC USB token for digital signing (begin) ---"
AA_END="# --- railway-dsc: DSC USB token for digital signing (end) ---"
AA_VIEWERS="usr.bin.papers usr.bin.evince"          # AppArmor profiles of PDF viewers that sign through NSS

set_user_paths() {            # $1 = home directory
    U_HOME="$1"
    EOFFICE_DIR="$U_HOME/DigitalSignerService-$EOFFICE_VER"
    EOFFICE_JAR="$EOFFICE_DIR/$EOFFICE_JAR_NAME"
    EOFFICE_JKS="$EOFFICE_DIR/dscSSL.jks"
    EOFFICE_P11CFG="$EOFFICE_DIR/pkcs11cfg"
    EOFFICE_CA="$EOFFICE_DIR/eOfficeCA2022.pem"
    EOFFICE_LOGS="$EOFFICE_DIR/logs"
    EOFFICE_APPLOGS="$U_HOME/DscSignerAppLogs"     # written by the signer itself
    E7_DIR="$U_HOME/DigitalSignerService-7.0.6"          # 7.0.6 reads conf/ from here
    E7_JAR="$E7_DIR/$E7_JAR_NAME"
    E7_LOGS="$U_HOME/DigitalSignerService-7.0.6-Logs"
    CRIS_DIR="$U_HOME/CrisSigner_Linux"
    IREPS_DIR="$U_HOME/IREPSSigner_Linux"
    CONF_DIR="$U_HOME/.config/railway-dsc"
    CONF_FILE="$CONF_DIR/suite.conf"
    SHARE_DIR="$U_HOME/.local/share/railway-dsc"
    JRE8_DIR="$SHARE_DIR/jre8"
    JRE17_DIR="$SHARE_DIR/jre17"
    KEEP_DIR="$SHARE_DIR/keep"
    STATE_DIR="$SHARE_DIR/state"
    MANIFEST="$SHARE_DIR/manifest.sha256"
    LAUNCH="$SHARE_DIR/launch.sh"
    LAF_JAR="$SHARE_DIR/laf-gtk.jar"
    SCALE_JAR="$SHARE_DIR/swing-scale.jar"
    KIT_COPY="$SHARE_DIR/kit"
    PROBE="$SHARE_DIR/probe.py"
    HEAL_LOG="$SHARE_DIR/heal.log"
    BIN="$U_HOME/.local/bin/railway-dsc"
    UNIT_DIR="$U_HOME/.config/systemd/user"
    AUTOSTART="$U_HOME/.config/autostart/railway-dsc-supervisor.desktop"
    PDF_VENV="$U_HOME/.local/share/dsc-pdfsign"
    PDF_PY="$PDF_VENV/sign_pdf.py"
    PDF_BIN="$U_HOME/.local/bin/sign-pdf"
    PDF_DESKTOP="$U_HOME/.local/share/applications/sign-pdf-dsc.desktop"
    PDF_NAUTILUS="$U_HOME/.local/share/nautilus/scripts/Sign PDF with DSC"
    NSSDB="$U_HOME/.pki/nssdb"
}
set_user_paths "$HOME"

# service table
ALL_SVCS="eoffice eoffice7 cris ireps"
svc_unit()  { case "$1" in eoffice) echo eofficesigner418;; eoffice7) echo eofficesigner706;; cris) echo crissigner;; ireps) echo irepssigner;; esac; }
svc_kind()  { case "$1" in eoffice|eoffice7) echo http;; *) echo ws;; esac; }
svc_port()  { case "$1" in eoffice) echo $EOFFICE_PORT;; eoffice7) echo $E7_PORT;; cris) echo 2039;; ireps) echo 2175;; esac; }
svc_label() { case "$1" in eoffice) echo "eOffice signer (NIC $EOFFICE_VER)";; eoffice7) echo "eOffice signer (NIC $E7_VER)";; cris) echo "CrisSigner";; ireps) echo "IREPSSigner";; esac; }
svc_files_ok() {
    case "$1" in
        eoffice) [ -f "$EOFFICE_JAR" ] && [ -f "$EOFFICE_JKS" ];;
        eoffice7) [ -f "$E7_JAR" ];;
        cris)    [ -f "$CRIS_DIR/crissigner_app.jar" ];;
        ireps)   [ -f "$IREPS_DIR/irepssigner_app.jar" ];;
    esac
}
# Which eOffice signer(s) to run: DSC_EOFFICE=4 | 7 | both  (suite.conf, or install --eoffice=)
eoffice_choice() {
    case "${DSC_EOFFICE:-4}" in 7|7.*|v7) echo 7;; both|all|"4 7"|4,7|47) echo "4 7";; *) echo 4;; esac
}
eoffice_desc() {              # human-readable choice, e.g. "4.1.8 (port 55101) + 7.0.6 (port 55103)"
    local v o=""
    for v in $(eoffice_choice); do
        case "$v" in 4) o="$o + $EOFFICE_VER (port $EOFFICE_PORT)";; 7) o="$o + $E7_VER (port $E7_PORT)";; esac
    done
    echo "${o# + }"
}
svc_wanted() {
    case "$1" in
        eoffice)  case " $(eoffice_choice) " in *" 4 "*) return 0;; *) return 1;; esac;;
        eoffice7) case " $(eoffice_choice) " in *" 7 "*) return 0;; *) return 1;; esac;;
        *) return 0;;
    esac
}
present_svcs() { local s o=""; for s in $ALL_SVCS; do svc_files_ok "$s" && svc_wanted "$s" && o="$o $s"; done; echo "${o# }"; }
# shellcheck disable=SC1090
[ -f "$CONF_FILE" ] && . "$CONF_FILE"
SVCS="$(present_svcs)"

# ----------------------------------------------------------------- helpers ---
if [ -t 1 ]; then G=$'\033[0;32m'; R=$'\033[0;31m'; Y=$'\033[1;33m'; B=$'\033[1m'; N=$'\033[0m'; else G=""; R=""; Y=""; B=""; N=""; fi
info() { echo "    $*"; }
ok()   { echo "${G}[ ok ]${N} $*"; }
warn() { echo "${Y}[warn]${N} $*"; }
fail() { echo "${R}[FAIL]${N} $*"; }
step() { echo; echo "${B}==> $*${N}"; }
die()  { fail "$*"; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }
hlog() { mkdir -p "$SHARE_DIR"; echo "$(date '+%F %T') $*" >> "$HEAL_LOG"; }
sha()  { sha256sum "$1" 2>/dev/null | cut -d' ' -f1; }
have_systemd_user() { [ "${RDSC_NO_SYSTEMD:-}" != 1 ] && have systemctl && systemctl --user show-environment >/dev/null 2>&1; }

hook_active() { [ -f "$VENDOR_HOOK" ] && grep -Eq '^[^#]*DigitalSignerService' "$VENDOR_HOOK" 2>/dev/null; }
udev_rule_present() { [ -f "$UDEV_RULE" ] || grep -rqsiE 'idVendor.{0,6}(055c|096e|163c|0529)' /etc/udev/rules.d/ 2>/dev/null; }
hosts_addr()  { getent hosts "$HOSTS_NAME" 2>/dev/null | awk '{print $1; exit}'; }
hosts_ok()    { case "$(hosts_addr)" in 127.*) return 0;; *) return 1;; esac; }

# USB vendor IDs of common Indian DSC tokens
TOKEN_VIDS="055c:Longmai-mToken 096e:Feitian-ePass2003 163c:WatchData-ProxKey/TrustKey 0529:SafeNet-eToken 08e6:Gemalto 24dc:Aladdin-JaCarta 1a44:VASCO 04e6:SCM-reader 072f:ACS-reader"
tokens_plugged() {            # prints "vid:Name" for each plugged token
    local f vid t
    for f in /sys/bus/usb/devices/*/idVendor; do
        [ -f "$f" ] || continue; vid=$(cat "$f" 2>/dev/null)
        for t in $TOKEN_VIDS; do [ "${t%%:*}" = "$vid" ] && echo "$t"; done
    done | sort -u
}

P11_CANDIDATES="/usr/lib/libcryptoid_pkcs11.so /usr/lib/libcastle.so.1.0.0 /usr/lib/libcastle.so
 /usr/lib/x86_64-linux-gnu/libcastle.so /usr/lib64/libcastle.so
 /usr/lib/WatchData/ProxKey/lib/libwdpkcs_SignatureP11.so /usr/lib/WatchData/TRUSTKEY/lib/libwdpkcs_TRUSTKEY.so
 /usr/lib/WatchData/eMudhra_3.4.3/lib/libwdpkcs_eMudhra_343.so /usr/lib/WatchData/PROXKey/lib/libwdpkcs.so
 /usr/lib/libwdpkcs.so /usr/lib/libmTokenPKCS11.so /usr/lib/libaetpkss.so.2.3.1 /usr/lib/libaetpkss.so
 /usr/lib/libeTPkcs11.so /usr/lib/libeToken.so /usr/lib/pkcs11/libgtop11dotnet.so /usr/lib/libgtop11dotnet.so
 /usr/lib/x86_64-linux-gnu/opensc-pkcs11.so /usr/lib64/opensc-pkcs11.so /usr/lib64/pkcs11/opensc-pkcs11.so
 /usr/lib/opensc-pkcs11.so /usr/lib/pkcs11/opensc-pkcs11.so"
OPENSC_LIBS="/usr/lib/x86_64-linux-gnu/opensc-pkcs11.so /usr/lib64/opensc-pkcs11.so /usr/lib64/pkcs11/opensc-pkcs11.so
 /usr/lib/opensc-pkcs11.so /usr/lib/pkcs11/opensc-pkcs11.so /usr/lib/aarch64-linux-gnu/opensc-pkcs11.so"
EPASS_ZIP_SHA="6d69729a4ca1354b2a9929a9cb18b7bcebb54dfdc06f2b85d95d1f3053d01654"   # Feitian/EnterSafe ePass2003-Linux-x64.zip
CASTLE_LIB="/usr/lib/libcastle.so.1.0.0"
plugged_vids() { cat /sys/bus/usb/devices/*/idVendor 2>/dev/null | sort -u; }
p11_for_vid() {               # USB vendor id of the plugged token -> its drivers, best first
    case "$1" in
        055c) echo "/usr/lib/libcryptoid_pkcs11.so /usr/lib/libmTokenPKCS11.so";;
        096e) echo "/usr/lib/libcastle.so.1.0.0 /usr/lib/libcastle.so /usr/lib/x86_64-linux-gnu/libcastle.so /usr/lib64/libcastle.so $OPENSC_LIBS";;
        163c) echo "/usr/lib/WatchData/ProxKey/lib/libwdpkcs_SignatureP11.so /usr/lib/WatchData/TRUSTKEY/lib/libwdpkcs_TRUSTKEY.so /usr/lib/WatchData/eMudhra_3.4.3/lib/libwdpkcs_eMudhra_343.so /usr/lib/WatchData/PROXKey/lib/libwdpkcs.so /usr/lib/libwdpkcs.so";;
        0529) echo "/usr/lib/libeTPkcs11.so /usr/lib/libeToken.so";;
        08e6) echo "/usr/lib/pkcs11/libgtop11dotnet.so /usr/lib/libgtop11dotnet.so $OPENSC_LIBS";;
        24dc) echo "/usr/lib/libjcPKCS11-2.so /usr/lib/x86_64-linux-gnu/libjcPKCS11-2.so";;
        04e6|072f) echo "$OPENSC_LIBS";;                      # smart-card readers
    esac
}
find_p11_lib() {              # P11_LIB (suite.conf) > driver matching the plugged token > first one found
    local l v known=0 c
    for l in ${P11_LIB:-}; do [ -f "$l" ] && { echo "$l"; return 0; }; done
    for v in $(plugged_vids); do
        c=$(p11_for_vid "$v"); [ -n "$c" ] && known=1
        for l in $c; do [ -f "$l" ] && { echo "$l"; return 0; }; done
    done
    [ $known = 1 ] && return 1        # a known token is plugged but its driver is missing: never guess another's
    for l in $P11_CANDIDATES; do [ -f "$l" ] && { echo "$l"; return 0; }; done
    return 1
}

# ------------------------------------------------------------------- java ---
java_major() { "$1" -version 2>&1 | awk -F'"' '/version/{split($2,v,"."); print (v[1]=="1")?v[2]:v[1]; exit}'; }
java_has_gui() { local r; r="$(dirname "$(dirname "$(readlink -f "$1")")")"; [ -n "$(find "$r" -name 'libawt_xawt.so' -print -quit 2>/dev/null)" ]; }
find_java8() {                # a Java 8 runtime WITH the GUI libraries (the PIN prompt is Swing)
    local j
    for j in ${JAVA8:-} "$JRE8_DIR/bin/java" /usr/lib/jvm/java-8-openjdk-*/jre/bin/java \
             /usr/lib/jvm/java-1.8.0-openjdk*/jre/bin/java /usr/lib/jvm/jre-1.8.0*/bin/java \
             /usr/lib/jvm/java-8-*/jre/bin/java /usr/lib/jvm/temurin-8-*/bin/java /usr/lib/jvm/zulu8*/jre/bin/java \
             /usr/java/jre1.8*/bin/java /usr/java/jdk1.8*/jre/bin/java /opt/jre1.8*/bin/java "$U_HOME"/java/jre1.8*/bin/java; do
        [ -x "$j" ] || continue
        [ "$(java_major "$j" 2>/dev/null)" = 8 ] && java_has_gui "$j" && { echo "$j"; return 0; }
    done
    return 1
}
find_java_modern() {          # Java 11+ for CrisSigner/IREPSSigner (17 preferred)
    local j m
    for j in ${JAVA17:-} "$JRE17_DIR/bin/java" "$LEGACY_706_DIR/jre/bin/java" /usr/lib/jvm/java-17*/bin/java \
             /usr/lib/jvm/jre-17*/bin/java /usr/lib/jvm/temurin-17*/bin/java /usr/lib/jvm/java-21*/bin/java \
             /usr/lib/jvm/java-1[1-9]*/bin/java /usr/lib/jvm/java-2[0-9]*/bin/java "$(command -v java 2>/dev/null)"; do
        [ -n "$j" ] && [ -x "$j" ] || continue
        m=$(java_major "$j" 2>/dev/null); [ -n "$m" ] && [ "$m" -ge 11 ] 2>/dev/null && java_has_gui "$j" && { echo "$j"; return 0; }
    done
    return 1
}
keytool_bin() {
    local j d
    for j in "$(find_java8 2>/dev/null)" "$(find_java_modern 2>/dev/null)"; do
        [ -n "$j" ] || continue; d=$(dirname "$(readlink -f "$j")"); [ -x "$d/keytool" ] && { echo "$d/keytool"; return 0; }
    done
    have keytool && { command -v keytool; return 0; }
    return 1
}
jks_expiry() {                # $1 = jks (alias 1, password eoffice) -> epoch of notAfter
    local kt end; kt=$(keytool_bin) || return 1
    end=$("$kt" -list -v -keystore "$1" -storepass eoffice -alias 1 2>/dev/null | sed -n 's/.*until: //p' | head -1)
    [ -n "$end" ] && date -d "$end" +%s 2>/dev/null
}
jks_valid() { local e; e=$(jks_expiry "$1") && [ -n "$e" ] && [ "$e" -gt "$(date +%s)" ]; }
jks_leaf_pem() {              # $1 = jks -> first certificate (the server's own) of alias 1 as PEM
    local kt; kt=$(keytool_bin) || return 1
    "$kt" -list -rfc -keystore "$1" -storepass eoffice -alias 1 2>/dev/null |
        awk '/BEGIN CERTIFICATE/{on=1} on{print} /END CERTIFICATE/{exit}'
}
jks_trusted() {               # $1 = jks: chain ends in the pinned NIC CA and the leaf is for $HOSTS_NAME
    have openssl || return 1
    local d; d="$(work_tmp)/verify.$$"; mkdir -p "$d"
    jks_ca_pem "$1" > "$d/ca.pem" && jks_leaf_pem "$1" > "$d/leaf.pem" || { rm -rf "$d"; return 1; }
    local fp; fp=$(openssl x509 -in "$d/ca.pem" -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2)
    if [ "$fp" = "$EOFFICE_CA_SHA256" ] &&
       openssl verify -CAfile "$d/ca.pem" "$d/leaf.pem" >/dev/null 2>&1 &&
       openssl x509 -in "$d/leaf.pem" -noout -ext subjectAltName 2>/dev/null | grep -q "DNS:$HOSTS_NAME"; then
        rm -rf "$d"; return 0
    fi
    rm -rf "$d"; return 1
}
jks_ca_pem() {                # $1 = jks -> prints the last (CA) certificate of alias 1's chain as PEM
    local kt; kt=$(keytool_bin) || return 1
    "$kt" -list -rfc -keystore "$1" -storepass eoffice -alias 1 2>/dev/null |
        awk '/BEGIN CERTIFICATE/{buf=""; on=1} on{buf=buf $0 "\n"} /END CERTIFICATE/{on=0; last=buf} END{printf "%s", last}'
}

# Download a Temurin JRE (used only when neither a package nor the payload provides one)
fetch_temurin() {             # $1 = 8|17   $2 = destination dir
    local ver="$1" dst="$2" arch tmp json link sum
    case "$(uname -m)" in x86_64) arch=x64;; aarch64) arch=aarch64;; armv7l) arch=arm;; *) return 1;; esac
    have curl && have python3 || return 1
    tmp=$(mktemp -d) || return 1
    json=$(curl -fsSL --max-time 60 "https://api.adoptium.net/v3/assets/latest/$ver/hotspot?architecture=$arch&image_type=jre&os=linux&vendor=eclipse") || { rm -rf "$tmp"; return 1; }
    read -r link sum < <(printf '%s' "$json" | python3 -c 'import json,sys; a=json.load(sys.stdin)[0]["binary"]["package"]; print(a["link"], a["checksum"])') || { rm -rf "$tmp"; return 1; }
    info "Downloading Temurin $ver JRE ..."
    curl -fsSL --max-time 900 -o "$tmp/jre.tgz" "$link" || { rm -rf "$tmp"; return 1; }
    [ "$(sha "$tmp/jre.tgz")" = "$sum" ] || { warn "Temurin download failed its checksum"; rm -rf "$tmp"; return 1; }
    mkdir -p "$tmp/x" && tar -xzf "$tmp/jre.tgz" -C "$tmp/x" --strip-components=1 || { rm -rf "$tmp"; return 1; }
    rm -rf "$dst"; mkdir -p "$(dirname "$dst")"; mv "$tmp/x" "$dst"; rm -rf "$tmp"
    [ -x "$dst/bin/java" ]
}

# ------------------------------------------------------- service back-ends ---
svc_active() {
    if have_systemd_user; then systemctl --user is-active --quiet "$(svc_unit "$1").service"
    else local p; p=$(cat "$STATE_DIR/pid.$1" 2>/dev/null) && [ -n "$p" ] && kill -0 "$p" 2>/dev/null; fi
}
svc_pid() {
    if have_systemd_user; then systemctl --user show "$(svc_unit "$1").service" -p MainPID --value 2>/dev/null
    else cat "$STATE_DIR/pid.$1" 2>/dev/null; fi
}
svc_restart() {
    if have_systemd_user; then systemctl --user restart "$(svc_unit "$1").service"
    else local p; p=$(cat "$STATE_DIR/pid.$1" 2>/dev/null); [ -n "$p" ] && kill "$p" 2>/dev/null; ensure_supervisor; fi
}
svc_stop() {
    if have_systemd_user; then systemctl --user stop "$(svc_unit "$1").service" 2>/dev/null
    else local p; p=$(cat "$STATE_DIR/pid.$1" 2>/dev/null); [ -n "$p" ] && kill "$p" 2>/dev/null; rm -f "$STATE_DIR/pid.$1"; fi
}
svc_age() { local p; p=$(svc_pid "$1"); [ -n "$p" ] && [ "$p" != 0 ] && ps -o etimes= -p "$p" 2>/dev/null | tr -d ' ' || echo 0; }
ensure_probe() { [ -f "$PROBE" ] || { PROBE="$(work_tmp)/probe.py"; [ -f "$PROBE" ] || write_probe; }; }
probe() {
    ensure_probe
    if [ "$(svc_kind "$1")" = http ]; then python3 "$PROBE" http "$(svc_port "$1")" "$(hosts_addr || true)" "$HOSTS_NAME" >/dev/null 2>&1
    else python3 "$PROBE" ws "$(svc_port "$1")" >/dev/null 2>&1; fi
}
port_owner() { ss -ltnpH "sport = :$1" 2>/dev/null | sed -n 's/.*users:((\("[^"]*",pid=[0-9]*\).*/\1/p' | head -1; }

ensure_supervisor() {         # non-systemd systems only
    have_systemd_user && return 0
    local p; p=$(cat "$STATE_DIR/supervisor.pid" 2>/dev/null)
    [ -n "$p" ] && kill -0 "$p" 2>/dev/null && return 0
    mkdir -p "$STATE_DIR"
    if have setsid; then setsid nohup "$BIN" supervise >/dev/null 2>&1 &
    else nohup "$BIN" supervise >/dev/null 2>&1 & fi
}

# ============================================================== generators ===
write_probe() {
    mkdir -p "$(dirname "$PROBE")"
    cat > "$PROBE" <<'PY'
#!/usr/bin/env python3
"""Functional health probe: exit 0 only if the signer really answers.
usage: probe.py http PORT [ADDR] [HOSTNAME]   |   probe.py ws PORT"""
import base64, os, socket, ssl, sys

def tls(addr, port, sni):
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    raw = socket.create_connection((addr, port), timeout=8)
    raw.settimeout(8)
    return ctx.wrap_socket(raw, server_hostname=sni)

def read_until(sock, token, limit=65536):
    data = b""
    while token not in data and len(data) < limit:
        chunk = sock.recv(4096)
        if not chunk:
            break
        data += chunk
    return data

def http(port, addr, host):
    # The NIC signer answers 401 to any Host header other than its own name.
    s = tls(addr, port, host)
    try:
        s.sendall(b"GET /check/isLive HTTP/1.0\r\nHost: %s:%d\r\n"
                  b"Origin: https://localhost\r\nConnection: close\r\n\r\n" % (host.encode(), port))
        data = read_until(s, b"version")
        return b" 200" in data.split(b"\r\n", 1)[0] and b"success" in data
    finally:
        s.close()

def ws(port):
    s = tls("127.0.0.1", port, "127.0.0.1")
    try:
        key = base64.b64encode(os.urandom(16))
        s.sendall(b"GET / HTTP/1.1\r\nHost: 127.0.0.1:%d\r\nUpgrade: websocket\r\n"
                  b"Connection: Upgrade\r\nSec-WebSocket-Key: %s\r\n"
                  b"Sec-WebSocket-Version: 13\r\nOrigin: https://localhost\r\n\r\n" % (port, key))
        data = read_until(s, b"\r\n\r\n")
        good = b" 101" in data.split(b"\r\n", 1)[0]
        try:                       # polite WebSocket close so the server frees the session
            s.sendall(bytes([0x88, 0x80]) + os.urandom(4))
            s.settimeout(2)
            s.recv(256)
        except Exception:
            pass
        return good
    finally:
        try:
            s.close()
        except Exception:
            pass

if __name__ == "__main__":
    try:
        kind, port = sys.argv[1], int(sys.argv[2])
        if kind == "http":
            addr = sys.argv[3] if len(sys.argv) > 3 and sys.argv[3] else "127.0.0.1"
            host = sys.argv[4] if len(sys.argv) > 4 else "eoffsigner.eoffice.gov.in"
            good = http(port, addr, host)
        else:
            good = ws(port)
        sys.exit(0 if good else 1)
    except Exception as exc:
        sys.stderr.write("probe failed: %s\n" % exc)
        sys.exit(1)
PY
    chmod 755 "$PROBE"
}

# CrisSigner/IREPSSigner insist on the Windows look; this stand-in (source: extras/gtk-look/)
# is GTK underneath, so they follow the desktop theme and get native-size text on HiDPI.
LAF_JAR_SHA="9ddcd6c7cd8f4ee34bf841371e63c36c181f80575788d39152271572ef16b6bc"
LAF_JAR_B64="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"
write_laf_jar() {
    mkdir -p "$SHARE_DIR"
    printf '%s' "$LAF_JAR_B64" | base64 -d > "$LAF_JAR.tmp" && [ "$(sha "$LAF_JAR.tmp")" = "$LAF_JAR_SHA" ] &&
        mv -f "$LAF_JAR.tmp" "$LAF_JAR" || { rm -f "$LAF_JAR.tmp"; warn "could not write the GTK look jar"; }
}

# Java 8 cannot scale Swing on Linux; this agent (source: extras/swing-scale/) enlarges the
# eOffice 4.1.8 windows (PIN prompt, start message) when they open. NIC's jar is not changed.
SCALE_JAR_SHA="426f534487d2aeee811fb2eff807b6545e9788eca07f9a749d93f172dc4cf2ae"
SCALE_JAR_B64="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"
write_scale_jar() {
    mkdir -p "$SHARE_DIR"
    printf '%s' "$SCALE_JAR_B64" | base64 -d > "$SCALE_JAR.tmp" && [ "$(sha "$SCALE_JAR.tmp")" = "$SCALE_JAR_SHA" ] &&
        mv -f "$SCALE_JAR.tmp" "$SCALE_JAR" || { rm -f "$SCALE_JAR.tmp"; warn "could not write the window-scaling agent"; }
}

write_launcher() {
    mkdir -p "$SHARE_DIR"
    {
        echo '#!/usr/bin/env bash'
        echo "# Generated by railway-dsc-suite $SUITE_VERSION - do not edit; re-run \"railway-dsc install\"."
        echo '# usage: launch.sh eoffice|cris|ireps'
        local v
        for v in U_HOME LAF_JAR SCALE_JAR E7_DIR E7_JAR E7_LOGS EOFFICE_DIR EOFFICE_JAR EOFFICE_JKS EOFFICE_LOGS CRIS_DIR IREPS_DIR CONF_FILE \
                 JRE8_DIR JRE17_DIR LEGACY_706_DIR HOSTS_NAME P11_CANDIDATES OPENSC_LIBS MTOKEN_LIB; do
            printf '%s=%q\n' "$v" "${!v}"
        done
        declare -f java_major java_has_gui find_java8 find_java_modern find_p11_lib plugged_vids p11_for_vid
    } > "$LAUNCH"
    cat >> "$LAUNCH" <<'LAUNCH_EOF'
SVC="${1:-}"
DSC_UI_SCALE=auto; DSC_EOFFICE_SCALE=auto; DSC_LOOK=native; P11_LIB=""; JAVA8=""; JAVA17=""
[ -f "$CONF_FILE" ] && . "$CONF_FILE"

# --- Display: these are Swing apps and the PIN prompt needs an X display -------
if [ -z "${DISPLAY:-}" ] && command -v systemctl >/dev/null 2>&1; then
    DISPLAY=$(systemctl --user show-environment 2>/dev/null | sed -n 's/^DISPLAY=//p')
fi
if [ -z "${DISPLAY:-}" ]; then
    for s in /tmp/.X11-unix/X*; do [ -S "$s" ] && { DISPLAY=":${s##*/X}"; break; }; done
fi
[ -n "${DISPLAY:-}" ] || { echo "No X display yet - will retry."; exit 1; }
export DISPLAY
if [ -z "${XAUTHORITY:-}" ]; then
    XA=""
    command -v systemctl >/dev/null 2>&1 && XA=$(systemctl --user show-environment 2>/dev/null | sed -n 's/^XAUTHORITY=//p')
    if [ -z "$XA" ]; then
        for f in /run/user/$(id -u)/.mutter-Xwaylandauth.* /run/user/$(id -u)/xauth_* "$HOME/.Xauthority"; do
            [ -f "$f" ] && { XA="$f"; break; }
        done
    fi
    [ -n "$XA" ] && export XAUTHORITY="$XA"
fi
dnum="${DISPLAY#*:}"; dnum="${dnum%%.*}"
i=0
while [ ! -S "/tmp/.X11-unix/X$dnum" ] && [ $i -lt 30 ]; do sleep 2; i=$((i+1)); done
[ -S "/tmp/.X11-unix/X$dnum" ] || { echo "X display $DISPLAY not available - will retry."; exit 1; }

# Ubuntu's Java ships an accessibility.properties naming the GNOME ATK bridge; when that
# bridge is not installed every Swing window (incl. the PIN prompt) dies with AWTError.
NOATK="-Djavax.accessibility.assistive_technologies="
# --- Scale: follow the desktop. GNOME with native XWayland scaling (and plain X11 HiDPI)
# announces it through Xft.dpi (192 = 2x); when the compositor scales X apps itself it is 96.
detect_scale() {
    [ -n "${GDK_SCALE:-}" ] && { echo "$GDK_SCALE"; return; }
    local dpi="" g
    if command -v xrdb >/dev/null 2>&1; then
        dpi=$(xrdb -get Xft.dpi 2>/dev/null) || dpi=""
        [ -n "$dpi" ] || dpi=$(xrdb -query 2>/dev/null | awk '/^Xft.dpi:/{print $2; exit}')
    fi
    if [ -n "$dpi" ] && [ "${dpi%.*}" -gt 0 ] 2>/dev/null; then
        awk -v d="$dpi" 'BEGIN{s=d/96; if (s<1) s=1; printf "%g", int(s*4+0.5)/4}'; return
    fi
    g=$(gsettings get org.gnome.desktop.interface scaling-factor 2>/dev/null | awk '{print $NF}')
    [ -n "$g" ] && [ "$g" -gt 0 ] 2>/dev/null && { echo "$g"; return; }
    echo 1
}
case "$DSC_UI_SCALE" in ""|auto) DSC_UI_SCALE=$(detect_scale);; esac
UI=("-Dsun.java2d.uiScale.enabled=true" "-Dsun.java2d.uiScale=${DSC_UI_SCALE}")

BIND=$(getent hosts "$HOSTS_NAME" 2>/dev/null | awk '{print $1; exit}')
case "$BIND" in 127.*) ;; *) BIND=127.0.0.1;; esac          # eOffice signers never listen on the LAN

if [ "$SVC" = eoffice7 ]; then
    J=$(find_java_modern) || { echo "No Java 11+ runtime with GUI libraries found - run: railway-dsc install"; exit 1; }
    mkdir -p "$E7_DIR" "$E7_LOGS"
    cd "$E7_DIR" || exit 1                                   # conf/ (token list) is read from here
    if P11=$(find_p11_lib) && ! grep -qs "^1.path=$P11\$" conf/all_tokens.properties; then   # follow the plugged token
        mkdir -p conf; T=Token; [ "$P11" = "$MTOKEN_LIB" ] && T=mToken
        printf '1.name=%s\n1.path=%s\n1.status=1\n' "$T" "$P11" > conf/all_tokens.properties
        printf 'service.start=false\nservice.locale=en_in\nprocess.type=custom\nselected.token.name=%s\nselected.token.path=%s\nused.token.name=%s\nused.token.path=%s\n' "$T" "$P11" "$T" "$P11" > conf/default_token.properties
    fi
    exec >>"$E7_LOGS/output.log" 2>>"$E7_LOGS/errorOutput.log"
    # java.awt.headless=true is what NIC's own launcher passes; the app switches it back itself.
    exec "$J" "$NOATK" "${UI[@]}" -Djava.awt.headless=true -jar "$E7_JAR" --server.address="$BIND"
fi

if [ "$SVC" = eoffice ]; then
    J8=$(find_java8) || { echo "No Java 8 runtime with GUI libraries found - run: railway-dsc install"; exit 1; }
    mkdir -p "$EOFFICE_LOGS"
    cd "$EOFFICE_DIR" || exit 1                              # pkcs11cfg is read from here
    if P11=$(find_p11_lib) && ! grep -qs "^library = $P11\$" pkcs11cfg; then              # follow the plugged token
        printf 'name = DSCToken\nlibrary = %s\n' "$P11" > pkcs11cfg
    fi
    exec >>"$EOFFICE_LOGS/output.log" 2>>"$EOFFICE_LOGS/error.log"
    # Java 8 cannot scale Swing on Linux: the scaling agent enlarges NIC's PIN window instead.
    case "$DSC_EOFFICE_SCALE" in ""|auto) ES="$DSC_UI_SCALE";; *) ES="$DSC_EOFFICE_SCALE";; esac
    AGENT=()
    if [ -f "$SCALE_JAR" ] && awk -v s="$ES" 'BEGIN{exit !(s+0 > 1.01)}'; then AGENT=("-javaagent:$SCALE_JAR=$ES"); fi
    exec "$J8" "$NOATK" "${AGENT[@]}" -jar "$EOFFICE_JAR" \
        --server.ssl.key-store="file:$EOFFICE_JKS" --server.address="$BIND"
fi

case "$SVC" in
    cris)  APP_DIR="$CRIS_DIR";  APP_JAR="crissigner_app.jar" ;;
    ireps) APP_DIR="$IREPS_DIR"; APP_JAR="irepssigner_app.jar" ;;
    *) echo "usage: launch.sh eoffice|eoffice7|cris|ireps"; exit 2 ;;
esac
JAVA_BIN=$(find_java_modern) || { echo "No Java 11+ runtime with GUI libraries found - run: railway-dsc install"; exit 1; }
cd "$APP_DIR" || exit 1
OPTS=("$NOATK" "-Djava.util.Arrays.useLegacyMergeSort=true" "${UI[@]}"
      "--add-exports=jdk.crypto.cryptoki/sun.security.pkcs11=ALL-UNNAMED"
      "--add-opens=jdk.crypto.cryptoki/sun.security.pkcs11=ALL-UNNAMED"
      "--add-opens=java.base/java.lang=ALL-UNNAMED"
      "--add-opens=java.desktop/javax.swing=ALL-UNNAMED"
      "--add-opens=java.desktop/java.awt=ALL-UNNAMED"
      "--add-opens=java.desktop/sun.awt=ALL-UNNAMED"
      "--add-exports=java.desktop/com.sun.java.swing.plaf.gtk=ALL-UNNAMED")
P11=$(find_p11_lib) && OPTS+=("-Dwebsigner.pkcs11.library=$P11")
CP="$APP_DIR/lib/windows-laf-stub.jar:$APP_DIR/lib/windowslookandfell-stub.jar:$APP_DIR/$APP_JAR:$APP_DIR/lib/*"
[ "$DSC_LOOK" = native ] && [ -f "$LAF_JAR" ] && CP="$LAF_JAR:$CP"      # first on the path wins
exec "$JAVA_BIN" "${OPTS[@]}" -cp "$CP" server.ServerUI
LAUNCH_EOF
    chmod 755 "$LAUNCH"
}

write_units() {
    mkdir -p "$UNIT_DIR"
    local s u
    for s in $SVCS; do
        u=$(svc_unit "$s")
        cat > "$UNIT_DIR/$u.service" <<UNIT_EOF
# Generated by railway-dsc-suite $SUITE_VERSION
[Unit]
Description=$(svc_label "$s")
After=graphical-session.target
StartLimitIntervalSec=0

[Service]
Type=simple
ExecStart=$LAUNCH $s
Restart=always
RestartSec=5
SuccessExitStatus=143

[Install]
WantedBy=default.target
UNIT_EOF
    done
    cat > "$UNIT_DIR/railway-dsc-heal.service" <<UNIT_EOF
# Generated by railway-dsc-suite $SUITE_VERSION
[Unit]
Description=Railway DSC signer suite watchdog

[Service]
Type=oneshot
ExecStart=$BIN heal
UNIT_EOF
    cat > "$UNIT_DIR/railway-dsc-heal.timer" <<UNIT_EOF
# Generated by railway-dsc-suite $SUITE_VERSION
[Unit]
Description=Railway DSC signer suite watchdog (every 3 minutes)

[Timer]
OnStartupSec=90
OnUnitActiveSec=180
AccuracySec=15

[Install]
WantedBy=timers.target
UNIT_EOF
}
unit_names() { local s o=""; for s in $SVCS; do o="$o $(svc_unit "$s").service"; done; echo "$o railway-dsc-heal.timer"; }

install_self() {              # copy this script WITHOUT the payload to ~/.local/bin
    mkdir -p "$(dirname "$BIN")"
    local n; n=$(grep -a -n -m1 "^${MARKER}\$" "$SELF" | cut -d: -f1)
    if [ -n "$n" ]; then head -n "$((n-1))" "$SELF" > "$BIN.tmp"; else cat "$SELF" > "$BIN.tmp"; fi
    chmod 755 "$BIN.tmp"; mv -f "$BIN.tmp" "$BIN"
}

# The files the watchdog can restore by itself (everything except the Java runtimes).
keep_list() {
    local f
    for f in "$EOFFICE_JAR" "$EOFFICE_JKS" "$EOFFICE_CA" "$E7_JAR"; do echo "$f"; done
    find "$CRIS_DIR" "$IREPS_DIR" -maxdepth 2 -type f \( -name '*.jar' -o -name 'certificate.crt' \) 2>/dev/null
    echo "$LAUNCH"; echo "$PROBE"; echo "$LAF_JAR"; echo "$SCALE_JAR"
}
refresh_keep() {
    rm -rf "$KEEP_DIR"; mkdir -p "$KEEP_DIR"; chmod 700 "$KEEP_DIR"; : > "$MANIFEST.tmp"
    local f h
    while IFS= read -r f; do
        [ -f "$f" ] || continue
        h=$(sha "$f"); [ -n "$h" ] || continue
        [ -f "$KEEP_DIR/$h" ] || cp -p "$f" "$KEEP_DIR/$h"
        printf '%s  %s\n' "$h" "$f" >> "$MANIFEST.tmp"
    done < <(keep_list)
    mv -f "$MANIFEST.tmp" "$MANIFEST"
}

# ================================================================== payload ===
PAYLOAD=""; PAYLOAD_TMP=""; WORK_TMP=""
cleanup() { [ -n "$PAYLOAD_TMP" ] && rm -rf "$PAYLOAD_TMP"; [ -n "$WORK_TMP" ] && rm -rf "$WORK_TMP"; return 0; }
trap cleanup EXIT
init_work_tmp() { [ -n "$WORK_TMP" ] || { mkdir -p "$HOME/.cache"; WORK_TMP=$(mktemp -d "$HOME/.cache/railway-dsc-work.XXXXXX") || die "cannot create a temporary directory"; }; }
work_tmp() { echo "$WORK_TMP"; }     # created once in main(), so subshells share it

locate_payload() {
    local n; n=$(grep -a -n -m1 "^${MARKER}\$" "$SELF" | cut -d: -f1)
    if [ -n "$n" ]; then
        mkdir -p "$HOME/.cache"
        PAYLOAD_TMP=$(mktemp -d "$HOME/.cache/railway-dsc-payload.XXXXXX") || die "cannot create a temporary directory"
        info "Unpacking embedded payload ..."
        tail -n "+$((n+1))" "$SELF" | tar -xzf - -C "$PAYLOAD_TMP" || die "payload is damaged - copy the .run file again"
        PAYLOAD="$PAYLOAD_TMP"
    elif [ -d "$(dirname "$SELF")/payload" ]; then
        PAYLOAD="$(dirname "$SELF")/payload"
    fi
    if [ -n "$PAYLOAD" ] && [ -f "$PAYLOAD/MANIFEST.sha256" ]; then
        ( cd "$PAYLOAD" && sha256sum --quiet -c MANIFEST.sha256 >/dev/null 2>&1 ) || die "payload failed its checksum - copy the .run file again"
    fi
}

# ----------------------------------------------------- eOffice file sources ---
find_msi() {                  # the official Windows installer of the 4.1.8 signer
    [ -n "${OPT_MSI:-}" ] && { [ -f "$OPT_MSI" ] && echo "$OPT_MSI"; return; }
    local d f
    for d in "$U_HOME/Downloads" "$U_HOME/Desktop" "$U_HOME"; do      # missing folders must not abort the search
        [ -d "$d" ] || continue
        f=$(find "$d" -maxdepth 5 -type f -iname '*signer*4.1.8*.msi' -print -quit 2>/dev/null || true)
        [ -n "$f" ] && { echo "$f"; return 0; }
    done
    return 1
}
jar_from_msi() {              # $1 = msi -> path of the verified jar (in a temp dir)
    have cabextract || return 1
    local t; t="$(work_tmp)/msi"; mkdir -p "$t"
    cabextract -q -d "$t" -F "$EOFFICE_JAR_NAME" "$1" >/dev/null 2>&1 || return 1
    [ "$(sha "$t/$EOFFICE_JAR_NAME")" = "$EOFFICE_JAR_SHA" ] || return 1
    echo "$t/$EOFFICE_JAR_NAME"
}
e7_zip_candidates() {         # NIC's "DigitalSignerService_7.0.6_Ubuntu_Installer.zip" or its unpacked folder
    [ -n "${OPT_ZIP7:-}" ] && { echo "$OPT_ZIP7"; return; }
    find "$U_HOME/Downloads" "$U_HOME/Desktop" -maxdepth 4 -type f -iname '*DigitalSignerService*7.0.6*Installer*.zip' 2>/dev/null
    find "$U_HOME/Downloads" "$U_HOME/Desktop" -maxdepth 6 -type d -name app -path '*7.0.6*' 2>/dev/null
}
e7_extract() {                # $1 = zip or app dir  $2 = member (DigitalSignerService-7.0.6.jar|jre.zip)  $3 = out file
    if [ -d "$1" ]; then [ -f "$1/$2" ] && cp -p "$1/$2" "$3"
    else unzip -p "$1" "*/app/$2" > "$3" 2>/dev/null; fi
    [ -s "$3" ]
}
e7_jar_source() {             # prints a verified 7.0.6 jar
    local c t; t="$(work_tmp)/e7"; mkdir -p "$t"
    [ -n "$PAYLOAD" ] && [ "$(sha "$PAYLOAD/eoffice7/$E7_JAR_NAME")" = "$E7_JAR_SHA" ] && { echo "$PAYLOAD/eoffice7/$E7_JAR_NAME"; return 0; }
    while IFS= read -r c; do
        [ -n "$c" ] && e7_extract "$c" "$E7_JAR_NAME" "$t/$E7_JAR_NAME" && [ "$(sha "$t/$E7_JAR_NAME")" = "$E7_JAR_SHA" ] && { echo "$t/$E7_JAR_NAME"; return 0; }
    done < <(e7_zip_candidates)
    for c in "$LEGACY_706_DIR/$E7_JAR_NAME" "$LEGACY_706_DIR/$E7_JAR_NAME.bak" "$E7_JAR"; do
        [ "$(sha "$c")" = "$E7_JAR_SHA" ] && { echo "$c"; return 0; }
    done
    return 1
}
e7_jre_from_zip() {           # unpack NIC's bundled Java 17 (jre.zip) into $1
    local c t; t="$(work_tmp)/e7jre"; mkdir -p "$t"
    while IFS= read -r c; do
        [ -n "$c" ] && e7_extract "$c" jre.zip "$t/jre.zip" && [ "$(sha "$t/jre.zip")" = "$E7_JRE_ZIP_SHA" ] || continue
        rm -rf "$t/x"; mkdir -p "$t/x" && unzip -q -o "$t/jre.zip" -d "$t/x" && [ -x "$t/x/jre/bin/java" ] || continue
        rm -rf "$1"; mkdir -p "$(dirname "$1")"; mv "$t/x/jre" "$1"; return 0
    done < <(e7_zip_candidates)
    return 1
}

renewed_jks_candidates() {    # NIC's renewed eoffsigner certificate ships in the 7.0.x packages
    [ -n "$PAYLOAD" ] && echo "jks:$PAYLOAD/eoffice/dscSSL.jks"
    echo "jks:$EOFFICE_JKS"
    local f
    for f in "$LEGACY_706_DIR"/DigitalSignerService-7.0.*.jar* ; do [ -f "$f" ] && echo "jar:$f"; done
    find "$U_HOME/Downloads" "$U_HOME/Desktop" -maxdepth 5 -type f -name 'DigitalSignerService-7.0.*.jar' 2>/dev/null | sed 's/^/jar:/'
    find "$U_HOME/Downloads" "$U_HOME/Desktop" -maxdepth 4 -type f -iname '*DigitalSignerService*7.0*Installer*.zip' 2>/dev/null | sed 's/^/zip:/'
    [ -f "$EOFFICE_JAR" ] && echo "jar:$EOFFICE_JAR"        # 4.1.8's own (expired 2026) as a last resort
}
pick_valid_jks() {            # prints a path to a currently valid dscSSL.jks
    local c kind f t i=0
    while IFS= read -r c; do
        kind="${c%%:*}"; f="${c#*:}"; [ -f "$f" ] || continue
        i=$((i+1)); t="$(work_tmp)/jks$i"; mkdir -p "$t"
        case "$kind" in
            jks) cp -p "$f" "$t/dscSSL.jks" ;;
            jar) unzip -p "$f" BOOT-INF/classes/dscSSL.jks > "$t/dscSSL.jks" 2>/dev/null ;;
            zip) unzip -p "$f" '*/app/DigitalSignerService-7.0.*.jar' > "$t/in.jar" 2>/dev/null &&
                 unzip -p "$t/in.jar" BOOT-INF/classes/dscSSL.jks > "$t/dscSSL.jks" 2>/dev/null ;;
        esac
        [ -s "$t/dscSSL.jks" ] || continue
        if ! jks_trusted "$t/dscSSL.jks"; then
            [ "$kind" = jks ] || warn "ignoring $f: its certificate is not issued by NIC's eOfficeCA2022 (fingerprint pinned)" >&2
            continue
        fi
        jks_valid "$t/dscSSL.jks" && { echo "$t/dscSSL.jks"; return 0; }
    done < <(renewed_jks_candidates)
    return 1
}

# ================================================================= pack ======
cmd_pack() {
    step "Packing this machine's working installation"
    local out="${1:-$PWD/railway-dsc-suite-$(date +%Y%m%d).run}" st s j8 j17 r
    svc_files_ok eoffice || svc_files_ok eoffice7 || die "no eOffice signer installed (run install first)"
    [ -f "$CRIS_DIR/crissigner_app.jar" ]  || warn "CrisSigner not found in $CRIS_DIR - packing without it"
    [ -f "$IREPS_DIR/irepssigner_app.jar" ] || warn "IREPSSigner not found in $IREPS_DIR - packing without it"
    if [ -x "$PROBE" ]; then for s in $SVCS; do probe "$s" || warn "$(svc_label "$s") is not answering right now - packing it anyway"; done; fi
    st="$(work_tmp)/pack"; mkdir -p "$st/eoffice" "$st/drivers"
    svc_files_ok eoffice && cp -p "$EOFFICE_JAR" "$EOFFICE_JKS" "$st/eoffice/"
    svc_files_ok eoffice7 && { mkdir -p "$st/eoffice7"; cp -p "$E7_JAR" "$st/eoffice7/"; }
    for s in cris ireps; do
        local src="$CRIS_DIR"; [ $s = ireps ] && src="$IREPS_DIR"
        [ -d "$src" ] || continue
        mkdir -p "$st/$s"; cp -p "$src"/*.jar "$st/$s/"; cp -a "$src/lib" "$st/$s/"
        for f in certificate.crt icon.png; do [ -f "$src/$f" ] && cp -p "$src/$f" "$st/$s/"; done
    done
    if j8=$(find_java8); then r="$(dirname "$(dirname "$(readlink -f "$j8")")")"; cp -aL "$r" "$st/jre8" && ok "Java 8 runtime added ($r)"
    else warn "no Java 8 to pack - the target will install one from its package manager"; fi
    if j17=$(find_java_modern); then r="$(dirname "$(dirname "$(readlink -f "$j17")")")"; cp -aL "$r" "$st/jre17" && ok "Java $(java_major "$j17") runtime added for CRIS/IREPS ($r)"
    else warn "no Java 11+ to pack"; fi
    [ -f "$MTOKEN_LIB" ] && cp -p "$MTOKEN_LIB" "$st/drivers/"
    # pyHanko for sign-pdf, as wheels for this machine's Python (the target falls back to PyPI on another Python)
    local pip="$PDF_VENV/bin/pip"; [ -x "$pip" ] || pip=""
    if [ -n "$pip" ] && mkdir -p "$st/pdf/wheels" && "$pip" download -q -d "$st/pdf/wheels" "$PYHANKO_REQ" >/dev/null 2>&1; then
        ok "pyHanko wheels added for Python $(python3 -c 'import sys;print("%d.%d"%sys.version_info[:2])') ($(du -sh "$st/pdf/wheels" | cut -f1))"
    else rm -rf "$st/pdf"; warn "pyHanko wheels not added (needs sign-pdf installed here and internet) - targets will download them"; fi
    ( cd "$st" && find . -type f ! -name MANIFEST.sha256 -print0 | sort -z | xargs -0 sha256sum > MANIFEST.sha256 )
    info "Compressing ..."
    local n; n=$(grep -a -n -m1 "^${MARKER}\$" "$SELF" | cut -d: -f1)
    { if [ -n "$n" ]; then head -n "$((n-1))" "$SELF"; else cat "$SELF"; fi
      echo "$MARKER"
      tar -czf - -C "$st" . ; } > "$out.tmp" || die "packing failed"
    chmod 700 "$out.tmp"; mv -f "$out.tmp" "$out"     # contains vendor TLS keys: owner only
    ok "Created $out ($(du -h "$out" | cut -f1))"
    info "Copy it to the other PC and run:  bash $(basename "$out") install"
}

# =============================================================== root phase ===
pkg_install() {               # best effort, one package at a time
    local p
    for p in "$@"; do
        if   have apt-get;      then DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$p" >/dev/null 2>&1
        elif have dnf;          then dnf install -y "$p" >/dev/null 2>&1
        elif have yum;          then yum install -y "$p" >/dev/null 2>&1
        elif have zypper;       then zypper --non-interactive install "$p" >/dev/null 2>&1
        elif have pacman;       then pacman -S --noconfirm --needed "$p" >/dev/null 2>&1
        elif have apk;          then apk add "$p" >/dev/null 2>&1
        elif have xbps-install; then xbps-install -y "$p" >/dev/null 2>&1
        else return 1; fi && info "installed $p" || warn "could not install package '$p'"
    done
}
pkgs_for() {                  # $1 = logical need -> distro package names
    local m=other
    if have apt-get; then m=apt; elif have dnf || have yum; then m=dnf; elif have zypper; then m=zypper
    elif have pacman; then m=pacman; elif have apk; then m=apk; elif have xbps-install; then m=xbps; fi
    case "$1:$m" in
        python:pacman) echo python;;                     python:*) echo python3;;
        certutil:apt) echo libnss3-tools;;               certutil:dnf|certutil:apk) echo nss-tools;;
        certutil:zypper) echo mozilla-nss-tools;;        certutil:*) echo nss;;
        cabextract:*) echo cabextract;;
        unzip:*) echo unzip;;
        xlibs:apt) echo "libxtst6 libxi6 libxrender1 libfreetype6 fontconfig";;
        xlibs:zypper) echo "libXtst6 libXi6 libXrender1 libfreetype6 fontconfig";;
        xlibs:pacman) echo "libxtst libxi libxrender freetype2 fontconfig";;
        xlibs:apk) echo "libxtst libxi libxrender freetype fontconfig ttf-dejavu";;
        xlibs:*) echo "libXtst libXi libXrender freetype fontconfig";;
        java8:apt) echo openjdk-8-jre;;                  java8:dnf) echo java-1.8.0-openjdk;;
        java8:zypper) echo java-1_8_0-openjdk;;          java8:pacman) echo jre8-openjdk;;
        java8:apk|java8:xbps) echo openjdk8-jre;;
        java17:apt) echo openjdk-17-jre;;                java17:dnf|java17:zypper) echo java-17-openjdk;;
        java17:pacman) echo jre17-openjdk;;              java17:apk|java17:xbps) echo openjdk17-jre;;
        smartcard:apt) echo "pcscd libccid opensc";;     smartcard:dnf) echo "pcsc-lite pcsc-lite-ccid opensc";;
        smartcard:zypper) echo "pcsc-lite pcsc-ccid opensc";;
        smartcard:pacman|smartcard:xbps) echo "pcsclite ccid opensc";;
        smartcard:apk) echo "pcsc-lite ccid opensc";;
        pdfviewer:apt) echo "papers evince";;            pdfviewer:*) echo "papers evince";;   # first that installs
        venv:apt) echo python3-venv;;                    venv:*) echo "";;                    # ensurepip elsewhere
    esac
}
xlibs_missing() {
    have ldconfig || return 1
    local l c; c=$(ldconfig -p 2>/dev/null)
    for l in libXtst.so.6 libXi.so.6 libXrender.so.1 libfreetype.so.6 libfontconfig.so.1; do
        case "$c" in *"$l"*) ;; *) return 0;; esac
    done
    return 1
}

# ---- PDF signing: what needs root -----------------------------------------------
pdf_viewer() { local v; for v in papers evince; do have "$v" && { echo "$v"; return 0; }; done; return 1; }
venv_ok() { python3 -c 'import ensurepip, venv' >/dev/null 2>&1; }
aa_enabled() { [ "$(cat /sys/module/apparmor/parameters/enabled 2>/dev/null)" = Y ] && [ -d /etc/apparmor.d ]; }
aa_viewer_profiles() { local p; for p in $AA_VIEWERS; do [ -f "/etc/apparmor.d/$p" ] && echo "$p"; done; }
aa_block() {                  # the lines added to a viewer's local AppArmor file. Only AppArmor's extra limit is
    # lifted: normal file permissions still decide which USB devices may be opened (the udev rule grants the token).
    printf '%s\n' "$AA_BEGIN" \
        "# the token's driver (loaded by NSS from ~/.pki/nssdb/pkcs11.txt) finds and opens the token through libusb" \
        "/dev/bus/usb/ r," "/dev/bus/usb/[0-9]*/ r," "/dev/bus/usb/[0-9]*/[0-9]* rw," \
        "/sys/bus/usb/devices/ r," "/sys/devices/**/usb[0-9]*/** r," "/run/udev/data/c189:* r," "$AA_END"
}
aa_block_current() { [ "$(sed -n "\|^$AA_BEGIN\$|,\|^$AA_END\$|p" "/etc/apparmor.d/local/$1" 2>/dev/null)" = "$(aa_block)" ]; }
aa_block_old() { grep -qsF "$AA_BEGIN" "/etc/apparmor.d/local/$1"; }      # present, but another version
aa_rules_missing() {          # a viewer's AppArmor profile does not (yet, or not in this version) let it reach the token
    aa_enabled || return 1
    local p; for p in $(aa_viewer_profiles); do aa_block_current "$p" || { echo "$p"; return 0; }; done
    return 1
}
aa_add_token_rules() {        # root: the token's PKCS#11 driver (loaded by NSS inside the viewer) needs the USB tree.
    # Without this the mToken driver's libusb_init() fails under the profile and the driver crashes the viewer.
    aa_enabled || return 0
    local p f
    for p in $(aa_viewer_profiles); do
        f="/etc/apparmor.d/local/$p"
        aa_block_current "$p" && continue
        mkdir -p /etc/apparmor.d/local; touch "$f"; cp -p "$f" "$f.bak-railway-dsc"
        sed -i "\|^$AA_BEGIN\$|,\|^$AA_END\$|d" "$f"          # an older version of the block
        aa_block >> "$f"
        if apparmor_parser -r "/etc/apparmor.d/$p" >/dev/null 2>&1; then ok "AppArmor: ${p#usr.bin.} may now use the DSC token"
        else cp -p "$f.bak-railway-dsc" "$f"; apparmor_parser -r "/etc/apparmor.d/$p" >/dev/null 2>&1
             warn "AppArmor refused the token rules for ${p#usr.bin.} - left unchanged"; fi
    done
}

opensc_present() { local l; for l in $OPENSC_LIBS; do [ -f "$l" ] && return 0; done; return 1; }
smartcard_stack_ok() { { have pcscd || [ -x /usr/sbin/pcscd ]; } && opensc_present; }
find_epass_zip() {            # Feitian's Linux driver zip: explicit file, or the known version in ~/Downloads
    local f
    if [ -n "${OPT_EPASS_ZIP:-}" ]; then [ -f "$OPT_EPASS_ZIP" ] && echo "$OPT_EPASS_ZIP"; return; fi
    while IFS= read -r f; do [ "$(sha "$f")" = "$EPASS_ZIP_SHA" ] && { echo "$f"; return 0; }; done < <(
        find "$U_HOME/Downloads" "$U_HOME/Desktop" -maxdepth 4 -type f -iname 'ePass2003*Linux*.zip' 2>/dev/null)
    return 1
}

cmd_root() {                  # internal: runs under sudo.  args: user payload_dir need_java8 need_java17 need_cab epass_zip pdf
    local user="$1" payload="$2" nj8="$3" nj17="$4" ncab="$5" epass="${6:-}" pdf="${7:-0}" home
    [ "$(id -u)" -eq 0 ] || die "root phase must run as root"
    home=$(getent passwd "$user" | cut -d: -f6); [ -n "$home" ] || die "unknown user $user"
    set_user_paths "$home"
    step "System-level setup (as root)"

    have apt-get && apt-get update -qq >/dev/null 2>&1
    have python3 || pkg_install $(pkgs_for python)
    have certutil || pkg_install $(pkgs_for certutil)
    have unzip || pkg_install $(pkgs_for unzip)
    [ "$ncab" = 1 ] && pkg_install $(pkgs_for cabextract)
    xlibs_missing && pkg_install $(pkgs_for xlibs)
    [ "$nj8" = 1 ] && pkg_install $(pkgs_for java8)
    [ "$nj17" = 1 ] && pkg_install $(pkgs_for java17)
    smartcard_stack_ok || pkg_install $(pkgs_for smartcard)      # pcscd + CCID + OpenSC (ePass2003, smart cards)
    if have systemctl && [ -d /run/systemd/system ]; then systemctl enable --now pcscd.socket >/dev/null 2>&1 || true; fi
    if [ "$pdf" = 1 ]; then                                     # PDF signing: viewer, Python venv, AppArmor
        local v; for v in $(pkgs_for pdfviewer); do pdf_viewer >/dev/null && break; pkg_install "$v"; done
        pdf_viewer >/dev/null || warn "no PDF viewer with signing could be installed (papers / evince)"
        venv_ok || { [ -n "$(pkgs_for venv)" ] && pkg_install $(pkgs_for venv); }
        aa_add_token_rules
    fi
    if [ -n "$epass" ] && [ -f "$epass" ] && [ ! -f "$CASTLE_LIB" ] && [ "$(uname -m)" = x86_64 ]; then
        # Only the PKCS#11 library is taken; Feitian's config scripts (hotplug edits) are not run -
        # the suite's udev rule already gives the desktop user access to the token.
        local t; t=$(mktemp -d)
        if unzip -q -o "$epass" '*/redist/libcastle.so.1.0.0' -d "$t" 2>/dev/null && f=$(find "$t" -name libcastle.so.1.0.0 -print -quit) && [ -n "$f" ]; then
            install -o root -g root -m 0644 "$f" "$CASTLE_LIB" && ok "Feitian ePass2003 driver installed ($CASTLE_LIB)"
        else warn "could not find libcastle.so.1.0.0 in $epass"; fi
        rm -rf "$t"
    fi

    if [ ! -f "$MTOKEN_LIB" ] && [ -f "$payload/drivers/libcryptoid_pkcs11.so" ] && [ "$(uname -m)" = x86_64 ]; then
        install -o root -g root -m 0644 "$payload/drivers/libcryptoid_pkcs11.so" "$MTOKEN_LIB" && ok "mToken PKCS#11 driver installed"
    fi
    if [ -d /etc/udev/rules.d ] && ! udev_rule_present; then
        {   echo "# Railway DSC suite: give the logged-in desktop user raw USB access to DSC tokens"
            echo "# (drivers such as the Longmai mToken talk to the token over USB, not PC/SC)."
            local t; for t in $TOKEN_VIDS; do
                case "${t%%:*}" in 04e6|072f) continue;; esac       # card readers are handled by pcscd
                echo "SUBSYSTEM==\"usb\", ATTRS{idVendor}==\"${t%%:*}\", TAG+=\"uaccess\"   # ${t#*:}"
            done; } > "$UDEV_RULE"
        udevadm control --reload-rules 2>/dev/null; udevadm trigger --subsystem-match=usb 2>/dev/null
        ok "udev rule for DSC tokens installed (re-plug the token once)"
    fi
    if ! grep -qs "$HOSTS_NAME" /etc/hosts; then
        printf '%s\t%s\n' "$HOSTS_ADDR" "$HOSTS_NAME" >> /etc/hosts && ok "/etc/hosts: $HOSTS_NAME -> $HOSTS_ADDR"
    elif ! hosts_ok; then
        sed -i.bak-railway-dsc "/[[:space:]]$HOSTS_NAME\([[:space:]]\|\$\)/d" /etc/hosts
        printf '%s\t%s\n' "$HOSTS_ADDR" "$HOSTS_NAME" >> /etc/hosts && ok "/etc/hosts: $HOSTS_NAME now points to loopback"
    fi
    if hook_active; then
        cp -p "$VENDOR_HOOK" "$VENDOR_HOOK.vendor-disabled" 2>/dev/null
        printf '%s\n' "# Disabled by railway-dsc-suite: the vendor hook started a signer from every login" \
                      "# shell and killed the running one. The suite's user service starts it instead." > "$VENDOR_HOOK"
        ok "Vendor login-shell autostart disabled"
    fi
    return 0
}

# ================================================================== install ===
copy_if_changed() {           # src dst [mode]  -> sets CHANGED=1 when it wrote
    local src="$1" dst="$2" mode="${3:-}"
    if [ -f "$dst" ] && cmp -s "$src" "$dst"; then return 0; fi
    mkdir -p "$(dirname "$dst")"
    [ -f "$dst" ] && cp -p "$dst" "$dst.bak-$(date +%Y%m%d-%H%M%S)"
    cp -p "$src" "$dst.rdsc-tmp" && mv -f "$dst.rdsc-tmp" "$dst" || die "cannot write $dst"
    [ -n "$mode" ] && chmod "$mode" "$dst"
    CHANGED=1
}

nss_dbs() {                   # every NSS certificate store a browser of this user reads
    local d
    echo "$U_HOME/.pki/nssdb"
    for d in "$U_HOME"/.mozilla/firefox/* "$U_HOME"/.config/mozilla/firefox/* \
             "$U_HOME"/snap/firefox/common/.mozilla/firefox/* \
             "$U_HOME"/.var/app/org.mozilla.firefox/.mozilla/firefox/* \
             "$U_HOME"/.librewolf/* "$U_HOME"/.waterfox/* \
             "$U_HOME"/snap/chromium/current/.pki/nssdb "$U_HOME"/.var/app/*/.pki/nssdb; do
        [ -f "$d/cert9.db" ] && echo "$d"
    done
}
trust_list() {                # name|file|flags  (minimum trust: C = may vouch for servers only)
    echo "eOfficeCA2022|$EOFFICE_CA|C,,"
    echo "IREPSSigner eMudhra Local CA|$IREPS_DIR/certificate.crt|C,,"
    echo "CrisSigner 127.0.0.1|$CRIS_DIR/certificate.crt|P,,"     # self-signed leaf: trusted as that one peer
}
cert_fp() {                   # $1 = PEM or DER file (or - for stdin) -> SHA-256 fingerprint
    local f="$1"; [ "$f" = - ] && f=/dev/stdin
    openssl x509 -in "$f" -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2 ||
        openssl x509 -inform DER -in "$1" -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2
}
cert_in_db() {                # $1 = nss db  $2 = cert file  -> true if that certificate is in the store (any nickname)
    local fp nick
    have openssl || { certutil -d "sql:$1" -L -n "$3" >/dev/null 2>&1; return; }
    fp=$(cert_fp "$2"); [ -n "$fp" ] || return 1
    while IFS= read -r nick; do
        [ -n "$nick" ] || continue
        [ "$(certutil -d "sql:$1" -L -n "$nick" -a 2>/dev/null | cert_fp -)" = "$fp" ] && return 0
    done < <(certutil -d "sql:$1" -L 2>/dev/null | tail -n +5 | sed -E 's/[[:space:]]+[^[:space:]]*,[^[:space:]]*,[^[:space:]]*[[:space:]]*$//')
    return 1
}
trust_certs() {
    step "Trusting the local signer certificates in browsers"
    have certutil || { warn "certutil not available - browsers will show a certificate warning for the local signers"; return 0; }
    mkdir -p "$U_HOME/.pki/nssdb"
    [ -f "$U_HOME/.pki/nssdb/cert9.db" ] || certutil -d "sql:$U_HOME/.pki/nssdb" -N --empty-password 2>/dev/null
    local d n=0 item name file flags
    while IFS= read -r d; do
        while IFS= read -r item; do
            name="${item%%|*}"; file="${item#*|}"; file="${file%%|*}"; flags="${item##*|}"
            [ -f "$file" ] || continue
            if [ "$name" = eOfficeCA2022 ] && [ "$(cert_fp "$file")" != "$EOFFICE_CA_SHA256" ]; then
                warn "not trusting $file: it is not NIC's eOfficeCA2022 (fingerprint mismatch)"; continue
            fi
            if certutil -d "sql:$d" -L -n "$name" >/dev/null 2>&1; then certutil -d "sql:$d" -M -n "$name" -t "$flags" 2>/dev/null
            elif cert_in_db "$d" "$file" "$name"; then :      # already trusted under another nickname
            else certutil -d "sql:$d" -A -n "$name" -t "$flags" -i "$file" 2>/dev/null || warn "could not add '$name' to $d"; fi
        done < <(trust_list)
        n=$((n+1))
    done < <(nss_dbs)
    ok "Certificates trusted in $n browser store(s) - restart the browser to pick them up"
}

# ============================================================ PDF signing ===
# "sign-pdf" (source: extras/sign-pdf/sign_pdf.py) and the CCA India 2022 root (extras/sign-pdf/CCAIndia2022.pem)
SIGNPDF_SHA="9056768a53899b0f695816cb3dfe0ab891fba4c81a4597b415b6e2439ee73b63"
SIGNPDF_B64="IiIiU2lnbiBhIFBERiB3aXRoIHRoZSBEU0MgVVNCIHRva2VuIChQQWRFUywgdmlzaWJsZSBzaWduYXR1cmUgYm94IGJ5IGRlZmF1bHQpLgoKICAgIHNpZ24tcGRmIGxldHRlci5wZGYgICAgICAgICAgICAgICAgICAgICAgICAgLT4gbGV0dGVyX3NpZ25lZC5wZGYsIGJveCBhdCBib3R0b20tcmlnaHQgb2YgdGhlIGxhc3QgcGFnZQogICAgc2lnbi1wZGYgbGV0dGVyLnBkZiAtbyBvdXQucGRmIC0tcmVhc29uICJBcHByb3ZlZCIgLS1sb2NhdGlvbiAiUmF0bGFtIgogICAgc2lnbi1wZGYgbGV0dGVyLnBkZiAtLXBhZ2UgMSAtLXBvcyBibCAgICAgICBmaXJzdCBwYWdlLCBib3R0b20tbGVmdAogICAgc2lnbi1wZGYgbGV0dGVyLnBkZiAtLWludmlzaWJsZSAgICAgICAgICAgICBubyBib3ggKHRoZSBzaWduYXR1cmUgaXMgc3RpbGwgaW4gdGhlIGZpbGUpCgpUaGUgdG9rZW4gUElOIGlzIGFza2VkIGZvciBldmVyeSB0aW1lICh0ZXJtaW5hbCwgb3IgYSBwYXNzd29yZCBib3ggd2hlbiBzdGFydGVkIGZyb20gdGhlIGZpbGUgbWFuYWdlcikgYW5kIGlzCm5ldmVyIHN0b3JlZC4gVGhlIHRva2VuJ3MgZHJpdmVyIGlzIGNob3NlbiBieSB0aGUgdG9rZW4gcGx1Z2dlZCBpbiAoc2FtZSB0YWJsZSBhcyByYWlsd2F5LWRzYykuCiIiIgppbXBvcnQgYXJncGFyc2UKaW1wb3J0IGdldHBhc3MKaW1wb3J0IG9zCmltcG9ydCBzaHV0aWwKaW1wb3J0IHN1YnByb2Nlc3MKaW1wb3J0IHN5cwppbXBvcnQgdGVtcGZpbGUKCmZyb20gcHloYW5rby5wZGZfdXRpbHMuaW5jcmVtZW50YWxfd3JpdGVyIGltcG9ydCBJbmNyZW1lbnRhbFBkZkZpbGVXcml0ZXIKZnJvbSBweWhhbmtvLnNpZ24gaW1wb3J0IGZpZWxkcywgc2lnbmVycwpmcm9tIHB5aGFua28uc2lnbi5wa2NzMTEgaW1wb3J0IFBLQ1MxMVNpZ25lciwgb3Blbl9wa2NzMTFfc2Vzc2lvbgpmcm9tIHB5aGFua28uc3RhbXAgaW1wb3J0IFRleHRTdGFtcFN0eWxlCgpPUEVOU0MgPSBbIi91c3IvbGliL3g4Nl82NC1saW51eC1nbnUvb3BlbnNjLXBrY3MxMS5zbyIsICIvdXNyL2xpYi94ODZfNjQtbGludXgtZ251L3BrY3MxMS9vcGVuc2MtcGtjczExLnNvIl0KRFJJVkVSUyA9IHsgICMgVVNCIHZlbmRvciBpZCAtPiBQS0NTIzExIGRyaXZlcnMsIGJlc3QgZmlyc3QgKG1pcnJvcnMgcmFpbHdheS1kc2MncyBwMTFfZm9yX3ZpZCkKICAgICIwNTVjIjogWyIvdXNyL2xpYi9saWJjcnlwdG9pZF9wa2NzMTEuc28iLCAiL3Vzci9saWIvbGlibVRva2VuUEtDUzExLnNvIl0sCiAgICAiMDk2ZSI6IFsiL3Vzci9saWIvbGliY2FzdGxlLnNvLjEuMC4wIiwgIi91c3IvbGliL2xpYmNhc3RsZS5zbyIsICIvdXNyL2xpYi94ODZfNjQtbGludXgtZ251L2xpYmNhc3RsZS5zbyJdICsgT1BFTlNDLAogICAgIjE2M2MiOiBbIi91c3IvbGliL1dhdGNoRGF0YS9Qcm94S2V5L2xpYi9saWJ3ZHBrY3NfU2lnbmF0dXJlUDExLnNvIiwgIi91c3IvbGliL1dhdGNoRGF0YS9UUlVTVEtFWS9saWIvbGlid2Rwa2NzX1RSVVNUS0VZLnNvIiwKICAgICAgICAgICAgICIvdXNyL2xpYi9XYXRjaERhdGEvZU11ZGhyYV8zLjQuMy9saWIvbGlid2Rwa2NzX2VNdWRocmFfMzQzLnNvIiwgIi91c3IvbGliL1dhdGNoRGF0YS9QUk9YS2V5L2xpYi9saWJ3ZHBrY3Muc28iLAogICAgICAgICAgICAgIi91c3IvbGliL2xpYndkcGtjcy5zbyJdLAogICAgIjA1MjkiOiBbIi91c3IvbGliL2xpYmVUUGtjczExLnNvIiwgIi91c3IvbGliL2xpYmVUb2tlbi5zbyJdLAogICAgIjA4ZTYiOiBbIi91c3IvbGliL3BrY3MxMS9saWJndG9wMTFkb3RuZXQuc28iLCAiL3Vzci9saWIvbGliZ3RvcDExZG90bmV0LnNvIl0gKyBPUEVOU0MsCiAgICAiMjRkYyI6IFsiL3Vzci9saWIvbGliamNQS0NTMTEtMi5zbyIsICIvdXNyL2xpYi94ODZfNjQtbGludXgtZ251L2xpYmpjUEtDUzExLTIuc28iXSwKICAgICIwNGU2IjogT1BFTlNDLCAiMDcyZiI6IE9QRU5TQywKfQpHVUkgPSBub3Qgc3lzLnN0ZGluLmlzYXR0eSgpCgoKZGVmIHNheShtc2csIGVycm9yPUZhbHNlKToKICAgIHByaW50KG1zZywgZmlsZT1zeXMuc3RkZXJyIGlmIGVycm9yIGVsc2Ugc3lzLnN0ZG91dCwgZmx1c2g9VHJ1ZSkKCgpkZWYgZmFpbChtc2cpOgogICAgc2F5KCJzaWduLXBkZjogIiArIG1zZywgZXJyb3I9VHJ1ZSkKICAgIGlmIEdVSSBhbmQgc2h1dGlsLndoaWNoKCJ6ZW5pdHkiKToKICAgICAgICBzdWJwcm9jZXNzLnJ1bihbInplbml0eSIsICItLWVycm9yIiwgIi0tdGl0bGU9U2lnbiBQREYiLCAiLS1uby13cmFwIiwgIi0tdGV4dD0iICsgbXNnXSkKICAgIHN5cy5leGl0KDEpCgoKZGVmIHBsdWdnZWRfdmlkcygpOgogICAgb3V0ID0gW10KICAgIGZvciBkIGluIG9zLmxpc3RkaXIoIi9zeXMvYnVzL3VzYi9kZXZpY2VzIik6CiAgICAgICAgdHJ5OgogICAgICAgICAgICB3aXRoIG9wZW4oZiIvc3lzL2J1cy91c2IvZGV2aWNlcy97ZH0vaWRWZW5kb3IiKSBhcyBmOgogICAgICAgICAgICAgICAgb3V0LmFwcGVuZChmLnJlYWQoKS5zdHJpcCgpLmxvd2VyKCkpCiAgICAgICAgZXhjZXB0IE9TRXJyb3I6CiAgICAgICAgICAgIHBhc3MKICAgIHJldHVybiBvdXQKCgpkZWYgZmluZF9kcml2ZXIob3ZlcnJpZGUpOgogICAgaWYgb3ZlcnJpZGU6CiAgICAgICAgcmV0dXJuIG92ZXJyaWRlIGlmIG9zLnBhdGguaXNmaWxlKG92ZXJyaWRlKSBlbHNlIGZhaWwoIm5vIHN1Y2ggUEtDUyMxMSBkcml2ZXI6ICIgKyBvdmVycmlkZSkKICAgIGtub3duID0gRmFsc2UKICAgIGZvciB2IGluIHBsdWdnZWRfdmlkcygpOgogICAgICAgIGlmIHYgaW4gRFJJVkVSUzoKICAgICAgICAgICAga25vd24gPSBUcnVlCiAgICAgICAgICAgIGZvciBsaWIgaW4gRFJJVkVSU1t2XToKICAgICAgICAgICAgICAgIGlmIG9zLnBhdGguaXNmaWxlKGxpYik6CiAgICAgICAgICAgICAgICAgICAgcmV0dXJuIGxpYgogICAgaWYga25vd246CiAgICAgICAgZmFpbCgidGhlIHBsdWdnZWQgdG9rZW4ncyBkcml2ZXIgaXMgbm90IGluc3RhbGxlZCAocnVuOiByYWlsd2F5LWRzYyBkb2N0b3IpIikKICAgIGZhaWwoIm5vIERTQyB0b2tlbiBmb3VuZCAtIHBsdWcgaW4gdGhlIFVTQiB0b2tlbiBhbmQgdHJ5IGFnYWluIikKCgpkZWYgYXNrX3BpbigpOgogICAgaWYgR1VJIGFuZCBzaHV0aWwud2hpY2goInplbml0eSIpOgogICAgICAgIHIgPSBzdWJwcm9jZXNzLnJ1bihbInplbml0eSIsICItLXBhc3N3b3JkIiwgIi0tdGl0bGU9RFNDIHRva2VuIFBJTiJdLCBjYXB0dXJlX291dHB1dD1UcnVlLCB0ZXh0PVRydWUpCiAgICAgICAgaWYgci5yZXR1cm5jb2RlICE9IDA6CiAgICAgICAgICAgIHN5cy5leGl0KDEpCiAgICAgICAgcmV0dXJuIHIuc3Rkb3V0LnJzdHJpcCgiXG4iKQogICAgcmV0dXJuIGdldHBhc3MuZ2V0cGFzcygiVG9rZW4gUElOOiAiKQoKCmRlZiBjdXJyZW50X3VtYXNrKCk6CiAgICBtID0gb3MudW1hc2soMCkKICAgIG9zLnVtYXNrKG0pCiAgICByZXR1cm4gbQoKCmRlZiBpc19jYShjZXJ0KToKICAgIGJjID0gY2VydC5iYXNpY19jb25zdHJhaW50c192YWx1ZQogICAgcmV0dXJuIGJvb2woYmMgYW5kIGJjWyJjYSJdLm5hdGl2ZSkKCgpkZWYgbWVkaWFfYm94KHcsIHBhZ2VfaXgpOgogICAgIiIiVGhlIHBhZ2UncyBzaXplLCBhIE1lZGlhQm94IGluaGVyaXRlZCBmcm9tIGl0cyBwYXJlbnRzIGluY2x1ZGVkIChBNCB3aGVuIG5vbmUgY2FuIGJlIHJlYWQpLiIiIgogICAgdHJ5OgogICAgICAgIG5vZGUgPSB3LmZpbmRfcGFnZV9mb3JfbW9kaWZpY2F0aW9uKHBhZ2VfaXgpWzBdLmdldF9vYmplY3QoKQogICAgICAgIHdoaWxlIG5vZGUgaXMgbm90IE5vbmU6CiAgICAgICAgICAgIGlmICIvTWVkaWFCb3giIGluIG5vZGU6CiAgICAgICAgICAgICAgICByZXR1cm4gW2Zsb2F0KHgpIGZvciB4IGluIG5vZGVbIi9NZWRpYUJveCJdXQogICAgICAgICAgICBwYXJlbnQgPSBub2RlLmdldCgiL1BhcmVudCIpCiAgICAgICAgICAgIG5vZGUgPSBwYXJlbnQuZ2V0X29iamVjdCgpIGlmIHBhcmVudCBpcyBub3QgTm9uZSBlbHNlIE5vbmUKICAgIGV4Y2VwdCBFeGNlcHRpb246CiAgICAgICAgcGFzcwogICAgcmV0dXJuIFswLjAsIDAuMCwgNTk1LjAsIDg0Mi4wXQoKCmRlZiBzaWduX2ZpbGUoYSwgc3JjLCBvdXQsIHNpZ25lcik6CiAgICB3aXRoIG9wZW4oc3JjLCAicmIiKSBhcyBmOgogICAgICAgIHcgPSBJbmNyZW1lbnRhbFBkZkZpbGVXcml0ZXIoZiwgc3RyaWN0PUZhbHNlKQogICAgICAgIG5fcGFnZXMgPSBpbnQody5yb290WyIvUGFnZXMiXVsiL0NvdW50Il0pCiAgICAgICAgdXNlZCA9IHNldCgpCiAgICAgICAgdHJ5OgogICAgICAgICAgICBmb3IgeCBpbiB3LnJvb3RbIi9BY3JvRm9ybSJdWyIvRmllbGRzIl06CiAgICAgICAgICAgICAgICB1c2VkLmFkZChzdHIoeC5nZXRfb2JqZWN0KCkuZ2V0KCIvVCIpKSkKICAgICAgICBleGNlcHQgRXhjZXB0aW9uOgogICAgICAgICAgICBwYXNzCiAgICAgICAgZmllbGQgPSBuZXh0KGYiU2lnbmF0dXJle2l9IiBmb3IgaSBpbiByYW5nZSgxLCA5OTkpIGlmIGYiU2lnbmF0dXJle2l9IiBub3QgaW4gdXNlZCkKCiAgICAgICAgc3R5bGUgPSBOb25lCiAgICAgICAgaWYgYS5pbnZpc2libGU6CiAgICAgICAgICAgIHNwZWMgPSBmaWVsZHMuU2lnRmllbGRTcGVjKGZpZWxkKQogICAgICAgIGVsc2U6CiAgICAgICAgICAgIHBhZ2VfaXggPSAoYS5wYWdlIC0gMSkgaWYgYS5wYWdlIGVsc2Ugbl9wYWdlcyAtIDEKICAgICAgICAgICAgaWYgbm90IDAgPD0gcGFnZV9peCA8IG5fcGFnZXM6CiAgICAgICAgICAgICAgICBmYWlsKGYicGFnZSB7YS5wYWdlfSBpcyBub3QgaW4gdGhlIGRvY3VtZW50IChpdCBoYXMge25fcGFnZXN9KSIpCiAgICAgICAgICAgIGxseCwgbGx5LCB1cngsIHVyeSA9IG1lZGlhX2JveCh3LCBwYWdlX2l4KQogICAgICAgICAgICBib3hfdywgYm94X2gsIG0gPSAyMTAsIDY0LCAzMAogICAgICAgICAgICB4ID0gKHVyeCAtIGJveF93IC0gbSkgaWYgYS5wb3MgaW4gKCJiciIsICJ0ciIpIGVsc2UgKGxseCArIG0pCiAgICAgICAgICAgIHkgPSAobGx5ICsgbSkgaWYgYS5wb3MgaW4gKCJiciIsICJibCIpIGVsc2UgKHVyeSAtIGJveF9oIC0gbSkKICAgICAgICAgICAgc3BlYyA9IGZpZWxkcy5TaWdGaWVsZFNwZWMoZmllbGQsIG9uX3BhZ2U9cGFnZV9peCwgYm94PShpbnQoeCksIGludCh5KSwgaW50KHggKyBib3hfdyksIGludCh5ICsgYm94X2gpKSkKICAgICAgICAgICAgbGluZXMgPSAiRGlnaXRhbGx5IHNpZ25lZCBieSAlKHNpZ25lcilzXG5EYXRlOiAlKHRzKXMiCiAgICAgICAgICAgIGlmIGEucmVhc29uOgogICAgICAgICAgICAgICAgbGluZXMgKz0gIlxuUmVhc29uOiAiICsgYS5yZWFzb24ucmVwbGFjZSgiJSIsICIlJSIpCiAgICAgICAgICAgIGlmIGEubG9jYXRpb246CiAgICAgICAgICAgICAgICBsaW5lcyArPSAiXG5Mb2NhdGlvbjogIiArIGEubG9jYXRpb24ucmVwbGFjZSgiJSIsICIlJSIpCiAgICAgICAgICAgIHN0eWxlID0gVGV4dFN0YW1wU3R5bGUoc3RhbXBfdGV4dD1saW5lcywgdGltZXN0YW1wX2Zvcm1hdD0iJWQtJW0tJVkgJUg6JU06JVMgJXoiLCBib3JkZXJfd2lkdGg9MSkKCiAgICAgICAgbWV0YSA9IHNpZ25lcnMuUGRmU2lnbmF0dXJlTWV0YWRhdGEoZmllbGRfbmFtZT1maWVsZCwgcmVhc29uPWEucmVhc29uLCBsb2NhdGlvbj1hLmxvY2F0aW9uLAogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIG1kX2FsZ29yaXRobT0ic2hhMjU2Iiwgc3ViZmlsdGVyPWZpZWxkcy5TaWdTZWVkU3ViRmlsdGVyLlBBREVTKQogICAgICAgICMgYSBuZXcsIHVucHJlZGljdGFibGUgdGVtcCBmaWxlIGJlc2lkZSB0aGUgb3V0cHV0IChPX0VYQ0w6IG5ldmVyIGZvbGxvd3MgYSBwbGFudGVkIGxpbmspLCB0aGVuIHJlbmFtZWQKICAgICAgICBmZCwgdG1wID0gdGVtcGZpbGUubWtzdGVtcChwcmVmaXg9Ii5zaWduLXBkZi0iLCBzdWZmaXg9Ii5wYXJ0IiwgZGlyPW9zLnBhdGguZGlybmFtZShvdXQpIG9yICIuIikKICAgICAgICB0cnk6CiAgICAgICAgICAgIHdpdGggb3MuZmRvcGVuKGZkLCAid2IiKSBhcyBvOgogICAgICAgICAgICAgICAgc2lnbmVycy5QZGZTaWduZXIobWV0YSwgc2lnbmVyLCBzdGFtcF9zdHlsZT1zdHlsZSwgbmV3X2ZpZWxkX3NwZWM9c3BlYykuc2lnbl9wZGYodywgb3V0cHV0PW8pCiAgICAgICAgICAgIG9zLmNobW9kKHRtcCwgMG82NDQgJiB+Y3VycmVudF91bWFzaygpKQogICAgICAgIGV4Y2VwdCBCYXNlRXhjZXB0aW9uOgogICAgICAgICAgICBpZiBvcy5wYXRoLmV4aXN0cyh0bXApOgogICAgICAgICAgICAgICAgb3MucmVtb3ZlKHRtcCkKICAgICAgICAgICAgcmFpc2UKICAgIG9zLnJlcGxhY2UodG1wLCBvdXQpCgoKZGVmIHJlcG9ydChvdXQpOgogICAgc2F5KGYic2lnbmVkICA6IHtvdXR9IikKICAgIGlmIHNodXRpbC53aGljaCgicGRmc2lnIik6CiAgICAgICAgciA9IHN1YnByb2Nlc3MucnVuKFsicGRmc2lnIiwgb3V0XSwgY2FwdHVyZV9vdXRwdXQ9VHJ1ZSwgdGV4dD1UcnVlKQogICAgICAgIG9rID0gIlNpZ25hdHVyZSBWYWxpZGF0aW9uOiBTaWduYXR1cmUgaXMgVmFsaWQiIGluIHIuc3Rkb3V0CiAgICAgICAgc2F5KCJjaGVjayAgIDogIiArICgidGhlIHNpZ25hdHVyZSBpcyB2YWxpZCIgaWYgb2sgZWxzZSAicGRmc2lnIGNvdWxkIG5vdCBjb25maXJtIGl0OlxuIiArIHIuc3Rkb3V0LnN0cmlwKCkpKQogICAgaWYgR1VJIGFuZCBzaHV0aWwud2hpY2goIm5vdGlmeS1zZW5kIik6CiAgICAgICAgc3VicHJvY2Vzcy5ydW4oWyJub3RpZnktc2VuZCIsICJQREYgc2lnbmVkIiwgb3MucGF0aC5iYXNlbmFtZShvdXQpXSkKICAgIGlmIEdVSSBhbmQgb3MuZW52aXJvbi5nZXQoIlNJR05fUERGX09QRU4iLCAiMSIpID09ICIxIiBhbmQgc2h1dGlsLndoaWNoKCJwYXBlcnMiKTogICAjIHNob3cgdGhlIHJlc3VsdAogICAgICAgIHN1YnByb2Nlc3MuUG9wZW4oWyJwYXBlcnMiLCBvdXRdLCBzdGRvdXQ9c3VicHJvY2Vzcy5ERVZOVUxMLCBzdGRlcnI9c3VicHJvY2Vzcy5ERVZOVUxMLCBzdGFydF9uZXdfc2Vzc2lvbj1UcnVlKQoKCmRlZiBtYWluKCk6CiAgICBhcCA9IGFyZ3BhcnNlLkFyZ3VtZW50UGFyc2VyKHByb2c9InNpZ24tcGRmIiwgZGVzY3JpcHRpb249IlNpZ24gYSBQREYgd2l0aCB0aGUgRFNDIFVTQiB0b2tlbi4iKQogICAgYXAuYWRkX2FyZ3VtZW50KCJwZGYiLCBuYXJncz0iPyIsIGhlbHA9InRoZSBQREYgKGFza2VkIGZvciBpbiBhIGZpbGUgY2hvb3NlciB3aGVuIHN0YXJ0ZWQgZnJvbSB0aGUgYXBwIG1lbnUpIikKICAgIGFwLmFkZF9hcmd1bWVudCgiLW8iLCAiLS1vdXRwdXQiLCBoZWxwPSJvdXRwdXQgZmlsZSAoZGVmYXVsdDogPG5hbWU+X3NpZ25lZC5wZGYpIikKICAgIGFwLmFkZF9hcmd1bWVudCgiLS1yZWFzb24iLCBkZWZhdWx0PU5vbmUpCiAgICBhcC5hZGRfYXJndW1lbnQoIi0tbG9jYXRpb24iLCBkZWZhdWx0PU5vbmUpCiAgICBhcC5hZGRfYXJndW1lbnQoIi0tcGFnZSIsIHR5cGU9aW50LCBkZWZhdWx0PTAsIGhlbHA9InBhZ2UgZm9yIHRoZSBib3gsIDEgPSBmaXJzdCAoZGVmYXVsdDogbGFzdCBwYWdlKSIpCiAgICBhcC5hZGRfYXJndW1lbnQoIi0tcG9zIiwgY2hvaWNlcz1bImJyIiwgImJsIiwgInRyIiwgInRsIl0sIGRlZmF1bHQ9ImJyIiwgaGVscD0iY29ybmVyIGZvciB0aGUgYm94IChkZWZhdWx0IGJyKSIpCiAgICBhcC5hZGRfYXJndW1lbnQoIi0taW52aXNpYmxlIiwgYWN0aW9uPSJzdG9yZV90cnVlIiwgaGVscD0ibm8gdmlzaWJsZSBib3giKQogICAgYXAuYWRkX2FyZ3VtZW50KCItLWxpYiIsIGhlbHA9IlBLQ1MjMTEgZHJpdmVyIHRvIHVzZSBpbnN0ZWFkIG9mIHRoZSBhdXRvbWF0aWMgY2hvaWNlIikKICAgIGEgPSBhcC5wYXJzZV9hcmdzKCkKICAgIGlmIG5vdCBhLnBkZjoKICAgICAgICBpZiBub3QgKEdVSSBhbmQgc2h1dGlsLndoaWNoKCJ6ZW5pdHkiKSk6CiAgICAgICAgICAgIGFwLmVycm9yKCJnaXZlIHRoZSBQREYgdG8gc2lnbiIpCiAgICAgICAgciA9IHN1YnByb2Nlc3MucnVuKFsiemVuaXR5IiwgIi0tZmlsZS1zZWxlY3Rpb24iLCAiLS10aXRsZT1DaG9vc2UgdGhlIFBERiB0byBzaWduIiwgIi0tZmlsZS1maWx0ZXI9UERGIHwgKi5wZGYgKi5QREYiXSwKICAgICAgICAgICAgICAgICAgICAgICAgICAgY2FwdHVyZV9vdXRwdXQ9VHJ1ZSwgdGV4dD1UcnVlKQogICAgICAgIGlmIHIucmV0dXJuY29kZSAhPSAwIG9yIG5vdCByLnN0ZG91dC5zdHJpcCgpOgogICAgICAgICAgICBzeXMuZXhpdCgwKQogICAgICAgIGEucGRmID0gci5zdGRvdXQuc3RyaXAoKQoKICAgIHNyYyA9IG9zLnBhdGguYWJzcGF0aChhLnBkZikKICAgIGlmIG5vdCBvcy5wYXRoLmlzZmlsZShzcmMpOgogICAgICAgIGZhaWwoIm5vIHN1Y2ggZmlsZTogIiArIGEucGRmKQogICAgcm9vdCwgXyA9IG9zLnBhdGguc3BsaXRleHQoc3JjKQogICAgb3V0ID0gb3MucGF0aC5hYnNwYXRoKGEub3V0cHV0KSBpZiBhLm91dHB1dCBlbHNlIHJvb3QgKyAiX3NpZ25lZC5wZGYiCiAgICBpZiBvdXQgPT0gc3JjOgogICAgICAgIGZhaWwoInRoZSBvdXRwdXQgbXVzdCBiZSBhIG5ldyBmaWxlLCBub3QgdGhlIG9yaWdpbmFsIikKCiAgICB0ZXN0X3AxMiA9IG9zLmVudmlyb24uZ2V0KCJTSUdOX1BERl9URVNUX1AxMiIpICAgIyBzZWxmLXRlc3Qgb25seTogYSB0aHJvd2F3YXkga2V5IGZpbGUgaW5zdGVhZCBvZiB0aGUgdG9rZW4KICAgIGlmIHRlc3RfcDEyOgogICAgICAgIHNpZ25fZmlsZShhLCBzcmMsIG91dCwgc2lnbmVycy5TaW1wbGVTaWduZXIubG9hZF9wa2NzMTIodGVzdF9wMTIsIHBhc3NwaHJhc2U9Tm9uZSkpCiAgICAgICAgcmV0dXJuIHJlcG9ydChvdXQpCgogICAgbGliID0gZmluZF9kcml2ZXIoYS5saWIpCiAgICBwaW4gPSBhc2tfcGluKCkKICAgIGlmIG5vdCBwaW46CiAgICAgICAgZmFpbCgibm8gUElOIGdpdmVuIikKICAgIHRyeToKICAgICAgICBzZXNzaW9uID0gb3Blbl9wa2NzMTFfc2Vzc2lvbihsaWIsIHVzZXJfcGluPXBpbikKICAgIGV4Y2VwdCBFeGNlcHRpb24gYXMgZTogICMgd3JvbmcgUElOLCBsb2NrZWQgdG9rZW4sIHRva2VuIGJ1c3kKICAgICAgICBmYWlsKCJjb3VsZCBub3Qgb3BlbiB0aGUgdG9rZW46ICIgKyAoc3RyKGUpIG9yIGUuX19jbGFzc19fLl9fbmFtZV9fKSArCiAgICAgICAgICAgICAiXG4oYSB3cm9uZyBQSU4gY291bnRzIHRvd2FyZHMgbG9ja2luZyB0aGUgdG9rZW4gLSBjaGVjayBpdCBiZWZvcmUgdHJ5aW5nIGFnYWluKSIpCiAgICBmaW5hbGx5OgogICAgICAgIHBpbiA9IE5vbmUKCiAgICB0cnk6CiAgICAgICAgaW1wb3J0IHBrY3MxMQogICAgICAgIGZyb20gYXNuMWNyeXB0byBpbXBvcnQgeDUwOQogICAgICAgIGtleV9pZHMgPSB7ay5pZCBmb3IgayBpbiBzZXNzaW9uLmdldF9vYmplY3RzKHtwa2NzMTEuQXR0cmlidXRlLkNMQVNTOiBwa2NzMTEuT2JqZWN0Q2xhc3MuUFJJVkFURV9LRVl9KX0KICAgICAgICBtaW5lID0gW10KICAgICAgICBmb3IgYyBpbiBzZXNzaW9uLmdldF9vYmplY3RzKHtwa2NzMTEuQXR0cmlidXRlLkNMQVNTOiBwa2NzMTEuT2JqZWN0Q2xhc3MuQ0VSVElGSUNBVEV9KToKICAgICAgICAgICAgY2VydCA9IHg1MDkuQ2VydGlmaWNhdGUubG9hZChjW3BrY3MxMS5BdHRyaWJ1dGUuVkFMVUVdKQogICAgICAgICAgICBpZiBjLmlkIGluIGtleV9pZHMgYW5kIG5vdCBpc19jYShjZXJ0KToKICAgICAgICAgICAgICAgIG1pbmUuYXBwZW5kKChjLmlkLCBjZXJ0KSkKICAgICAgICBpZiBub3QgbWluZToKICAgICAgICAgICAgZmFpbCgibm8gc2lnbmluZyBjZXJ0aWZpY2F0ZSB3aXRoIGEgcHJpdmF0ZSBrZXkgb24gdGhpcyB0b2tlbiIpCiAgICAgICAgbWluZS5zb3J0KGtleT1sYW1iZGEgdDogdFsxXS5ub3RfdmFsaWRfYWZ0ZXIsIHJldmVyc2U9VHJ1ZSkgICAgICAjIHNldmVyYWw6IHRoZSBvbmUgdmFsaWQgbG9uZ2VzdAogICAgICAgIGNpZCwgY2VydCA9IG1pbmVbMF0KICAgICAgICBuYW1lID0gY2VydC5zdWJqZWN0Lm5hdGl2ZS5nZXQoImNvbW1vbl9uYW1lIiwgIkRTQyBob2xkZXIiKQogICAgICAgIHNheShmInNpZ25lciAgOiB7bmFtZX0gICh2YWxpZCB1bnRpbCB7Y2VydC5ub3RfdmFsaWRfYWZ0ZXI6JWQtJW0tJVl9KSIpCiAgICAgICAgc2lnbmVyID0gUEtDUzExU2lnbmVyKHNlc3Npb24sIGNlcnRfaWQ9Y2lkLCBrZXlfaWQ9Y2lkLCBvdGhlcl9jZXJ0c190b19wdWxsPU5vbmUpCiAgICAgICAgc2lnbl9maWxlKGEsIHNyYywgb3V0LCBzaWduZXIpCiAgICBmaW5hbGx5OgogICAgICAgIHNlc3Npb24uY2xvc2UoKQogICAgcmVwb3J0KG91dCkKCgppZiBfX25hbWVfXyA9PSAiX19tYWluX18iOgogICAgbWFpbigpCg=="
CCA_ROOT_B64="LS0tLS1CRUdJTiBDRVJUSUZJQ0FURS0tLS0tDQpNSUlGTkRDQ0F4eWdBd0lCQWdJUWRpUXo2OXNtZGxxRllNMEtxQy9oRnpBTkJna3Foa2lHOXcwQkFRc0ZBREE2DQpNUXN3Q1FZRFZRUUdFd0pKVGpFU01CQUdBMVVFQ2hNSlNXNWthV0VnVUV0Sk1SY3dGUVlEVlFRREV3NURRMEVnDQpTVzVrYVdFZ01qQXlNakFlRncweU1qQXlNREl4TWpBME16ZGFGdzAwTWpBeU1ESXhNakEwTXpkYU1Eb3hDekFKDQpCZ05WQkFZVEFrbE9NUkl3RUFZRFZRUUtFd2xKYm1ScFlTQlFTMGt4RnpBVkJnTlZCQU1URGtORFFTQkpibVJwDQpZU0F5TURJeU1JSUNJakFOQmdrcWhraUc5dzBCQVFFRkFBT0NBZzhBTUlJQ0NnS0NBZ0VBdjNFQnVkV0M4SFkwDQpvU3d0SlpDcXBqUVRHcEVld2wzRWREcVVPUlYwcW9GcDc4bWRSL3Z1QVRYSTgzRzduRjlSTHZtTmpnUWdLci9iDQpNeDZnUE80WTU3Yk1qQXNnd0V6bGVGY2xaa2Evc3FjNjhpTjVyUzNodWhyQ1g2TUVJTkx5RE9RNzFNUkE3R0pDDQphTkw2RTNqMTQzOGVUdTAxMW1saWtlWllCZGtodmZwQVZqQ3c5MHc4d2NXRG1xeDY2WTU2MVQvUmlYeXoydUVoDQpCQlpBRDQzZ1Y1OGVYU3RPZU9Ud0F6RVpZTXJtcDIzMkdmbVFLYWJZUmZkSVJ1czFhdnl1R2VhMm5JQ0VzUkhFDQo4TTJ0ZHp3cEdQN29JeTJxSEJGSkorM0F3bXdRQTREam1Ea0p0Q0QrNThhd29oUWF2Uk5ocWpzR0QrWmlmRzNWDQpSNGk2V3JLdjhPV3FaemNaajNnM0VscjUrZlJNbHoxR1Nxa1dQQncxRXY4S1dUSGF6U1VLRjdPTXhtM1h6eVh4DQpRbnc3ZlpGOUdPVnR4M2FkcGZSUHFZR2d0Yk9QMzRFVmt6NHdzSHZOTXJ2VXJZY0t5bWRPcm5rVGpsWDI2ZklIDQpVSnBLR1lrTGs5cTBqaE1OS3M0Um44bGo0cEo3WUYzMy9ORDRianBWMGV4MUVBUXowaVp2VDM3T254Tml1QVovDQorNERqZjA3NVV1TlgyZWNXbmFkT3JOMXI4TkFQYXJaSXdVb1NVbldoVThUcUFXV1JxekZVUkhVWnVPTVFjQTBnDQplZzRjOXpxdEJvVVBndFFrc2JJQUVzRVhtRHVScHdTSUZqRWtLMTFmNUVlbWZtZmRnMzdLeUlqUTY3VFJUbUJBDQora1Q5UTVKSW0vZTdtMUlMZy9IS2NrZ0xVT0NuQU1zQ0F3RUFBYU0yTURRd0R3WURWUjBUQVFIL0JBVXdBd0VCDQovekFSQmdOVkhRNEVDZ1FJVGp0SU5semlYMzB3RGdZRFZSMFBBUUgvQkFRREFnRUdNQTBHQ1NxR1NJYjNEUUVCDQpDd1VBQTRJQ0FRQ2RiRThkMWMxRHlzS3RydFlsQXBZSVhUbFkzTjJYSE5RNmdLb2FWV3NLYTFUSi9vdnJUK0ZWDQozYm1RTGV0M2FTb0VHNnBUZS92TFpTZzhXaUY3Y243V3VGNFhsUVMzeUEyVXU4L2NnL1M0b3dxaFFKcDZLL1hnDQo2VW9TQmFkOUtvZzFIOGRlT2ZWOE5tYjhhODl6QjRZZjgvQWVwSWQrTHIvM0k2TzdpdWIrUFVUMlFCWG5rc2ErDQpjZjB5Zis0OUdoeU1DSUxadmN0TlNRZDRWeHI5RWdSdkJBUlRyQWdOUTlzRU9KNm15T3o0aVRGUjdUMnBJRlA4DQpDcDE1ZThqRVZJMXE0SXVIdTNYbHdKTms5ZjVrM2did3J6b3k5UDVyUDh2b1FVM3U5d2g2MkpaYTlVNjNiK3UvDQpVcjF0c0tiNUx4MFlVZWR0SHZwSWlJUnVyRVB4dW1XMHR3anJ4OFRyQWNYUnJWaVNMN2RzWEFvWUMwZFhvMTU0DQpFRThqQkF6Z0lJdXI3dEppenhnWERFbjRpMnB1OFlkNjE1WU1MOWlpNUJvb0VKMmo2ZlEwbnp5UFJteDFFZ3cyDQpGamxnenpjZWFpNFRVT2NhQ0thYjg2eXl1NU1aSXArQmlQUjg0MG53NU1nZ2JSZ1lIMm5GUkJBNzB0b1ZtNFZGDQpsYlpzM3JlR21hSUNtNFNUNlIzOTVPeFlTMWlZQm01a1htOXRMYjRwa0loVXhya2d5dWl3RStEc1djZUJqSEFZDQphWG5DZ1VHS3RpRzl0ZkJNVXczZkNob1BiOUwxeUtkTm9mM3pYRGRUbG9NcUVwTzRCRnJtamNvOGt0MXYwTFVRDQpQaE5abVFQNG5xZDRIcXgyMzg0blBtV0RYYlErZWVQeXhSdGVZR1kwaEplRExWcHllWUc4VlE9PQ0KLS0tLS1FTkQgQ0VSVElGSUNBVEUtLS0tLQ0K"
pdf_py_ok() { [ -x "$PDF_VENV/bin/python" ] && "$PDF_VENV/bin/python" -I -c 'import pyhanko.sign.pkcs11, pkcs11' >/dev/null 2>&1; }
nss_has_lib() { have modutil && modutil -dbdir "sql:$NSSDB" -list 2>/dev/null | grep -qF "library name: $1"; }
nss_has_cca() { have certutil && certutil -d "sql:$NSSDB" -L 2>/dev/null | grep -Eq '^CCA India 2022[[:space:]]+[^[:space:]]*,[^,]*C[^,]*,'; }
install_pdf_signing() {
    step "PDF signing (sign-pdf, Document Viewer)"
    local v w p11 tmp
    # 1. the signing tool: pyHanko in its own Python environment (from the bundle's wheels when offline)
    mkdir -p "$PDF_VENV" "$(dirname "$PDF_BIN")"
    printf '%s' "$SIGNPDF_B64" | base64 -d > "$PDF_PY.tmp" && [ "$(sha "$PDF_PY.tmp")" = "$SIGNPDF_SHA" ] &&
        mv -f "$PDF_PY.tmp" "$PDF_PY" || { rm -f "$PDF_PY.tmp"; warn "could not write sign_pdf.py"; return 0; }
    if ! pdf_py_ok; then
        [ -x "$PDF_VENV/bin/python" ] || python3 -m venv "$PDF_VENV" >/dev/null 2>&1 ||
            { warn "Python cannot create a virtual environment (Ubuntu: sudo apt install python3-venv) - sign-pdf skipped"; return 0; }
        w=""; [ -n "$PAYLOAD" ] && [ -d "$PAYLOAD/pdf/wheels" ] && w="$PAYLOAD/pdf/wheels"
        if [ -n "$w" ] && "$PDF_VENV/bin/pip" install -q --no-index --find-links "$w" "$PYHANKO_REQ" >/dev/null 2>&1; then
            ok "pyHanko installed from the bundle"
        elif [ "${OPT_DOWNLOAD:-1}" = 1 ] && "$PDF_VENV/bin/pip" install -q "$PYHANKO_REQ" >/dev/null 2>&1; then
            ok "pyHanko installed from PyPI"
        else warn "pyHanko could not be installed (no matching wheels in the bundle and no internet) - sign-pdf will not work yet"; fi
    fi
    printf '#!/usr/bin/env bash\n# Sign a PDF with the DSC USB token - see: sign-pdf --help  (railway-dsc-suite)\nexec "%s/bin/python" -I "%s" "$@"\n' \
        "$PDF_VENV" "$PDF_PY" > "$PDF_BIN"; chmod 755 "$PDF_BIN"
    mkdir -p "$(dirname "$PDF_DESKTOP")"
    cat > "$PDF_DESKTOP" <<EOF
[Desktop Entry]
Type=Application
Name=Sign PDF with DSC
GenericName=Digital signature
Comment=Sign a PDF with your DSC USB token (asks for the token PIN)
Exec=$PDF_BIN %f
TryExec=$PDF_BIN
Icon=application-certificate
Terminal=false
MimeType=application/pdf;
Categories=Office;
Keywords=DSC;sign;signature;PDF;token;eSign;
StartupNotify=false
EOF
    have update-desktop-database && update-desktop-database "$(dirname "$PDF_DESKTOP")" >/dev/null 2>&1
    mkdir -p "$(dirname "$PDF_NAUTILUS")"
    cat > "$PDF_NAUTILUS" <<EOF
#!/usr/bin/env bash
# Files right-click -> Scripts -> Sign PDF with DSC  (railway-dsc-suite)
IFS=\$'\\n'
for f in \$NAUTILUS_SCRIPT_SELECTED_FILE_PATHS; do
  case "\${f,,}" in *.pdf) "$PDF_BIN" "\$f" </dev/null ;; *) zenity --error --no-wrap --text="Not a PDF: \$(basename "\$f")" ;; esac
done
EOF
    chmod 755 "$PDF_NAUTILUS"
    pdf_py_ok && ok "sign-pdf ready: 'sign-pdf FILE.pdf', the app 'Sign PDF with DSC', or Files right-click > Scripts"

    # 2. Document Viewer (Papers/Evince) signs through NSS: the token's driver and the CCA root in ~/.pki/nssdb
    if have certutil && have modutil; then
        mkdir -p "$NSSDB"; [ -f "$NSSDB/cert9.db" ] || certutil -d "sql:$NSSDB" -N --empty-password 2>/dev/null
        if p11=$(find_p11_lib) && [ -n "$p11" ]; then
            if nss_has_lib "$p11"; then ok "token driver already registered for Document Viewer ($p11)"
            elif modutil -dbdir "sql:$NSSDB" -add "DSC token ($(basename "$p11"))" -libfile "$p11" -force >/dev/null 2>&1; then ok "token driver registered for Document Viewer ($p11)"
            else warn "could not register $p11 in $NSSDB"; fi
        fi
        tmp="$(work_tmp)/cca.pem"; printf '%s' "$CCA_ROOT_B64" | base64 -d > "$tmp"
        if [ "$(cert_fp "$tmp")" != "$CCA_ROOT_SHA256" ]; then warn "embedded CCA root does not match its fingerprint - not trusted"
        elif nss_has_cca; then ok "CCA India 2022 root trusted for signatures"
        else certutil -d "sql:$NSSDB" -D -n "CCA India 2022" >/dev/null 2>&1
             certutil -d "sql:$NSSDB" -A -n "CCA India 2022" -t ",C," -i "$tmp" 2>/dev/null &&
                 ok "CCA India 2022 root trusted for signatures (DSC signatures show as trusted)" || warn "could not trust the CCA root"; fi
    else warn "NSS tools (certutil/modutil) missing - Document Viewer cannot see the token"; fi
    if v=$(pdf_viewer); then ok "PDF viewer with signing: $v"
        if p=$(aa_rules_missing); then
            if aa_block_old "$p"; then warn "AppArmor rules for ${p#usr.bin.} are from an older suite version - run: railway-dsc install (asks for sudo)"
            else warn "AppArmor still blocks the token in ${p#usr.bin.} (it would crash on signed PDFs) - run: railway-dsc install"; fi
        fi
    else warn "no Document Viewer (papers/evince) installed - run: railway-dsc install"; fi
    return 0
}

install_eoffice_files() {
    local jar="" jks="" msi
    if [ -n "$PAYLOAD" ] && [ -f "$PAYLOAD/eoffice/$EOFFICE_JAR_NAME" ]; then jar="$PAYLOAD/eoffice/$EOFFICE_JAR_NAME"
    elif msi=$(find_msi) && [ -n "$msi" ]; then
        info "Using the official installer: $msi"
        jar=$(jar_from_msi "$msi") || die "could not extract the 4.1.8 jar from $msi (needs cabextract; file must be the official 4.1.8 x64 MSI)"
    elif [ -f "$EOFFICE_JAR" ]; then jar="$EOFFICE_JAR"
    else
        warn "eOffice signer: no source found. Put 'Digital Signer Service 4.1.8_x64.msi' in ~/Downloads or pass --msi=FILE."
        return 1
    fi
    [ "$(sha "$jar")" = "$EOFFICE_JAR_SHA" ] || die "$jar is not the expected NIC 4.1.8 build (checksum mismatch)"
    mkdir -p "$EOFFICE_DIR" "$EOFFICE_LOGS"
    [ "$jar" = "$EOFFICE_JAR" ] || copy_if_changed "$jar" "$EOFFICE_JAR" 644
    have openssl || die "openssl is needed to verify NIC's certificate (Ubuntu: sudo apt install openssl)"
    jks=$(pick_valid_jks) || die "No currently valid HTTPS certificate for $HOSTS_NAME found. The one inside 4.1.8 expired on 21-06-2026; keep NIC's 7.0.x Linux installer zip in ~/Downloads (it carries the renewed certificate) and run install again."
    copy_if_changed "$jks" "$EOFFICE_JKS" 600
    jks_ca_pem "$EOFFICE_JKS" > "$EOFFICE_CA.new" && [ -s "$EOFFICE_CA.new" ] && copy_if_changed "$EOFFICE_CA.new" "$EOFFICE_CA" 644; rm -f "$EOFFICE_CA.new"
    local p11; p11=$(find_p11_lib || true)
    if [ -n "$p11" ]; then
        printf 'name = DSCToken\nlibrary = %s\n' "$p11" > "$EOFFICE_P11CFG.new"; copy_if_changed "$EOFFICE_P11CFG.new" "$EOFFICE_P11CFG" 644; rm -f "$EOFFICE_P11CFG.new"
    fi
    ok "eOffice signer $EOFFICE_VER in $EOFFICE_DIR (certificate valid until $(date -d "@$(jks_expiry "$EOFFICE_JKS")" +%F))"
}
install_eoffice7_files() {
    local jar p11 tname="Token"
    jar=$(e7_jar_source) || { warn "eOffice signer $E7_VER: no source found. Put NIC's 'DigitalSignerService_7.0.6_Ubuntu_Installer.zip' in ~/Downloads or pass --zip7=FILE."; return 1; }
    mkdir -p "$E7_DIR/conf" "$E7_LOGS"
    [ "$jar" = "$E7_JAR" ] || copy_if_changed "$jar" "$E7_JAR" 644
    p11=$(find_p11_lib || true)
    if [ -n "$p11" ] && ! grep -qs "path=$p11" "$E7_DIR/conf/all_tokens.properties"; then
        [ "$p11" = "$MTOKEN_LIB" ] && tname="mToken"
        [ -f "$E7_DIR/conf/all_tokens.properties" ] && cp -p "$E7_DIR/conf/all_tokens.properties" "$E7_DIR/conf/all_tokens.properties.bak-$(date +%Y%m%d-%H%M%S)"
        printf '1.name=%s\n1.path=%s\n1.status=1\n' "$tname" "$p11" > "$E7_DIR/conf/all_tokens.properties"
        printf 'service.start=false\nservice.locale=en_in\nprocess.type=custom\nselected.token.name=%s\nselected.token.path=%s\nused.token.name=%s\nused.token.path=%s\n' \
            "$tname" "$p11" "$tname" "$p11" > "$E7_DIR/conf/default_token.properties"
        CHANGED=1
    fi
    ok "eOffice signer $E7_VER in $E7_DIR (port $E7_PORT)"
}

# ---- CRIS/IREPS from the vendors' Windows installers + the Linux patch kit (kit/) ----
kit_dir() {                   # the kit shipped next to this script, or the copy kept by an earlier install
    local k
    for k in "${OPT_KIT:-}" "$(dirname "$SELF")/kit" "$KIT_COPY"; do
        [ -n "$k" ] && [ -f "$k/kittool.py" ] && [ -f "$k/cris/recipe.json" ] && { echo "$k"; return 0; }
    done
    return 1
}
recipe_val() { python3 -I -c 'import json,sys; v=json.load(open(sys.argv[1])).get(sys.argv[2]); print(v or "")' "$1" "$2" 2>/dev/null; }
find_vendor_msi() {           # $1 = expected sha256  $2 = name pattern  [$3 = explicit file]
    local f
    [ -n "${3:-}" ] && { [ "$(sha "$3")" = "$1" ] && echo "$3"; return; }
    while IFS= read -r f; do [ "$(sha "$f")" = "$1" ] && { echo "$f"; return 0; }; done < <(
        find "$U_HOME/Downloads" "$U_HOME/Desktop" -maxdepth 4 -type f -iname "$2" 2>/dev/null)
    return 1
}
install_from_kit() {          # $1 = cris|ireps  $2 = destination
    local d="$1" dst="$2" k rec msi aux="" args=()
    k=$(kit_dir) || { warn "$(svc_label "$d"): not installed, and the Linux patch kit (kit/ next to this script) was not found"; return 1; }
    have cabextract || { warn "$(svc_label "$d"): cabextract is needed to unpack the vendor installer (Ubuntu: sudo apt install cabextract)"; return 1; }
    rec="$k/$d/recipe.json"
    local pat='CrisSigner*.msi' opt="${OPT_CRIS_MSI:-}"; [ "$d" = ireps ] && { pat='IREPSSigner*.msi'; opt="${OPT_IREPS_MSI:-}"; }
    msi=$(find_vendor_msi "$(recipe_val "$rec" msi_sha256)" "$pat" "$opt") ||
        { warn "$(svc_label "$d"): put the vendor installer '$(recipe_val "$rec" msi_name)' (the exact version the kit was made for) in ~/Downloads"; return 1; }
    [ -n "$(recipe_val "$rec" aux_msi_sha256)" ] && aux=$(find_vendor_msi "$(recipe_val "$rec" aux_msi_sha256)" 'IREPSSigner*.msi' "${OPT_IREPS_MSI:-}" || true)
    [ -n "$aux" ] && args+=(--aux-msi "$aux")
    [ "${OPT_DOWNLOAD:-1}" = 1 ] || args+=(--offline)
    info "Building $(svc_label "$d") from $(basename "$msi")${aux:+ + $(basename "$aux")} and the Linux patch kit ..."
    python3 -I "$k/kittool.py" apply --kit "$k/$d" --msi "$msi" "${args[@]}" --dest "$dst" 2>&1 | sed 's/^/    /'
    [ "${PIPESTATUS[0]}" = 0 ] || { warn "$(svc_label "$d"): building from the installer failed"; return 1; }
    if [ "$k" != "$KIT_COPY" ]; then rm -rf "$KIT_COPY.tmp"; cp -a "$k" "$KIT_COPY.tmp" && rm -rf "$KIT_COPY" && mv "$KIT_COPY.tmp" "$KIT_COPY"; fi
    CHANGED=1
}

install_app_files() {         # $1 = cris|ireps
    local d="$1" dst="$CRIS_DIR" f rel
    [ "$d" = ireps ] && dst="$IREPS_DIR"
    if [ -n "$PAYLOAD" ] && [ -d "$PAYLOAD/$d" ]; then
        mkdir -p "$dst/lib"
        while IFS= read -r f; do
            rel="${f#"$PAYLOAD/$d/"}"
            if [ -L "$f" ]; then [ -e "$dst/$rel" ] || cp -a "$f" "$dst/$rel"
            elif ! { [ -f "$dst/$rel" ] && cmp -s "$f" "$dst/$rel"; }; then
                mkdir -p "$(dirname "$dst/$rel")"; cp -p "$f" "$dst/$rel" || die "cannot write $dst/$rel"; CHANGED=1
            fi
        done < <(find "$PAYLOAD/$d" \( -type f -o -type l \))
        ok "$(svc_label "$d") files in $dst"
    elif svc_files_ok "$d"; then ok "$(svc_label "$d") already installed in $dst"
    elif install_from_kit "$d" "$dst"; then ok "$(svc_label "$d") installed in $dst (vendor installer + Linux patch kit)"
    else warn "$(svc_label "$d"): skipped"; fi
}
install_runtime() {           # $1 = 8|17
    local v="$1" dir="$JRE8_DIR" finder=find_java8
    [ "$v" = 17 ] && { dir="$JRE17_DIR"; finder=find_java_modern; }
    $finder >/dev/null 2>&1 && return 0
    if [ -n "$PAYLOAD" ] && [ -x "$PAYLOAD/jre$v/bin/java" ] && "$PAYLOAD/jre$v/bin/java" -version >/dev/null 2>&1; then
        rm -rf "$dir"; mkdir -p "$(dirname "$dir")"; cp -a "$PAYLOAD/jre$v" "$dir" && ok "Java $v runtime installed from the payload"; return 0
    fi
    if [ "$v" = 17 ] && e7_jre_from_zip "$dir"; then ok "Java 17 runtime installed from NIC's 7.0.6 package"; return 0; fi
    [ "${OPT_DOWNLOAD:-1}" = 1 ] && fetch_temurin "$v" "$dir" && ok "Java $v runtime (Eclipse Temurin) installed in $dir" && return 0
    return 1
}

migrate_legacy() {            # 7.0.6 signer + v4 bridge -> disabled (files kept)
    have_systemd_user || return 0
    local u any=0 prev="$CONF_DIR/previous-units-$(date +%Y%m%d-%H%M%S)"
    for u in $LEGACY_UNITS; do
        [ -f "$UNIT_DIR/$u.service" ] || continue
        if systemctl --user is-enabled --quiet "$u.service" 2>/dev/null || systemctl --user is-active --quiet "$u.service" 2>/dev/null; then
            mkdir -p "$prev"; cp -p "$UNIT_DIR/$u.service" "$prev/"; any=1
            systemctl --user disable --now "$u.service" >/dev/null 2>&1
            ok "Old service $u stopped and disabled (eOffice now uses $EOFFICE_VER on port $EOFFICE_PORT)"
        fi
    done
    [ $any = 1 ] && info "Copies of the old service definitions: $prev"
    return 0
}

conf_set() {                  # $1 = key  $2 = value  (suite.conf)
    mkdir -p "$CONF_DIR"; touch "$CONF_FILE"
    if grep -q "^$1=" "$CONF_FILE"; then sed -i "s|^$1=.*|$1=$2|" "$CONF_FILE"; else printf '%s=%s\n' "$1" "$2" >> "$CONF_FILE"; fi
}
ask_eoffice() {               # interactive choice when nothing was chosen yet
    local a
    echo >&2
    echo "${B}Which eOffice DSC signer do you need?${N}" >&2
    echo "  1) $EOFFICE_VER  - portals still set to signer 4.1 (port $EOFFICE_PORT), e.g. Railway eOffice  [default]" >&2
    echo "  2) $E7_VER  - portals that ask for the 7.x signer (port $E7_PORT)" >&2
    echo "  3) both   - run both side by side (different ports, no conflict)" >&2
    echo "  Not sure? Choose 3. A portal using the wrong one says 'Unable to connect with DSC service'" >&2
    echo "  or 'Mismatch in DSC version'. Change later with: railway-dsc install --eoffice=4|7|both" >&2
    read -r -p "Choice [1]: " a </dev/tty || a=""
    case "$a" in 2|7*) echo 7;; 3|b*) echo both;; *) echo 4;; esac
}

cmd_install() {
    local no_root=0 ui_scale="" pin_scale="" a opt_eoffice="" opt_pdf=""
    OPT_MSI=""; OPT_ZIP7=""; OPT_DOWNLOAD=1; OPT_CRIS_MSI=""; OPT_IREPS_MSI=""; OPT_KIT=""; OPT_EPASS_ZIP=""
    for a in "$@"; do case "$a" in
        --no-root) no_root=1;; --ui-scale=*) ui_scale="${a#*=}";; --pin-scale=*) pin_scale="${a#*=}";;
        --msi=*) OPT_MSI="${a#*=}";; --zip7=*) OPT_ZIP7="${a#*=}";; --no-download) OPT_DOWNLOAD=0;;
        --cris-msi=*) OPT_CRIS_MSI="${a#*=}";; --ireps-msi=*) OPT_IREPS_MSI="${a#*=}";; --kit=*) OPT_KIT="${a#*=}";;
        --epass-zip=*) OPT_EPASS_ZIP="${a#*=}";;
        --no-pdf) opt_pdf=no;; --pdf) opt_pdf=yes;;
        --eoffice=*) opt_eoffice="${a#*=}"
            case "$opt_eoffice" in 4|4.1*|7|7.0*|both|all) ;; *) die "--eoffice must be 4, 7 or both";; esac;;
        *) die "unknown option $a";; esac; done
    if [ -n "$opt_eoffice" ]; then
        case "$opt_eoffice" in 4*) DSC_EOFFICE=4;; 7*) DSC_EOFFICE=7;; *) DSC_EOFFICE=both;; esac
    elif ! grep -qs '^DSC_EOFFICE=' "$CONF_FILE"; then
        if [ -t 0 ] && [ -t 1 ] && [ "${RDSC_TEST_NOSTART:-}" != 1 ]; then DSC_EOFFICE=$(ask_eoffice); else DSC_EOFFICE=4; fi
    fi
    DSC_EOFFICE="${DSC_EOFFICE:-4}"
    DSC_PDF=$(sed -n 's/^DSC_PDF=//p' "$CONF_FILE" 2>/dev/null | tail -1); [ -n "$opt_pdf" ] && DSC_PDF="$opt_pdf"
    case "${DSC_PDF:-yes}" in no|0|off|false) DSC_PDF=no;; *) DSC_PDF=yes;; esac
    [ "$(id -u)" -ne 0 ] || die "Run this as your normal desktop user, not root. It will ask for sudo when needed."
    echo "${B}Railway DSC Signer Suite $SUITE_VERSION - install / repair${N}  (eOffice signer: $(eoffice_desc))"
    case "$(uname -m)" in x86_64) ;; *) warn "CPU $(uname -m): the bundled Java and the mToken driver are x86_64 only; a system or downloaded Java and your token vendor's driver for this CPU are needed.";; esac
    locate_payload

    # ---- does anything need root? ---------------------------------------
    local nj8=0 nj17=0 ncab=0 reasons=()
    if svc_wanted eoffice && ! find_java8 >/dev/null && ! { [ -n "$PAYLOAD" ] && [ -x "$PAYLOAD/jre8/bin/java" ]; }; then nj8=1; reasons+=("Java 8 runtime"); fi
    if ! find_java_modern >/dev/null && ! { [ -n "$PAYLOAD" ] && [ -x "$PAYLOAD/jre17/bin/java" ]; }; then nj17=1; reasons+=("Java 17 runtime"); fi
    local kit_needed=0; for a in cris ireps; do { [ -n "$PAYLOAD" ] && [ -d "$PAYLOAD/$a" ]; } || svc_files_ok "$a" || kit_needed=1; done
    if ! have cabextract && { [ $kit_needed = 1 ] || { svc_wanted eoffice && ! { [ -n "$PAYLOAD" ] && [ -f "$PAYLOAD/eoffice/$EOFFICE_JAR_NAME" ]; } && [ ! -f "$EOFFICE_JAR" ]; }; }; then ncab=1; reasons+=("cabextract"); fi
    have python3 || reasons+=("python3")
    have certutil || reasons+=("certutil (NSS tools)")
    have unzip || reasons+=("unzip")
    xlibs_missing && reasons+=("X11/font libraries for Java")
    [ ! -f "$MTOKEN_LIB" ] && [ -n "$PAYLOAD" ] && [ -f "$PAYLOAD/drivers/libcryptoid_pkcs11.so" ] && [ "$(uname -m)" = x86_64 ] && reasons+=("mToken driver")
    [ -d /etc/udev/rules.d ] && ! udev_rule_present && reasons+=("udev rule for DSC tokens")
    hosts_ok || reasons+=("/etc/hosts entry")
    hook_active && reasons+=("disable the vendor autostart hook")
    smartcard_stack_ok || reasons+=("smart-card service + OpenSC (ePass2003 and smart cards)")
    local epass=""                     # Feitian's driver: when asked for, or when an ePass2003 is plugged in
    if [ -n "$OPT_EPASS_ZIP" ] || plugged_vids | grep -qx 096e; then epass=$(find_epass_zip || true); fi
    [ -n "$OPT_EPASS_ZIP" ] && [ -z "$epass" ] && die "--epass-zip: file not found: $OPT_EPASS_ZIP"
    [ -n "$epass" ] && [ ! -f "$CASTLE_LIB" ] && reasons+=("Feitian ePass2003 driver")
    local npdf=0
    if [ "$DSC_PDF" = yes ]; then
        pdf_viewer >/dev/null || { npdf=1; reasons+=("Document Viewer (Papers) for PDF signing"); }
        { pdf_py_ok || venv_ok; } || { npdf=1; reasons+=("Python venv for sign-pdf"); }
        aa_rules_missing >/dev/null && { npdf=1; reasons+=("AppArmor: let Document Viewer use the token"); }
    fi

    if [ ${#reasons[@]} -gt 0 ] && [ $no_root = 0 ] && [ "${RDSC_TEST_NOROOT:-}" != 1 ]; then
        step "Administrator rights needed for: $(IFS=,; echo "${reasons[*]}" | sed 's/,/, /g')"
        if have sudo; then
            sudo bash "$SELF" __root "$(id -un)" "${PAYLOAD:-/nonexistent}" "$nj8" "$nj17" "$ncab" "$epass" "$npdf" || warn "system-level setup reported a problem - continuing"
        else
            warn "sudo is not installed. Run this as root, then run install again:"
            info "su -c 'bash $SELF __root $(id -un) ${PAYLOAD:-/nonexistent} $nj8 $nj17 $ncab \"$epass\" $npdf'"
            [ -z "$PAYLOAD_TMP" ] || { PAYLOAD_TMP=""; info "(payload kept in $PAYLOAD for that command)"; }
            exit 1
        fi
    elif [ ${#reasons[@]} -gt 0 ]; then
        warn "Skipped (--no-root): ${reasons[*]}"
    else
        ok "Nothing needs administrator rights"
    fi
    have python3 || die "python3 is required and could not be installed"

    # ---- runtimes and program files ------------------------------------------
    step "Java runtimes"
    if svc_wanted eoffice; then
        install_runtime 8 && ok "eOffice $EOFFICE_VER -> Java 8: $(find_java8)" || warn "No Java 8 runtime - the eOffice $EOFFICE_VER signer cannot start (Ubuntu: sudo apt install openjdk-8-jre)"
    fi
    install_runtime 17 && ok "CRIS/IREPS$(svc_wanted eoffice7 && echo "/eOffice $E7_VER") -> Java $(java_major "$(find_java_modern)"): $(find_java_modern)" || warn "No Java 11+ runtime - CRIS/IREPS cannot start (Ubuntu: sudo apt install openjdk-17-jre)"

    step "Program files"
    CHANGED=0
    mkdir -p "$CONF_DIR" "$SHARE_DIR" "$STATE_DIR"
    if [ ! -f "$CONF_FILE" ]; then
        cat > "$CONF_FILE" <<EOF
# Railway DSC Signer Suite settings.  After editing:  railway-dsc install
# Size of the CRIS/IREPS windows: auto = follow the desktop, or a number (1, 1.5, 2).
DSC_UI_SCALE=${ui_scale:-auto}
# Size of the eOffice 4.1.8 PIN window: auto = same as above, or a number (1.5 = 150%).
DSC_EOFFICE_SCALE=${pin_scale:-auto}
# Look of the CRIS/IREPS windows: native = desktop GTK theme, metal = Java default.
DSC_LOOK=native
# eOffice signer version(s): 4 (= 4.1.8, port 55101), 7 (= 7.0.6, port 55103) or both
DSC_EOFFICE=$DSC_EOFFICE
# Token driver (PKCS#11 library). Leave empty to auto-detect.
P11_LIB=""
# Force a particular Java (leave empty to auto-detect).
JAVA8=""
JAVA17=""
# PDF signing with the token (sign-pdf, Document Viewer): yes or no
DSC_PDF=$DSC_PDF
EOF
    else
        [ -n "$ui_scale" ] && conf_set DSC_UI_SCALE "$ui_scale"
        [ -n "$pin_scale" ] && conf_set DSC_EOFFICE_SCALE "$pin_scale"
    fi
    conf_set DSC_EOFFICE "$DSC_EOFFICE"
    conf_set DSC_PDF "$DSC_PDF"
    # shellcheck disable=SC1090
    . "$CONF_FILE"
    svc_wanted eoffice  && { install_eoffice_files  || true; }
    svc_wanted eoffice7 && { install_eoffice7_files || true; }
    install_app_files cris
    install_app_files ireps
    SVCS="$(present_svcs)"
    [ -n "$SVCS" ] || die "Nothing to run: no signer program files are installed."
    local p11; p11=$(find_p11_lib || true)
    [ -n "$p11" ] && ok "Token driver: $p11" || warn "No PKCS#11 token driver found. Install your token vendor's Linux driver, then run: railway-dsc install"

    # ---- self-healing layer ---------------------------------------------------
    step "Services and watchdog"
    local before after u
    before=$(cat "$LAUNCH" "$UNIT_DIR"/eofficesigner418.service "$UNIT_DIR"/crissigner.service "$UNIT_DIR"/irepssigner.service 2>/dev/null | sha256sum)
    for u in eofficesigner418 crissigner irepssigner; do
        if [ -f "$UNIT_DIR/$u.service" ] && ! grep -qs 'railway-dsc-suite' "$UNIT_DIR/$u.service"; then
            local prev="$CONF_DIR/previous-units-$(date +%Y%m%d)"; mkdir -p "$prev"; cp -p "$UNIT_DIR/$u.service" "$prev/"
            info "Previous $u.service saved in $prev"
        fi
    done
    write_probe; write_laf_jar; write_scale_jar; write_launcher; install_self
    if [ "${RDSC_TEST_NOSTART:-}" = 1 ]; then
        write_units; info "(test mode: services not enabled or started)"
    elif have_systemd_user; then
        migrate_legacy
        for a in eoffice eoffice7; do         # the eOffice version not chosen: stop it, keep its files
            svc_wanted "$a" && continue
            if [ -f "$UNIT_DIR/$(svc_unit "$a").service" ]; then
                systemctl --user disable --now "$(svc_unit "$a").service" >/dev/null 2>&1
                rm -f "$UNIT_DIR/$(svc_unit "$a").service"; ok "$(svc_label "$a") switched off (files kept)"
            fi
        done
        write_units
        systemctl --user daemon-reload
        # shellcheck disable=SC2046
        systemctl --user enable $(unit_names) >/dev/null 2>&1
        rm -f "$AUTOSTART"
        ok "systemd user services + watchdog timer enabled"
    else
        mkdir -p "$(dirname "$AUTOSTART")"
        printf '[Desktop Entry]\nType=Application\nName=Railway DSC signer supervisor\nExec=%s supervise\nX-GNOME-Autostart-enabled=true\nNoDisplay=true\n' "$BIN" > "$AUTOSTART"
        ok "No systemd user session here: supervisor registered in desktop autostart"
    fi
    after=$(cat "$LAUNCH" "$UNIT_DIR"/eofficesigner418.service "$UNIT_DIR"/crissigner.service "$UNIT_DIR"/irepssigner.service 2>/dev/null | sha256sum)
    [ "$before" = "$after" ] || CHANGED=1
    refresh_keep
    ok "Repair copies stored ($(wc -l < "$MANIFEST") files, $(du -sh "$KEEP_DIR" | cut -f1))"
    trust_certs
    [ "$DSC_PDF" = yes ] && install_pdf_signing
    [ "${RDSC_TEST_NOSTART:-}" = 1 ] && return 0

    # ---- start and verify -----------------------------------------------------
    step "Starting services"
    local s
    rm -f "$STATE_DIR/stopped"
    if have_systemd_user; then
        for s in $SVCS; do
            if [ "$CHANGED" = 1 ] || ! svc_active "$s"; then systemctl --user restart "$(svc_unit "$s").service"; fi
        done
        systemctl --user restart railway-dsc-heal.timer
    else
        ensure_supervisor
    fi
    info "Waiting for the signers to come up ..."
    local i=0 allok=0
    while [ $i -lt 30 ]; do
        allok=1; for s in $SVCS; do probe "$s" || allok=0; done
        [ $allok = 1 ] && break; sleep 3; i=$((i+1))
    done
    cmd_status
    local rc=$?
    echo
    if [ $rc = 0 ]; then ok "Done. Log out of the web portals and back in so they find the signers. Check any time: ${B}railway-dsc doctor${N}"
    else warn "Installed, but something is not healthy yet - see above, or run: railway-dsc doctor"; fi
    case ":$PATH:" in *":$U_HOME/.local/bin:"*) ;; *) info "($U_HOME/.local/bin is not in PATH yet - log out and in, or call $BIN directly)";; esac
    return $rc
}

# ===================================================================== heal ===
restore_files() {             # prints the services whose files were repaired
    [ -f "$MANIFEST" ] || return 0
    local h f cur
    while read -r h f; do
        [ -n "$f" ] || continue
        cur=$(sha "$f")
        [ "$cur" = "$h" ] && continue
        if [ -f "$KEEP_DIR/$h" ] && [ "$(sha "$KEEP_DIR/$h")" = "$h" ]; then
            mkdir -p "$(dirname "$f")"
            [ -f "$f" ] && mv -f "$f" "$f.damaged-$(date +%Y%m%d-%H%M%S)"
            if cp -p "$KEEP_DIR/$h" "$f"; then
                hlog "REPAIRED file $f (was ${cur:-missing})"
                case "$f" in
                    "$EOFFICE_DIR"/*) echo eoffice;; "$E7_DIR"/*) echo eoffice7;; "$CRIS_DIR"/*) echo cris;; "$IREPS_DIR"/*) echo ireps;;
                    "$LAUNCH") echo "$SVCS";;
                esac
            else hlog "ERROR could not restore $f"; fi
        else
            hlog "ERROR $f is damaged and no good repair copy exists - run: railway-dsc install"
        fi
    done < "$MANIFEST"
}

heal_once() {
    local dry="${1:-0}" s repaired
    mkdir -p "$STATE_DIR"
    [ -f "$STATE_DIR/stopped" ] && return 0      # user ran "railway-dsc stop"
    # 1. program files
    if [ "$dry" = 0 ]; then repaired=$(restore_files | tr '\n' ' '); else repaired=""; fi
    if have_systemd_user; then
        # 2. service definitions
        local missing=0 u
        for s in $SVCS; do [ -f "$UNIT_DIR/$(svc_unit "$s").service" ] || missing=1; done
        [ -f "$UNIT_DIR/railway-dsc-heal.timer" ] || missing=1
        if [ $missing = 1 ] && [ "$dry" = 0 ]; then
            write_units; systemctl --user daemon-reload
            # shellcheck disable=SC2046
            systemctl --user enable $(unit_names) >/dev/null 2>&1
            hlog "REPAIRED missing service definitions"
        fi
        # 3. the old 7.0.6 signer / v4 bridge must not come back (the bridge steals port 55101)
        for u in $LEGACY_UNITS; do
            if systemctl --user is-active --quiet "$u.service" 2>/dev/null; then
                if [ "$dry" = 0 ]; then systemctl --user disable --now "$u.service" >/dev/null 2>&1; hlog "DISABLED legacy service $u"
                else echo "would disable legacy service $u"; fi
            fi
        done
        # 4. duplicate eOffice signer instances started outside the service
        local main p pat
        for s in $SVCS; do
            case "$s" in eoffice) pat='DigitalSignerService4[.]1[.]8[.]jar';; eoffice7) pat='DigitalSignerService-7[.]0[.]6[.]jar';; *) continue;; esac
            main=$(svc_pid "$s")
            for p in $(pgrep -u "$(id -u)" -f "$pat" 2>/dev/null); do
                [ "$p" = "$main" ] && continue
                grep -qs "$(svc_unit "$s").service" "/proc/$p/cgroup" && continue
                if [ "$dry" = 0 ]; then kill "$p" 2>/dev/null && hlog "REMOVED duplicate $(svc_label "$s") instance pid $p"
                else echo "would remove duplicate $(svc_label "$s") pid $p"; fi
            done
        done
    fi
    # 5. liveness
    for s in $SVCS; do
        local why="" cnt=0
        case " $repaired " in *" $s "*) why="program file repaired";; esac
        if [ -z "$why" ]; then
            if ! svc_active "$s"; then why="not running"
            elif [ "$(svc_age "$s")" -lt 60 ]; then rm -f "$STATE_DIR/fail.$s"; continue      # still starting
            elif probe "$s"; then rm -f "$STATE_DIR/fail.$s"; continue
            else
                cnt=$(( $(cat "$STATE_DIR/fail.$s" 2>/dev/null || echo 0) + 1 ))
                if [ "$cnt" -lt 2 ]; then
                    [ "$dry" = 0 ] && echo "$cnt" > "$STATE_DIR/fail.$s"
                    hlog "NOTICE $(svc_label "$s") did not answer on port $(svc_port "$s") (strike $cnt of 2)"
                    continue
                fi
                why="running but not answering on port $(svc_port "$s")"
            fi
        fi
        if [ "$dry" = 0 ]; then
            rm -f "$STATE_DIR/fail.$s"
            svc_restart "$s"; hlog "RESTARTED $(svc_label "$s"): $why"
        else echo "would restart $(svc_label "$s"): $why"; fi
    done
    # 6. log growth
    local lf
    for lf in "$EOFFICE_LOGS/output.log" "$EOFFICE_LOGS/error.log" "$E7_LOGS/output.log" "$E7_LOGS/errorOutput.log" "$HEAL_LOG"; do
        if [ -f "$lf" ] && [ "$(stat -c %s "$lf" 2>/dev/null || echo 0)" -gt 20971520 ] && [ "$dry" = 0 ]; then
            tail -c 2097152 "$lf" > "$lf.1" 2>/dev/null && : > "$lf" && hlog "ROTATED $lf"
        fi
    done
    # 7. things only an administrator can fix: report, once a day
    local drift=""
    hook_active && drift="$drift vendor-autostart-hook-is-back"
    hosts_ok || drift="$drift hosts-entry-missing"
    svc_files_ok eoffice && ! jks_valid "$EOFFICE_JKS" && drift="$drift eoffice-https-certificate-expired"
    if [ -n "$drift" ] && [ "$dry" = 0 ]; then
        local today; today=$(date +%F)
        if [ "$(cat "$STATE_DIR/drift.day" 2>/dev/null)" != "$today" ]; then
            echo "$today" > "$STATE_DIR/drift.day"
            hlog "NEEDS ADMIN:$drift - fix with: railway-dsc install"
            have notify-send && notify-send "Railway DSC signers" "Something needs repair. Run: railway-dsc doctor" 2>/dev/null
        fi
    fi
    return 0
}

cmd_heal() {
    local dry=0; [ "${1:-}" = "--dry-run" ] && dry=1
    mkdir -p "$STATE_DIR"
    if have flock && [ $dry = 0 ]; then exec 9>"$STATE_DIR/heal.lock"; flock -n 9 || exit 0; fi
    heal_once "$dry"
}

cmd_supervise() {             # fallback for systems without a systemd user session
    mkdir -p "$STATE_DIR"
    if have flock; then exec 8>"$STATE_DIR/supervisor.lock"; flock -n 8 || exit 0; fi
    echo $$ > "$STATE_DIR/supervisor.pid"
    trap 'for s in $SVCS; do p=$(cat "$STATE_DIR/pid.$s" 2>/dev/null); [ -n "$p" ] && kill "$p" 2>/dev/null; done; exit 0' TERM INT
    local n=0 s p
    while :; do
        for s in $SVCS; do
            [ -f "$STATE_DIR/stopped" ] && continue
            p=$(cat "$STATE_DIR/pid.$s" 2>/dev/null)
            if [ -z "$p" ] || ! kill -0 "$p" 2>/dev/null; then
                "$LAUNCH" "$s" >> "$SHARE_DIR/$s.log" 2>&1 &
                echo $! > "$STATE_DIR/pid.$s"
            fi
        done
        sleep 20 & wait $!
        n=$((n+1)); [ $((n % 9)) -eq 0 ] && [ ! -f "$STATE_DIR/stopped" ] && heal_once 0
    done
}

# =================================================================== status ===
cmd_status() {
    local rc=0 s state
    echo; echo "${B}Railway DSC Signer Suite $SUITE_VERSION - status${N}"
    [ -n "$SVCS" ] || { fail "No signer installed. Run: railway-dsc install"; return 1; }
    for s in $SVCS; do
        if ! svc_active "$s"; then state="${R}not running${N}"; rc=1
        elif probe "$s"; then state="${G}healthy${N}"
        else state="${Y}running, not answering yet${N}"; rc=1; fi
        printf '  %-30s port %-6s %s\n' "$(svc_label "$s")" "$(svc_port "$s")" "$state"
    done
    if have_systemd_user; then
        if systemctl --user is-active --quiet railway-dsc-heal.timer; then printf '  %-30s %s\n' "Watchdog" "${G}active${N} (every 3 minutes)"
        else printf '  %-30s %s\n' "Watchdog" "${R}not active${N}"; rc=1; fi
    else
        local p; p=$(cat "$STATE_DIR/supervisor.pid" 2>/dev/null)
        if [ -n "$p" ] && kill -0 "$p" 2>/dev/null; then printf '  %-30s %s\n' "Supervisor" "${G}active${N}"
        else printf '  %-30s %s\n' "Supervisor" "${R}not running${N}"; rc=1; fi
    fi
    local p11 tk; [ -f "$CONF_FILE" ] && . "$CONF_FILE"; p11=$(find_p11_lib || true)
    printf '  %-30s %s\n' "Token driver" "${p11:-${Y}none found${N}}"
    tk=$(tokens_plugged | cut -d: -f2 | paste -sd, -)
    if [ -n "$tk" ]; then printf '  %-30s %s\n' "USB token" "${G}$tk${N}"
    else printf '  %-30s %s\n' "USB token" "${Y}not detected${N} (plug it in before signing)"; fi
    hosts_ok || { printf '  %-30s %s\n' "/etc/hosts entry" "${R}missing; run: railway-dsc install${N}"; rc=1; }
    if [ -f "$HEAL_LOG" ]; then
        echo "  Last watchdog actions:"; grep -E 'RESTARTED|REPAIRED|REMOVED|DISABLED|ERROR|NEEDS ADMIN' "$HEAL_LOG" | tail -n 4 | sed 's/^/    /'
    fi
    return $rc
}

# =================================================================== doctor ===
D_FAILS=0; D_WARNS=0
d_ok()   { printf '  %s %s\n' "${G}ok  ${N}" "$*"; }
d_warn() { printf '  %s %s\n' "${Y}warn${N}" "$*"; D_WARNS=$((D_WARNS+1)); }
d_fail() { printf '  %s %s\n' "${R}FAIL${N}" "$*"; D_FAILS=$((D_FAILS+1)); }
d_fix()  { printf '         %s\n' "-> $*"; }
d_head() { echo; echo "${B}$*${N}"; }

cmd_doctor() {
    echo "${B}Railway DSC Signer Suite $SUITE_VERSION - doctor${N}  ($(date '+%F %T'))"
    [ -f "$CONF_FILE" ] && . "$CONF_FILE"
    local s j f u o e

    d_head "System"
    if [ -f /etc/os-release ]; then . /etc/os-release; d_ok "${PRETTY_NAME:-unknown Linux}, kernel $(uname -r), $(uname -m)"; fi
    case "$(uname -m)" in x86_64) ;; *) d_warn "CPU $(uname -m): the mToken driver and bundled runtimes are x86_64 only";; esac
    if have_systemd_user; then d_ok "systemd user session available"; else d_warn "no systemd user session - the desktop-autostart supervisor is used instead"; fi
    if [ -n "${WAYLAND_DISPLAY:-}" ]; then d_ok "Wayland session (signers use XWayland - fine)"; fi
    if ls /tmp/.X11-unix/X* >/dev/null 2>&1; then d_ok "X display socket present ($(ls /tmp/.X11-unix | tr '\n' ' '))"
    else d_fail "no X display socket - the signers' PIN window cannot open"; d_fix "log in to a graphical desktop session"; fi
    for f in python3 certutil ss unzip; do have "$f" || { d_warn "'$f' missing"; d_fix "railway-dsc install (installs it)"; }; done

    d_head "Java"
    if ! svc_wanted eoffice; then :
    elif j=$(find_java8); then d_ok "Java 8 for eOffice $EOFFICE_VER: $j"
    else d_fail "no Java 8 with GUI libraries (4.1.8 needs exactly Java 8)"; d_fix "Ubuntu: sudo apt install openjdk-8-jre   (or: railway-dsc install, which can download one)"
        ls /usr/lib/jvm/java-8-*/jre/bin/java >/dev/null 2>&1 && d_fix "a headless Java 8 is installed - the full JRE package adds the GUI libraries"; fi
    if j=$(find_java_modern); then d_ok "Java $(java_major "$j") for CRIS/IREPS: $j"
    else d_fail "no Java 11+ with GUI libraries"; d_fix "Ubuntu: sudo apt install openjdk-17-jre"; fi

    d_head "Program files"
    d_ok "eOffice signer chosen: $(eoffice_desc)   (change: railway-dsc install --eoffice=4|7|both)"
    for s in $ALL_SVCS; do
        svc_wanted "$s" || continue
        if svc_files_ok "$s"; then d_ok "$(svc_label "$s") installed"
        else d_warn "$(svc_label "$s") not installed"
            case "$s" in eoffice) d_fix "railway-dsc install   (with 'Digital Signer Service 4.1.8_x64.msi' in ~/Downloads)";;
                         eoffice7) d_fix "railway-dsc install   (with NIC's 7.0.6 Ubuntu installer zip in ~/Downloads)";;
                         *) d_fix "railway-dsc install   (from a .run bundle that contains it)";; esac; fi
    done
    if svc_wanted eoffice7 && [ -f "$E7_JAR" ]; then
        [ "$(sha "$E7_JAR")" = "$E7_JAR_SHA" ] && d_ok "eOffice jar is the genuine NIC 7.0.6 build" || { d_fail "7.0.6 jar checksum mismatch (damaged or patched)"; d_fix "railway-dsc heal"; }
        grep -qs '^1.path=' "$E7_DIR/conf/all_tokens.properties" && d_ok "7.0.6 token list -> $(sed -n 's/^1.path=//p' "$E7_DIR/conf/all_tokens.properties")" || { d_warn "7.0.6 has no token configured"; d_fix "railway-dsc install"; }
    fi
    if svc_wanted eoffice && [ -f "$EOFFICE_JAR" ]; then
        [ "$(sha "$EOFFICE_JAR")" = "$EOFFICE_JAR_SHA" ] && d_ok "eOffice jar is the genuine NIC 4.1.8 build" || { d_fail "eOffice jar checksum mismatch (damaged or not 4.1.8)"; d_fix "railway-dsc heal   (restores from the kept copy)"; }
        [ -f "$EOFFICE_P11CFG" ] && d_ok "pkcs11cfg -> $(sed -n 's/^library *= *//p' "$EOFFICE_P11CFG")" || { d_fail "pkcs11cfg missing - the eOffice signer cannot reach the token"; d_fix "railway-dsc install"; }
    fi
    if [ -f "$MANIFEST" ]; then
        o=0; while read -r e f; do [ "$(sha "$f")" = "$e" ] || o=$((o+1)); done < "$MANIFEST"
        [ $o = 0 ] && d_ok "all $(wc -l < "$MANIFEST") watched files intact" || { d_warn "$o watched file(s) changed or missing"; d_fix "railway-dsc heal"; }
    fi

    d_head "Certificates and browsers"
    if [ -f "$EOFFICE_JKS" ]; then
        e=$(jks_expiry "$EOFFICE_JKS" || true)
        if [ -n "$e" ] && [ "$e" -gt "$(date +%s)" ]; then
            [ $(( (e - $(date +%s)) / 86400 )) -lt 60 ] && d_warn "eOffice HTTPS certificate expires $(date -d "@$e" +%F) - get a newer NIC signer package before then" \
                || d_ok "eOffice HTTPS certificate valid until $(date -d "@$e" +%F)"
        else d_fail "eOffice HTTPS certificate expired - browsers refuse the signer"; d_fix "keep NIC's latest Linux signer zip in ~/Downloads and run: railway-dsc install"; fi
    fi
    if have certutil; then
        local db item name file miss
        while IFS= read -r db; do
            miss=""
            while IFS= read -r item; do
                name="${item%%|*}"; file="${item#*|}"; file="${file%%|*}"
                [ -f "$file" ] || continue
                case "$name" in CrisSigner*)       # Firefox honours a site exception for this self-signed leaf
                    grep -qs '^127\.0\.0\.1:2039' "$db/cert_override.txt" && continue;; esac
                cert_in_db "$db" "$file" "$name" || miss="$miss '$name'"
            done < <(trust_list)
            [ -z "$miss" ] && d_ok "trusted in ${db/#$U_HOME/~}" || { d_warn "${db/#$U_HOME/~} lacks:$miss"; d_fix "railway-dsc trust, restart the browser"
                case "$miss" in *CrisSigner*) [ -f "$db/cert_override.txt" ] || [ -f "$db/prefs.js" ] && d_fix "Firefox: open https://127.0.0.1:2039 once and accept the certificate";; esac; }
        done < <(nss_dbs)
    fi
    [ -d "$U_HOME/snap/firefox" ] && d_ok "Firefox is a snap: fine, it may reach the local signers"

    d_head "Network names and ports"
    if hosts_ok; then d_ok "$HOSTS_NAME -> $(hosts_addr) (loopback)"
    else d_fail "$HOSTS_NAME does not resolve to loopback (eOffice cannot reach the signer)"; d_fix "railway-dsc install   (adds '$HOSTS_ADDR $HOSTS_NAME' to /etc/hosts)"; fi
    for s in $ALL_SVCS; do
        svc_wanted "$s" || continue
        o=$(port_owner "$(svc_port "$s")")
        if [ -n "$o" ]; then
            case "$s:$o" in
                eoffice:*python*) d_fail "port $(svc_port "$s") is held by the old v4 bridge ($o)"; d_fix "railway-dsc install   (disables eofficesigner-proxy)";;
                *) d_ok "port $(svc_port "$s") listening: $o";;
            esac
        else svc_files_ok "$s" && d_warn "nothing listens on port $(svc_port "$s") ($(svc_label "$s"))"; fi
    done
    o=$(port_owner 55100); [ -n "$o" ] && { d_warn "port 55100 is in use ($o): the 4.1.8 signer then refuses to start by itself"; d_fix "stop whatever runs there"; }
    svc_wanted eoffice7 || { o=$(port_owner $E7_PORT); [ -n "$o" ] && d_warn "an eOffice 7.x signer runs on $E7_PORT ($o) although only $EOFFICE_VER is chosen"; }

    d_head "Token"
    local tk t v nm drv l; tk=$(tokens_plugged)
    if [ -n "$tk" ]; then
        for t in $tk; do
            v="${t%%:*}"; nm="${t#*:}"; drv=""
            for l in $(p11_for_vid "$v"); do [ -f "$l" ] && { drv="$l"; break; }; done
            if [ -n "$drv" ]; then d_ok "$nm token -> driver $drv"
                case " $OPENSC_LIBS " in *" $drv "*)
                    if have systemctl && systemctl is-active --quiet pcscd.socket 2>/dev/null || pgrep -x pcscd >/dev/null 2>&1; then d_ok "  (via OpenSC; smart-card service running)"
                    else d_fail "  OpenSC needs the smart-card service"; d_fix "sudo systemctl enable --now pcscd.socket"; fi;; esac
            else d_fail "$nm token plugged in, but its Linux driver is not installed"
                case "$v" in
                    096e) d_fix "railway-dsc install   (adds OpenSC, which supports the ePass2003)"
                          d_fix "or Feitian's own driver: railway-dsc install --epass-zip=ePass2003-Linux-x64.zip";;
                    163c) d_fix "install WatchData's ProxKey Linux driver (support.cryptoplanet.in -> Downloads -> Ubuntu)"
                          d_fix "note: that installer adds a login hook and a world-writable folder; untested with this suite";;
                    0529) d_fix "install SafeNet Authentication Client for Linux (from your token supplier)";;
                    08e6) d_fix "install Thales/Gemalto IDPrime middleware, or: sudo apt install opensc-pkcs11 pcscd";;
                    *)    d_fix "install the token vendor's Linux PKCS#11 driver, then set P11_LIB in $CONF_FILE";;
                esac
            fi
        done
        [ -n "${P11_LIB:-}" ] && d_ok "P11_LIB is set in suite.conf: $P11_LIB (overrides automatic choice)"
    else d_warn "no known DSC token on USB"; d_fix "plug the token in (try another port); 'lsusb' should list it"; fi
    if j=$(find_p11_lib); then
        d_ok "PKCS#11 driver: $j"
        if have ldd; then o=$(ldd "$j" 2>/dev/null | awk '/not found/{print $1}' | paste -sd' ' -); [ -n "$o" ] && { d_fail "driver needs missing libraries: $o"; d_fix "install those packages (Ubuntu: apt-file search <name>)"; }; fi
    else d_fail "no PKCS#11 driver found for any common token"; d_fix "install the token vendor's Linux driver (mToken: libcryptoid_pkcs11.so in /usr/lib)"; fi
    udev_rule_present && d_ok "udev rule for tokens present" || { d_warn "no udev rule - token may need root access"; d_fix "railway-dsc install"; }
    if have systemctl && systemctl is-active --quiet pcscd.socket 2>/dev/null || pgrep -x pcscd >/dev/null 2>&1; then d_ok "pcscd available (smart-card readers)"; fi

    d_head "PDF signing"
    if [ "${DSC_PDF:-yes}" = no ]; then d_ok "switched off (DSC_PDF=no in suite.conf)"
    else
        if o=$(pdf_viewer); then d_ok "Document Viewer: $o"; else d_warn "no PDF viewer that signs (papers/evince)"; d_fix "railway-dsc install"; fi
        if o=$(aa_rules_missing) && aa_block_old "$o"; then d_warn "AppArmor rules for ${o#usr.bin.} are from an older suite version (they work, but allow more than needed)"; d_fix "railway-dsc install   (asks for sudo)"
        elif [ -n "$o" ]; then d_fail "AppArmor blocks the token in ${o#usr.bin.}: it crashes when it opens a signed PDF"; d_fix "railway-dsc install   (adds the USB rules to /etc/apparmor.d/local/$o)"
        elif aa_enabled && [ -n "$(aa_viewer_profiles)" ]; then d_ok "AppArmor lets the viewer use the token"; fi
        if pdf_py_ok && [ -x "$PDF_BIN" ]; then d_ok "sign-pdf ready ($PDF_BIN)"; else d_warn "sign-pdf not installed or pyHanko missing"; d_fix "railway-dsc install"; fi
        if j=$(find_p11_lib) && [ -n "$j" ]; then
            nss_has_lib "$j" && d_ok "token driver registered in ~/.pki/nssdb" || { d_warn "token driver not registered in ~/.pki/nssdb (Document Viewer cannot see the token)"; d_fix "railway-dsc install"; }
        fi
        nss_has_cca && d_ok "CCA India 2022 trusted for signatures" || { d_warn "CCA India 2022 not trusted: signatures show 'untrusted issuer'"; d_fix "railway-dsc install"; }
    fi

    d_head "Services"
    have_systemd_user && for u in $LEGACY_UNITS; do
        systemctl --user is-active --quiet "$u.service" 2>/dev/null && { d_fail "old service $u is running"; d_fix "railway-dsc install   (disables it)"; }
    done
    hook_active && { d_fail "vendor login-shell hook $VENDOR_HOOK is active (starts/kills signers at every login)"; d_fix "railway-dsc install"; }
    for s in $SVCS; do
        if ! svc_active "$s"; then d_fail "$(svc_label "$s") not running"; d_fix "railway-dsc restart; then: railway-dsc logs"
        elif probe "$s"; then d_ok "$(svc_label "$s") answers on port $(svc_port "$s")"
        else d_warn "$(svc_label "$s") running but not answering"; d_fix "railway-dsc heal"; fi
    done
    if have_systemd_user; then systemctl --user is-active --quiet railway-dsc-heal.timer && d_ok "watchdog timer active" || { d_warn "watchdog timer not active"; d_fix "railway-dsc install"; }; fi
    if [ -f "$EOFFICE_LOGS/error.log" ] && grep -q 'AWTError\|Assistive Technology' "$EOFFICE_LOGS/error.log" 2>/dev/null; then
        d_warn "eOffice log shows the Java accessibility crash (old launcher?)"; d_fix "railway-dsc install"
    fi
    if [ -f "$EOFFICE_APPLOGS/app-info.log" ]; then
        o=$(grep -E '\[ERROR\]' "$EOFFICE_APPLOGS/app-info.log" 2>/dev/null | tail -1 | cut -c1-160)
        [ -n "$o" ] && d_warn "last eOffice signer error: $o"
    fi

    echo
    if [ $D_FAILS = 0 ] && [ $D_WARNS = 0 ]; then ok "Everything looks right."
    elif [ $D_FAILS = 0 ]; then warn "$D_WARNS warning(s), no failures."
    else fail "$D_FAILS problem(s), $D_WARNS warning(s). Most are fixed by: railway-dsc install"; fi
    [ $D_FAILS = 0 ]
}

# ================================================================ controls ===
cmd_ctl() {                   # start|stop|restart
    local s
    case "$1" in
        stop)    touch "$STATE_DIR/stopped" 2>/dev/null
                 have_systemd_user && systemctl --user stop railway-dsc-heal.timer 2>/dev/null
                 for s in $SVCS; do svc_stop "$s"; done; ok "All signer services stopped (watchdog paused). Start again with: railway-dsc start";;
        start|restart)
                 rm -f "$STATE_DIR/stopped"
                 if have_systemd_user; then
                     for s in $SVCS; do systemctl --user restart "$(svc_unit "$s").service"; done
                     systemctl --user start railway-dsc-heal.timer
                 else for s in $SVCS; do svc_stop "$s"; done; ensure_supervisor; fi
                 ok "Services (re)started; give them about 15 seconds, then: railway-dsc status";;
    esac
}

cmd_logs() {
    echo "${B}--- watchdog ($HEAL_LOG)${N}"; tail -n 20 "$HEAL_LOG" 2>/dev/null
    echo "${B}--- eOffice signer ($EOFFICE_APPLOGS/app-info.log)${N}"; tail -n 15 "$EOFFICE_APPLOGS/app-info.log" 2>/dev/null | cut -c1-200
    echo "${B}--- eOffice signer errors${N}"; grep -v '^Inside Filter$' "$EOFFICE_LOGS/error.log" 2>/dev/null | tail -n 10 | cut -c1-200
    local s
    if have_systemd_user && have journalctl; then
        for s in cris ireps; do echo "${B}--- $(svc_label "$s")${N}"; journalctl --user -u "$(svc_unit "$s").service" --no-pager -n 12 2>/dev/null | cut -c1-200; done
    else
        for s in cris ireps; do echo "${B}--- $(svc_label "$s")${N}"; tail -n 12 "$SHARE_DIR/$s.log" 2>/dev/null | cut -c1-200; done
    fi
}

cmd_uninstall() {
    local purge=0 s; [ "${1:-}" = "--purge" ] && purge=1
    if have_systemd_user; then
        # shellcheck disable=SC2046
        systemctl --user disable --now $(unit_names) >/dev/null 2>&1
        for s in $ALL_SVCS; do rm -f "$UNIT_DIR/$(svc_unit "$s").service"; done
        rm -f "$UNIT_DIR/railway-dsc-heal.service" "$UNIT_DIR/railway-dsc-heal.timer"
        systemctl --user daemon-reload
    else
        local p; p=$(cat "$STATE_DIR/supervisor.pid" 2>/dev/null); [ -n "$p" ] && kill "$p" 2>/dev/null
        for s in $SVCS; do svc_stop "$s"; done
    fi
    rm -f "$AUTOSTART" "$BIN" "$PDF_BIN" "$PDF_DESKTOP" "$PDF_NAUTILUS"
    if [ $purge = 1 ]; then
        rm -rf "$SHARE_DIR" "$EOFFICE_DIR" "$CRIS_DIR" "$IREPS_DIR" "$CONF_DIR" "$PDF_VENV"
        ok "Services and program files removed. Left in place (need root): $MTOKEN_LIB, $UDEV_RULE, the /etc/hosts line, the AppArmor lines in /etc/apparmor.d/local/ and Document Viewer."
    else
        rm -rf "$KEEP_DIR" "$STATE_DIR" "$LAUNCH" "$PROBE"
        ok "Services and watchdog removed; program files and Java runtimes kept (remove too with: uninstall --purge)."
    fi
}

usage() {
    cat <<EOF
Railway DSC Signer Suite $SUITE_VERSION  -  eOffice (NIC $EOFFICE_VER and/or $E7_VER), CrisSigner, IREPSSigner

  install | repair   install or repair everything; safe to run again at any time
                       --eoffice=4|7|both  eOffice signer: 4 = 4.1.8 (portals set to 4.1),
                                      7 = 7.0.6, both = side by side; asked if not given
                       --msi=FILE     the official "Digital Signer Service 4.1.8_x64.msi"
                                      (default: searched in ~/Downloads, ~/Desktop)
                       --zip7=FILE    NIC's "DigitalSignerService_7.0.6_Ubuntu_Installer.zip"
                       --epass-zip=FILE  Feitian's "ePass2003-Linux-x64.zip": installs its driver
                                      (otherwise ePass2003 tokens use OpenSC, installed automatically)
                       --cris-msi=FILE, --ireps-msi=FILE   the vendors' Windows installers
                                      (default: searched in ~/Downloads); CRIS/IREPS are
                                      built from them with the Linux patch kit (kit/)
                       --ui-scale=N   CRIS/IREPS/7.0.6 window scale (default auto = like the desktop)
                       --pin-scale=N  eOffice 4.1.8 PIN window scale, e.g. 1.5 = 150% (default auto)
                       --no-pdf       leave out PDF signing (Document Viewer + sign-pdf); --pdf adds it back
                       --no-root      skip the steps that need sudo
                       --no-download  never download a Java runtime
  doctor             explain every problem it can find and how to fix it
  status             health of all services, token and watchdog
  heal [--dry-run]   run the watchdog once now
  start|stop|restart control all signer services
  logs               recent watchdog actions and service logs
  trust              (re)add the local signer certificates to browser stores
  pack [FILE]        build a portable installer (.run) from this working machine
  uninstall [--purge]

PDF signing (installed by default):
  sign-pdf FILE.pdf [--reason R] [--location L] [--page N] [--pos br|bl|tr|tl] [--invisible]
  or the app "Sign PDF with DSC" / Files right-click > Scripts, or Document Viewer's own signing.
EOF
}

main() {
    local cmd="${1:-help}"; [ $# -gt 0 ] && shift
    case "$cmd" in supervise|help|-h|--help) ;; *) init_work_tmp;; esac
    case "$cmd" in
        install|repair) cmd_install "$@";;
        doctor)    cmd_doctor;;
        pack)      cmd_pack "$@";;
        status)    cmd_status;;
        heal)      cmd_heal "$@";;
        supervise) cmd_supervise;;
        start|stop|restart) cmd_ctl "$cmd";;
        logs)      cmd_logs;;
        trust)     trust_certs;;
        uninstall) cmd_uninstall "$@";;
        __root)    cmd_root "$@";;
        help|-h|--help) usage;;
        *) usage; exit 2;;
    esac
}
if [ "${RDSC_SOURCE_ONLY:-}" = 1 ]; then return 0 2>/dev/null; fi   # test hook
main "$@"
exit $?
