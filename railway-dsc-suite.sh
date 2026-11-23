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

SUITE_VERSION="4.7.0"
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
    CHAIN_JAR="$SHARE_DIR/chain-fill.jar"
    CA_DIR="$SHARE_DIR/ca"                          # CA certificates for the chain agent; add your own here
    KIT_COPY="$SHARE_DIR/kit"
    DRV_CACHE="$SHARE_DIR/drivers"                  # verified vendor token drivers, <kind>/<lib>
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
udev_rule_current() { [ -f "$UDEV_RULE" ] && [ "$(cat "$UDEV_RULE")" = "$(udev_rule_text)" ]; }   # ours, and lists every token below
udev_rule_text() {
    echo "# Railway DSC suite: give the logged-in desktop user raw USB access to DSC tokens"
    echo "# (drivers such as the Longmai mToken talk to the token over USB, not PC/SC)."
    local t; for t in $TOKEN_VIDS; do
        case "${t%%:*}" in 04e6|072f) continue;; esac       # card readers are handled by pcscd
        echo "SUBSYSTEM==\"usb\", ATTRS{idVendor}==\"${t%%:*}\", TAG+=\"uaccess\"   # ${t#*:}"
    done
    echo "SUBSYSTEM==\"hidraw\", ATTRS{idVendor}==\"338c\", TAG+=\"uaccess\"   # InnaIT-KeyDSC (fingerprint models)"
}
hosts_addr()  { getent hosts "$HOSTS_NAME" 2>/dev/null | awk '{print $1; exit}'; }
hosts_ok()    { case "$(hosts_addr)" in 127.*) return 0;; *) return 1;; esac; }

# USB vendor IDs of common Indian DSC tokens
TOKEN_VIDS="055c:Longmai-mToken 096e:Feitian-ePass2003 2ccf:Hypersecu-HYP2003 338c:InnaIT-KeyDSC 163c:WatchData-ProxKey/TrustKey 0529:SafeNet-eToken 08e6:Gemalto 24dc:Aladdin-JaCarta 1a44:VASCO 04e6:SCM-reader 072f:ACS-reader"
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
VDRV_DIR="/usr/lib/railway-dsc"          # vendor drivers installed by the suite (root-owned, survive ~/Downloads clean-ups)
FEITIAN2_LIB="$VDRV_DIR/feitian/libcastle_v2.so.1.0.0"
HYPERSECU_LIB="$VDRV_DIR/hypersecu/libcastle_v2.so.1.0.0"
INNAIT_LIB="$VDRV_DIR/innait/libInnaITPKCS11Driver.so"
PROXKEY_LIB="/usr/lib/WatchData/ProxKey/lib/libwdpkcs_SignatureP11.so"
PROXKEY_COMPAT="/usr/lib/WatchData/pcsc"   # the ProxKey driver's built-in library path (RPATH)
plugged_vids() { cat /sys/bus/usb/devices/*/idVendor 2>/dev/null | sort -u; }
p11_for_vid() {               # USB vendor id of the plugged token -> its drivers, best first
    case "$1" in
        055c) echo "/usr/lib/libcryptoid_pkcs11.so /usr/lib/libmTokenPKCS11.so";;
        096e) echo "/usr/lib/libcastle.so.1.0.0 $FEITIAN2_LIB /usr/lib/libcastle.so /usr/lib/x86_64-linux-gnu/libcastle.so /usr/lib64/libcastle.so $OPENSC_LIBS";;
        2ccf) echo "$HYPERSECU_LIB /usr/lib/libcastle_v2.so.1.0.0";;     # OpenSC does not drive the HYP2003
        338c) echo "$INNAIT_LIB /opt/Precision_Biometric/InnaITDSC/libraries/libInnaITPKCS11Driver.so";;
        163c) echo "$PROXKEY_LIB /usr/lib/WatchData/TRUSTKEY/lib/libwdpkcs_TRUSTKEY.so /usr/lib/WatchData/eMudhra_3.4.3/lib/libwdpkcs_eMudhra_343.so /usr/lib/WatchData/PROXKey/lib/libwdpkcs.so /usr/lib/libwdpkcs.so";;
        0529) echo "/usr/lib/libeTPkcs11.so /usr/lib/libeToken.so";;
        08e6) echo "/usr/lib/pkcs11/libgtop11dotnet.so /usr/lib/libgtop11dotnet.so $OPENSC_LIBS";;
        24dc) echo "/usr/lib/libjcPKCS11-2.so /usr/lib/x86_64-linux-gnu/libjcPKCS11-2.so";;
        04e6|072f) echo "$OPENSC_LIBS";;                      # smart-card readers
    esac
}
p11_override_fits() {         # $1 = P11_LIB entry: used unless it is another token's driver (P11_FORCE=1 always uses it)
    local v c any=0 kn
    [ "${P11_FORCE:-}" = 1 ] && return 0
    for v in $(plugged_vids); do
        c=" $(p11_for_vid "$v") "; [ "$c" = "  " ] && continue
        any=1; case "$c" in *" $1 "*) return 0;; esac
    done
    [ $any = 0 ] && return 0                         # no known token plugged: nothing to contradict it
    for kn in $TOKEN_VIDS; do case " $(p11_for_vid "${kn%%:*}") " in *" $1 "*) return 1;; esac; done
    return 0                                          # a driver of no known token: the user's own choice
}
find_p11_lib() {              # P11_LIB (suite.conf, if it suits the plugged token) > plugged token's driver > first found
    local l v known=0 c
    for l in ${P11_LIB:-}; do [ -f "$l" ] && p11_override_fits "$l" && { echo "$l"; return 0; }; done
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
# --- Can a signer still open its PIN window? A signer can answer on its port and still be
# useless: Java binds to one X display the first time it draws, and if that display goes away
# (or was never usable) every signing request fails with "Could not initialize class
# sun.awt.X11GraphicsEnvironment" - which eOffice shows as "Response size is heavy or browser
# compatibility issue". Only a fresh start fixes it.
AWT_DEAD='Can.t connect to X11 window server|Could not initialize class sun[.]awt[.]X11GraphicsEnvironment'
x11_ok() { ensure_probe; [ -n "$1" ] && python3 -I "$PROBE" x11 "$1" "${2:-}" >/dev/null 2>&1; }
proc_env() { tr '\0' '\n' < "/proc/$1/environ" 2>/dev/null | sed -n "s/^$2=//p" | head -n 1; }
session_display() {          # the desktop's display, if it accepts us now; prints DISPLAY
    local d="" a=""
    if have_systemd_user; then
        local env; env=$(systemctl --user show-environment 2>/dev/null)
        d=$(printf '%s\n' "$env" | sed -n 's/^DISPLAY=//p'); a=$(printf '%s\n' "$env" | sed -n 's/^XAUTHORITY=//p')
    fi
    [ -n "$d" ] || { d="${DISPLAY:-}"; a="${XAUTHORITY:-}"; }
    x11_ok "$d" "$a" && echo "$d"
}
svc_run_log() {              # this run's log output (everything after the launcher's start marker)
    local s=$1 p=$2 f
    if [ "$s" = eoffice ] || [ "$s" = eoffice7 ]; then
        for f in "$(svc_logdir "$s")"/*.log; do [ -f "$f" ] && after_marker "$p" < "$f"; done
    elif have_systemd_user && have journalctl; then
        journalctl --user -u "$(svc_unit "$s").service" "_PID=$p" -o cat --no-pager 2>/dev/null
    else after_marker "$p" < "$SHARE_DIR/$s.log" 2>/dev/null; fi
}
svc_logdir() { case "$1" in eoffice) echo "$EOFFICE_LOGS";; eoffice7) echo "$E7_LOGS";; esac; }
after_marker() { awk -v m=" pid $1 " 'index($0, "=== railway-dsc: started ") { f = index($0, m) > 0; next } f'; }
svc_gui_problem() {          # prints why the signer cannot show its PIN window; fails if it can
    local p d a; p=$(svc_pid "$1")
    [ -n "$p" ] && [ "$p" != 0 ] && [ -r "/proc/$p/environ" ] || return 1
    d=$(proc_env "$p" DISPLAY); a=$(proc_env "$p" XAUTHORITY)
    if [ -z "$d" ]; then echo "it was started without a display"; return 0; fi
    if ! x11_ok "$d" "$a"; then echo "its display $d is no longer usable"; return 0; fi
    if svc_run_log "$1" "$p" | grep -Eq "$AWT_DEAD"; then echo "Java failed to open its PIN window earlier and cannot recover"; return 0; fi
    return 1
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
usage: probe.py http PORT [ADDR] [HOSTNAME]  |  probe.py ws PORT  |  probe.py x11 DISPLAY [XAUTHORITY]"""
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

def xauth_cookies(path, num):
    """MIT-MAGIC-COOKIE-1 entries for display number `num`, best match first."""
    out = []
    try:
        with open(path, "rb") as f:
            data = f.read()
    except OSError:
        return out
    host = socket.gethostname().encode()
    i = 0
    def field():
        nonlocal i
        n = int.from_bytes(data[i:i + 2], "big")
        v = data[i + 2:i + 2 + n]
        i += 2 + n
        return v
    try:
        while i + 2 <= len(data):
            fam = int.from_bytes(data[i:i + 2], "big"); i += 2
            addr, number, name, cookie = field(), field(), field(), field()
            # an empty number means "any display" (mutter writes its Xwayland cookie that way)
            if name != b"MIT-MAGIC-COOKIE-1" or number not in (num.encode(), b""):
                continue
            rank = (0 if (fam == 256 and addr == host) else 1 if fam == 65535 else 2) + (0 if number else 3)
            out.append((rank, cookie))
    except Exception:
        pass
    return [c for _, c in sorted(out, key=lambda t: t[0])]

def x11_socket(display):
    """Path of a local display socket we may trust with our cookie, else None.
    /tmp/.X11-unix is world-writable and abstract sockets can be taken by anyone, so only
    a filesystem socket owned by root (Xorg) or by us (Xwayland) is accepted; never TCP."""
    host, _, rest = display.rpartition(":")
    num = rest.split(".")[0]
    if host not in ("", "unix") or not num.isdigit():
        return None
    path = "/tmp/.X11-unix/X" + num
    try:
        st = os.lstat(path)
    except OSError:
        return None
    import stat
    if not stat.S_ISSOCK(st.st_mode) or st.st_uid not in (0, os.getuid()):
        return None
    return path

def x11_hello(path, cookie):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(5)
    try:
        s.connect(path)
        name = b"MIT-MAGIC-COOKIE-1" if cookie is not None else b""
        data = cookie or b""
        pad = lambda b: b + b"\0" * (-len(b) % 4)
        s.sendall(b"l\0" + (11).to_bytes(2, "little") + (0).to_bytes(2, "little")
                  + len(name).to_bytes(2, "little") + len(data).to_bytes(2, "little")
                  + b"\0\0" + pad(name) + pad(data))
        reply = s.recv(8)
        return bool(reply) and reply[0] == 1         # 1 = Success, 0 = Failed, 2 = Authenticate
    finally:
        s.close()

def x11(display, xauthority):
    """Can a client with this DISPLAY/XAUTHORITY open the X server? (what a PIN window needs)"""
    path = x11_socket(display or "") if display and ":" in display else None
    if not path:
        return False
    num = display.rpartition(":")[2].split(".")[0]
    cookies = xauth_cookies(xauthority or os.path.expanduser("~/.Xauthority"), num)
    for c in cookies + [None]:          # None: servers without access control (xhost)
        try:
            if x11_hello(path, c):
                return True
        except (OSError, ValueError):
            return False
    return False

if __name__ == "__main__":
    try:
        if sys.argv[1] == "x11":
            sys.exit(0 if x11(sys.argv[2], sys.argv[3] if len(sys.argv) > 3 else "") else 1)
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

# On Linux NIC's signer reads the DSC chain only from the token and drops a certificate whose
# chain is two certificates or shorter (the server then says DSCSN05); Windows fills the chain
# from its certificate store. This agent (source: extras/chain-fill/) gives the eOffice 4.1.8
# signer the CA certificates instead: the bundle below, files in $CA_DIR, and the issuer named in
# each certificate's own "CA Issuers" address. A CA is added only if its signature verifies and
# the chain ends at a pinned CCA India root. The token and NIC's jar are not changed.
CHAIN_JAR_SHA="d086e85358ad349387bc531b9772de9516b9a7c0674c6f6d6eb5d9168338741e"
CHAIN_JAR_B64="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"
CA_BUNDLE_SHA="178e4f7a24631cf9bb72bb34c6f2e1fec48b26633b7261c545efac33bf2e4a18"
# CCA India 2022 + 2022 SPL roots (cca.gov.in) and the eMudhra 2022 CAs (e-mudhra.com/Repository).
CA_BUNDLE_B64="LS0tLS1CRUdJTiBDRVJUSUZJQ0FURS0tLS0tCk1JSUZORENDQXh5Z0F3SUJBZ0lRZGlRejY5c21kbHFGWU0wS3FDL2hGekFOQmdrcWhraUc5dzBCQVFzRkFEQTYKTVFzd0NRWURWUVFHRXdKSlRqRVNNQkFHQTFVRUNoTUpTVzVrYVdFZ1VFdEpNUmN3RlFZRFZRUURFdzVEUTBFZwpTVzVrYVdFZ01qQXlNakFlRncweU1qQXlNREl4TWpBME16ZGFGdzAwTWpBeU1ESXhNakEwTXpkYU1Eb3hDekFKCkJnTlZCQVlUQWtsT01SSXdFQVlEVlFRS0V3bEpibVJwWVNCUVMwa3hGekFWQmdOVkJBTVREa05EUVNCSmJtUnAKWVNBeU1ESXlNSUlDSWpBTkJna3Foa2lHOXcwQkFRRUZBQU9DQWc4QU1JSUNDZ0tDQWdFQXYzRUJ1ZFdDOEhZMApvU3d0SlpDcXBqUVRHcEVld2wzRWREcVVPUlYwcW9GcDc4bWRSL3Z1QVRYSTgzRzduRjlSTHZtTmpnUWdLci9iCk14NmdQTzRZNTdiTWpBc2d3RXpsZUZjbFprYS9zcWM2OGlONXJTM2h1aHJDWDZNRUlOTHlET1E3MU1SQTdHSkMKYU5MNkUzajE0MzhlVHUwMTFtbGlrZVpZQmRraHZmcEFWakN3OTB3OHdjV0RtcXg2Nlk1NjFUL1JpWHl6MnVFaApCQlpBRDQzZ1Y1OGVYU3RPZU9Ud0F6RVpZTXJtcDIzMkdmbVFLYWJZUmZkSVJ1czFhdnl1R2VhMm5JQ0VzUkhFCjhNMnRkendwR1A3b0l5MnFIQkZKSiszQXdtd1FBNERqbURrSnRDRCs1OGF3b2hRYXZSTmhxanNHRCtaaWZHM1YKUjRpNldyS3Y4T1dxWnpjWmozZzNFbHI1K2ZSTWx6MUdTcWtXUEJ3MUV2OEtXVEhhelNVS0Y3T014bTNYenlYeApRbnc3ZlpGOUdPVnR4M2FkcGZSUHFZR2d0Yk9QMzRFVmt6NHdzSHZOTXJ2VXJZY0t5bWRPcm5rVGpsWDI2ZklIClVKcEtHWWtMazlxMGpoTU5LczRSbjhsajRwSjdZRjMzL05ENGJqcFYwZXgxRUFRejBpWnZUMzdPbnhOaXVBWi8KKzREamYwNzVVdU5YMmVjV25hZE9yTjFyOE5BUGFyWkl3VW9TVW5XaFU4VHFBV1dScXpGVVJIVVp1T01RY0EwZwplZzRjOXpxdEJvVVBndFFrc2JJQUVzRVhtRHVScHdTSUZqRWtLMTFmNUVlbWZtZmRnMzdLeUlqUTY3VFJUbUJBCitrVDlRNUpJbS9lN20xSUxnL0hLY2tnTFVPQ25BTXNDQXdFQUFhTTJNRFF3RHdZRFZSMFRBUUgvQkFVd0F3RUIKL3pBUkJnTlZIUTRFQ2dRSVRqdElObHppWDMwd0RnWURWUjBQQVFIL0JBUURBZ0VHTUEwR0NTcUdTSWIzRFFFQgpDd1VBQTRJQ0FRQ2RiRThkMWMxRHlzS3RydFlsQXBZSVhUbFkzTjJYSE5RNmdLb2FWV3NLYTFUSi9vdnJUK0ZWCjNibVFMZXQzYVNvRUc2cFRlL3ZMWlNnOFdpRjdjbjdXdUY0WGxRUzN5QTJVdTgvY2cvUzRvd3FoUUpwNksvWGcKNlVvU0JhZDlLb2cxSDhkZU9mVjhObWI4YTg5ekI0WWY4L0FlcElkK0xyLzNJNk83aXViK1BVVDJRQlhua3NhKwpjZjB5Zis0OUdoeU1DSUxadmN0TlNRZDRWeHI5RWdSdkJBUlRyQWdOUTlzRU9KNm15T3o0aVRGUjdUMnBJRlA4CkNwMTVlOGpFVkkxcTRJdUh1M1hsd0pOazlmNWszZ2J3cnpveTlQNXJQOHZvUVUzdTl3aDYySlphOVU2M2IrdS8KVXIxdHNLYjVMeDBZVWVkdEh2cElpSVJ1ckVQeHVtVzB0d2pyeDhUckFjWFJyVmlTTDdkc1hBb1lDMGRYbzE1NApFRThqQkF6Z0lJdXI3dEppenhnWERFbjRpMnB1OFlkNjE1WU1MOWlpNUJvb0VKMmo2ZlEwbnp5UFJteDFFZ3cyCkZqbGd6emNlYWk0VFVPY2FDS2FiODZ5eXU1TVpJcCtCaVBSODQwbnc1TWdnYlJnWUgybkZSQkE3MHRvVm00VkYKbGJaczNyZUdtYUlDbTRTVDZSMzk1T3hZUzFpWUJtNWtYbTl0TGI0cGtJaFV4cmtneXVpd0UrRHNXY2VCakhBWQphWG5DZ1VHS3RpRzl0ZkJNVXczZkNob1BiOUwxeUtkTm9mM3pYRGRUbG9NcUVwTzRCRnJtamNvOGt0MXYwTFVRClBoTlptUVA0bnFkNEhxeDIzODRuUG1XRFhiUStlZVB5eFJ0ZVlHWTBoSmVETFZweWVZRzhWUT09Ci0tLS0tRU5EIENFUlRJRklDQVRFLS0tLS0KLS0tLS1CRUdJTiBDRVJUSUZJQ0FURS0tLS0tCk1JSUZQRENDQXlTZ0F3SUJBZ0lRWW9LQnh1Nit4ejk0Q0g1ZjlZOUo5REFOQmdrcWhraUc5dzBCQVFzRkFEQSsKTVFzd0NRWURWUVFHRXdKSlRqRVNNQkFHQTFVRUNoTUpTVzVrYVdFZ1VFdEpNUnN3R1FZRFZRUURFeEpEUTBFZwpTVzVrYVdFZ01qQXlNaUJUVUV3d0hoY05Nakl3T1RJd01Ea3hPREU1V2hjTk5ESXdPVEl3TURreE9ERTVXakErCk1Rc3dDUVlEVlFRR0V3SkpUakVTTUJBR0ExVUVDaE1KU1c1a2FXRWdVRXRKTVJzd0dRWURWUVFERXhKRFEwRWcKU1c1a2FXRWdNakF5TWlCVFVFd3dnZ0lpTUEwR0NTcUdTSWIzRFFFQkFRVUFBNElDRHdBd2dnSUtBb0lDQVFETQpBKytWSnhFWE4rY296bkJBRWYwZHorOERCajlTcEVRR29laGp4b0RuRCtXWUVCQVhuYXAybGg1eUU3L3dscEhVClE3aEo1NEpzcUxCWlFHa00wcGszNWJrdnZjZjJ3QUdTZEswS1JpbE5lRkRtVmRkdXFBVUpVbG1OZUwwdWZJdWYKc1NCRXVzT1dLSzZWdlFIeGlaMHFveW9lcVYrQ3BuRG04STJJRTBXQlNiYW90WHRHV1N5QkxORENFSDNsUkE5RwpRRE9aNVV0Yzhzb1IyWVZ3YlFTaWNHb3lBQzFQaVBhaDdMWTZuWkNiQmpjNjNyMjJkRStDbTFUR2VxRWIwWlVkCmhIbDA1MVdxRUdYWG10UU5meXRkTlArVmRLVTFucllFY1E1QmVHTWFXQTViSGtPMkVSbGRJNUY1NXBYMDZoVXgKd2pMMzlINkpWWDUvMEkrYkJpUHNaaUNwZWEyZ0tvek5CZytNQldMcXlCVXpGUlZoTGZkQ1BCNnRtOUVLSGdybApQNnJzV3JqZ1o1RmNSRW1lckNZczdISVllZW1pSTBVTzRYOHJxcG9iVDNyTDdtV0FMQjJwbHlGYUJkaVVXVzFyCjg3ZVpRREVlWVdhdk9oTklUWU5jMzFGRzNLbjhEQU5GM0loTmVZbVVEekc3L00xWHlHeWNxQm1YRzd0VlZYZXoKTzFHYmdmTTBTWWxrVkZSRE9ENnU5VGYwbFIxTWZqckpwTUIrSmRJSmxpbU1NNUc2TEdpYTcrM05sbGw4U0owRApoVzQ5RmRLbExCOTJpWHVPb2s0aXdQenlGS2c4RWF4LzlpTjlUeE1hZFl4YnBLa2VQTDlEcEwveW1SdnBHRGtQCmF1cnFVUDc3c210QjhKbGY3Yng4U0I5RFdWalZxc2d2ZW1OK0RaZk5hd0lEQVFBQm96WXdOREFQQmdOVkhSTUIKQWY4RUJUQURBUUgvTUJFR0ExVWREZ1FLQkFoSUVveWR2RE9oNmpBT0JnTlZIUThCQWY4RUJBTUNBUVl3RFFZSgpLb1pJaHZjTkFRRUxCUUFEZ2dJQkFEWXY5MUpibndVK0loNWdOelpTSlkweUprWWs0dGJCQnNDWkRpdm1aa25DClRiTThCOWovaEVaY2ZYWkNUYlA2R0NHa3J4Vng4YURsN0UxczVER21kTzd4NVIrZHhyTEQyQjQrT1JoRGV0bE0KWWQyMm1vcFZuenFZNVVkYVE4dTE2Sk5FcC9tNzVVcVQ1TnZjZ3RFKy9zMUhyKzNsaFdLS3ZON3U5UHhEU0lvTQpUL0kwL3NqZTlmV3dqZVgyOW56cUhUdzdoWVRMQ0llUXY4Yzkrd0dCRkFBRkFyVXEwTWFJNmp4SWF2MTBES2VICnB0eWNVSHdNTnl6UDloaDdHNG5IbytsRUlUMC9qV0lyanY1MythVkZMZEF2QktRMmp5QUtkL09odVFGQ3VlM3oKTVZNb1RRN1psOUhaazcyQ2tCZWNhWmhIbkV6cWpwT3p1ZUN3ZUswaDI3SXZ3RUQ3c2N1ZHBPUG5ZN21sNmZFRgpkcEhYWlhjVno4VFpicWlya0hUTGVwZkFPVUJjeXVhZEFLa09SK201dVUxVUtrRVNleGFZMnlWRWRXY1ZBZUNNCjZwNkZYbEZlUk1FZWJNYnBwa1BlU0ZVUE1SQTltaHNVVE9rNXNibkdOMlRWa1NmVXBjVU1vUWd6MmJTcXZHeVIKN3NBWjlVbjQ1N3N3andFRUVuemlqZE12ZDlZRGoxd1JxK3RzcTM4enE1SWFFNTBWTU1YZUJvVnoyLzJCbjhNcgpwOGtON1hJa3JDdWk4d2pjbG5HOUJCMVNid2pYUGhFKzd6RTZHS2grb0lSWnVhMlJrYW1UcGp3ZSsyb1NpaEdWCkZlRDdwU01oL1BneXhnMWx4U1ZES3ZiQmR4TnJCcG90Mk9RTjM1K0RrQVUyZXhKTXRVWUF2emRQVng5ZDJlbG8KLS0tLS1FTkQgQ0VSVElGSUNBVEUtLS0tLQotLS0tLUJFR0lOIENFUlRJRklDQVRFLS0tLS0KTUlJRnV6Q0NBNk9nQXdJQkFnSVFUTDV6RVh5azQ3R3REQ20yMEtnWW9UQU5CZ2txaGtpRzl3MEJBUXNGQURBNgpNUXN3Q1FZRFZRUUdFd0pKVGpFU01CQUdBMVVFQ2hNSlNXNWthV0VnVUV0Sk1SY3dGUVlEVlFRREV3NURRMEVnClNXNWthV0VnTWpBeU1qQWVGdzB5TWpBeU1UWXhNVEU0TURkYUZ3MHpNakF5TVRZeE1URTRNRGRhTUlHNU1Rc3cKQ1FZRFZRUUdFd0pKVGpFWU1CWUdBMVVFQ2hNUFpVMTFaR2h5WVNCTWFXMXBkR1ZrTVIwd0d3WURWUVFMRXhSRApaWEowYVdaNWFXNW5JRUYxZEdodmNtbDBlVEVQTUEwR0ExVUVFUk1HTlRZd01UQXpNUkl3RUFZRFZRUUlFd2xMCllYSnVZWFJoYTJFeEVqQVFCZ05WQkFrVENVSmxibWRoYkhWeWRURWRNQnNHQTFVRU14TVVNM0prSUVac2IyOXkKTEZOaGFTQkJjbU5oWkdVeEdUQVhCZ05WQkFNVEVHVXRUWFZrYUhKaElFTkJJREl3TWpJd2dnRWlNQTBHQ1NxRwpTSWIzRFFFQkFRVUFBNElCRHdBd2dnRUtBb0lCQVFDblhpaFhteGx3UlE2ejd1QjFXZ1RTOXduYnQ0NTE3SDMxCkF1Qk9heGpEU29qcWxXTHRIcCtEMXVVYVBOcDUxZkRsVWgwUVV2L3FhRzF4aDZkRWpaRWNnQzQrdzg3eENDWFAKd3RFYmdYaUhXSEVOZnRpQ3hZbWNyeDNTbDd0b2V2L2czSmIzK0xsNW9KTWYrY1c0dm1aeEQ5QW1idHdjQVZmNApBaGN3d1c2QytJc1UyOXgvZXlGeklQYkRzRnhUSmVSd21wbVVMc1p4eWpIQXdJS1VaWURjRnhDRUdaSFlKU0ZyCkEyUkZDZXg0MkxXemhBZU1mZ2dEZFk5QU5LTGlDTWw2a3pHOGcraC9jT1pxdHFISlhGOE91QUN1RUdCV2h6WW4KNEZqbmN3djlzT2xjSlJndUx0ZnY5UmxBQ0QybVRYWitnN1p2T01ZZkpCLzFjb3k3MGhaeEFnTUJBQUdqZ2dFNwpNSUlCTnpBU0JnTlZIUk1CQWY4RUNEQUdBUUgvQWdFQk1CMEdBMVVkRGdRV0JCUUU0TGwwZk1DUy8rOXZ4TlkxCkpQKzYvUkE2VERBU0JnTlZIU0FFQ3pBSk1BY0dCV0NDWkdRQ01CTUdBMVVkSXdRTU1BcUFDRTQ3U0RaYzRsOTkKTUlHQUJnZ3JCZ0VGQlFjQkFRUjBNSEl3SGdZSUt3WUJCUVVITUFHR0VtaDBkSEE2THk5dlkzWnpMbWR2ZGk1cApiakJRQmdnckJnRUZCUWN3QW9aRWFIUjBjRG92TDNkM2R5NWpZMkV1WjI5MkxtbHVMMk5qWVM5emFYUmxjeTlrClpXWmhkV3gwTDJacGJHVnpMMlpwYkdWekwwTkRRVWx1WkdsaE1qQXlNaTVqWlhJd0RnWURWUjBQQVFIL0JBUUQKQWdFR01FWUdBMVVkSHdRL01EMHdPNkE1b0RlR05XaDBkSEE2THk5alkyRXVaMjkyTG1sdUwzSjNMM0psYzI5MQpjbU5sY3k5RFEwRkpibVJwWVRJd01qSk1ZWFJsYzNRdVkzSnNNQTBHQ1NxR1NJYjNEUUVCQ3dVQUE0SUNBUUJQCnIxRWRNQkZVditCSEo5VU1oMEVSbHNSSGZyc2g2V1VEOHB2RitkK0hEdlR5OUtHYWo2L0xnajZSbXRDVGdkT3QKT0RvK0hNSEVNcWcwSU5RWmNHVlJFSGxrOXF1cURhTjFxTnFFeVdOOThQdFdJUVFxV3FVWkNGRVNFSFltMm1YawoyNGgvT3NqRUlvTys1WnRQaU4vbDR1OVJxV2FzcWpuYWtHdENjbzdyM0c2UU5NRm5iSTVyMm5CVURhNHRRZW1JCkUxd2J4Znp5dDFWeUNON1NQYmZCS3VNVmdNakkyK1paOWxaRkNTYWhFb0lEUWVNd2lYUEdRRk0vYlo4UXJQOTcKc2YyTGtaaXZEaE5UOVFjZ0R5UVFtZlBobk85dTJNN2FTdVVYNXRmOUNEWnVzUmRYL1g0eWFuVjNjZVEwWGdsNgovb3pFbkcxa0NpOEJSMlNWUzlGc3hzK3ZwNUdiN1BDZ2dRTHFsVjBocTNFR3FZTzh5NmxtV0hHb0ZIVDAxMnRSCkRwakI0UmRBNFhoVGZaN1pmcnlyS2U5bnd5dWg1NXIrRllGUnpXSWlWMnhlV1NtVTFobE5qblVuVm04ZEVQZG4KMzRZdWEzWUFuU0hUOWJzbHA5ZzJJT1RjK2EzcHFmbjVWcDRHR29JU0E3WmRHME90M056ZDBsNkVSdTFCN3JjSQoyNXFGcVZORkFiQW9yMXV4NlZRSjVQbVRySTNDWWkzTGRpRWw2bEJ5OFNEOFFKdm41c0w5VE12bFVqWUJCUFlWCmppNmRNbWRYZHpyZkpHOWxkV29PZ1pDZWhLNFpaY3JXaVJibzZXY3FYS3YxeTZIcWpOSE5QNzhOaFRYYlZoVTYKZ3VBeURvVVRiQW1xRzdCOWkrN0paSm9rZXIyZE45eDErZU14V1BvQnV3PT0KLS0tLS1FTkQgQ0VSVElGSUNBVEUtLS0tLQotLS0tLUJFR0lOIENFUlRJRklDQVRFLS0tLS0KTUlJRS9qQ0NBK2FnQXdJQkFnSUVBVkp5RlRBTkJna3Foa2lHOXcwQkFRc0ZBRENCdVRFTE1Ba0dBMVVFQmhNQwpTVTR4R0RBV0JnTlZCQW9URDJWTmRXUm9jbUVnVEdsdGFYUmxaREVkTUJzR0ExVUVDeE1VUTJWeWRHbG1lV2x1Clp5QkJkWFJvYjNKcGRIa3hEekFOQmdOVkJCRVRCalUyTURFd016RVNNQkFHQTFVRUNCTUpTMkZ5Ym1GMFlXdGgKTVJJd0VBWURWUVFKRXdsQ1pXNW5ZV3gxY25VeEhUQWJCZ05WQkRNVEZETnlaQ0JHYkc5dmNpeFRZV2tnUVhKagpZV1JsTVJrd0Z3WURWUVFERXhCbExVMTFaR2h5WVNCRFFTQXlNREl5TUI0WERUSXlNREl4T0RFeU1qVTFNRm9YCkRUTXlNREl4TlRFeU1qVTFNRm93ZkRFTE1Ba0dBMVVFQmhNQ1NVNHhHREFXQmdOVkJBb1REMlZOZFdSb2NtRWcKVEdsdGFYUmxaREVkTUJzR0ExVUVDeE1VUTJWeWRHbG1lV2x1WnlCQmRYUm9iM0pwZEhreE5EQXlCZ05WQkFNVApLMlV0VFhWa2FISmhJRk4xWWlCRFFTQm1iM0lnUTJ4aGMzTWdNeUJKYm1ScGRtbGtkV0ZzSURJd01qSXdnZ0VpCk1BMEdDU3FHU0liM0RRRUJBUVVBQTRJQkR3QXdnZ0VLQW9JQkFRQytVVFY5Wk05ck5DVCtaZ0Iwdmx1WklvYSsKRVc0M1czNVhkRXh0VHJQd2U1NzhmL3FqS05KbTVwZ1hqblNMVmVkRjJOYnZqTzZ1VnlQeFBCMjJ6bGFqL2JGYwphZEdjNFFSTHJ2ZDRLZlkxd0xveC9ybWJrZXgwbEJTeitDc0RLa0hIUzJ1RmtHNjNBTTliNURDOEdERDBUN0FUCk9RT2tya2xNdW1xeXBKazNpK21uN2FDOEorVG9UTVNMelRzejFMVlNlMXNrOXE5UWNkVGpRYjB4aUNjVzZveWUKN1ZDcDhFSGt0NXBtUWpNN0xMZzh0dUdpb0E3ZGxTVHR5b1pHcEdUTHBkZCs1UTlrUkJUN2daRW43azVOcW9XbwppaWNGQmY2anU3TGFRd2JzRVZWRVZiYmhqTzFwM1pTMmY3WU1Jd09qSDVGTnBpcVFqRFk2YmFQUWM1SlBBZ01HClZUZWpnZ0ZJTUlJQlJEQWZCZ05WSFNNRUdEQVdnQlFFNExsMGZNQ1MvKzl2eE5ZMUpQKzYvUkE2VERBZEJnTlYKSFE0RUZnUVUvV1ZRT0piK2FrTWRmc3lmWDVEbmtuKzFFU013RWdZRFZSMFRBUUgvQkFnd0JnRUIvd0lCQURBTwpCZ05WSFE4QkFmOEVCQU1DQVFZd0VnWURWUjBnQkFzd0NUQUhCZ1ZnZ21Sa0FqQitCZ2dyQmdFRkJRY0JBUVJ5Ck1IQXdKQVlJS3dZQkJRVUhNQUdHR0doMGRIQTZMeTl2WTNOd0xtVXRiWFZrYUhKaExtTnZiVEJJQmdnckJnRUYKQlFjd0FvWThhSFIwY0RvdkwzZDNkeTVsTFcxMVpHaHlZUzVqYjIwdmNtVndiM05wZEc5eWVTOWpZV05sY25SegpMMlZ0ZFdSb2NtRmpZVEl3TWpJdVkzSjBNRW9HQTFVZEh3UkRNRUV3UDZBOW9EdUdPV2gwZEhBNkx5OTNkM2N1ClpTMXRkV1JvY21FdVkyOXRMM0psY0c5emFYUnZjbmt2WTNKc2N5OWxiWFZrYUhKaFkyRXlNREl5TG1OeWJEQU4KQmdrcWhraUc5dzBCQVFzRkFBT0NBUUVBWmRYL2tpV1c0SDhiQmJGZ0diS0ZPcnhNVnNvS3dxdUV3aU9HNnR1ZQpCbkRqdlJNRzFPTlNXbVJUeWFjT2NGaFVDRVRYclpJSGNDYks3NTVXT1N3RUdHRFZWOGEvVmNidnpTTW1sbjRVClpmL0E2NkFYQjdxM0hQa3dVK2VLaStSdXJWcWV4VVoyeS9hNkNNd3lmeXhIZmVZWm4rSVdNa2lmZmNSNUpiSksKUVZRdm5HT1grUjNTVG9vd2UzN2dOOVFDeDdRTk5xbUE5bEN6ZXlxM3k4SEhTZWpNOTV2WW4xTTh1SllxV2tXQQpYdmFob1ZsVmNqTGNlVkYyUG0xQ0tQWDB4dWlIT1FiREJxajlTeVJzRGpOMHZNblhFeUpOWDJYdjE1Qkg1V2lsCitNVVNheHJPZ3Q4QXB0QUozQUkxeUpoa2E2NWt4akVxZEV2SEkrajZwdVFsVFE9PQotLS0tLUVORCBDRVJUSUZJQ0FURS0tLS0tCi0tLS0tQkVHSU4gQ0VSVElGSUNBVEUtLS0tLQpNSUlGQURDQ0EraWdBd0lCQWdJRUFWSnlNakFOQmdrcWhraUc5dzBCQVFzRkFEQ0J1VEVMTUFrR0ExVUVCaE1DClNVNHhHREFXQmdOVkJBb1REMlZOZFdSb2NtRWdUR2x0YVhSbFpERWRNQnNHQTFVRUN4TVVRMlZ5ZEdsbWVXbHUKWnlCQmRYUm9iM0pwZEhreER6QU5CZ05WQkJFVEJqVTJNREV3TXpFU01CQUdBMVVFQ0JNSlMyRnlibUYwWVd0aApNUkl3RUFZRFZRUUpFd2xDWlc1bllXeDFjblV4SFRBYkJnTlZCRE1URkROeVpDQkdiRzl2Y2l4VFlXa2dRWEpqCllXUmxNUmt3RndZRFZRUURFeEJsTFUxMVpHaHlZU0JEUVNBeU1ESXlNQjRYRFRJeU1ESXhPREV5TXpFeE1Gb1gKRFRNeU1ESXhOVEV5TXpFeE1Gb3dmakVMTUFrR0ExVUVCaE1DU1U0eEdEQVdCZ05WQkFvVEQyVk5kV1JvY21FZwpUR2x0YVhSbFpERWRNQnNHQTFVRUN4TVVRMlZ5ZEdsbWVXbHVaeUJCZFhSb2IzSnBkSGt4TmpBMEJnTlZCQU1UCkxXVXRUWFZrYUhKaElGTjFZaUJEUVNCbWIzSWdRMnhoYzNNZ015QlBjbWRoYm1sellYUnBiMjRnTWpBeU1qQ0MKQVNJd0RRWUpLb1pJaHZjTkFRRUJCUUFEZ2dFUEFEQ0NBUW9DZ2dFQkFMa1ZibEhyN3JhdDA1Rmp3ZXl2YWNuMAo4QzVwOXJ5cTN1c2xqMGdMSnd5dHRFckhlNUF1UGFnbFlIWHVaRjNOaHI3eDVSai9uN1Ruc2FUSzU0aHlKRlBtCndyOXVlSDhFV1NhYnp1QXM0OHQweUdUQk5uNk1vN3NyZ1R3S3E2Q3Q1ZTdGUk85d0Zxa1hXZi9EQll1VngxQzYKQ240bVlJZDNINjkrdURFV0dRemJ4eisxcHZOcGhDaHkxTkRXMDRDL28zYW40c1Y4SmxUbHJsUHg5V21xbHU5RQo1TTVyWHRmYUhMRkI1bWRzeElmY2NkYXVYUVQ3WHg1TGtIRlNwRUt3dXFiU0lBSFRGbnRwSlBrc1ZjZWpyZmJBCnZ5YWgrSGtBTlp0VlFkaUt1RFpCM0piQ0dLZm1Fd24yemZNczI0aGtjcTJUUDRPQ2g5UU1PUTcvSzNzQ1FVVUMKQXdaVk42T0NBVWd3Z2dGRU1COEdBMVVkSXdRWU1CYUFGQVRndVhSOHdKTC83Mi9FMWpVay83cjlFRHBNTUIwRwpBMVVkRGdRV0JCU3lEZEJUb3planJsV0NTNWs5UmlnY2lWWkxyREFTQmdOVkhSTUJBZjhFQ0RBR0FRSC9BZ0VBCk1BNEdBMVVkRHdFQi93UUVBd0lCQmpBU0JnTlZIU0FFQ3pBSk1BY0dCV0NDWkdRQ01INEdDQ3NHQVFVRkJ3RUIKQkhJd2NEQWtCZ2dyQmdFRkJRY3dBWVlZYUhSMGNEb3ZMMjlqYzNBdVpTMXRkV1JvY21FdVkyOXRNRWdHQ0NzRwpBUVVGQnpBQ2hqeG9kSFJ3T2k4dmQzZDNMbVV0YlhWa2FISmhMbU52YlM5eVpYQnZjMmwwYjNKNUwyTmhZMlZ5CmRITXZaVzExWkdoeVlXTmhNakF5TWk1amNuUXdTZ1lEVlIwZkJFTXdRVEEvb0QyZ080WTVhSFIwY0RvdkwzZDMKZHk1bExXMTFaR2h5WVM1amIyMHZjbVZ3YjNOcGRHOXllUzlqY214ekwyVnRkV1JvY21GallUSXdNakl1WTNKcwpNQTBHQ1NxR1NJYjNEUUVCQ3dVQUE0SUJBUUFGVFFsQTlBR0h3K1VtQjFYakVwQmVyTDUyQzR6RlZLK2FrSDc2CkJ5eStQeXlqTDNBZHAyb0tKR0N4NXN4ejhtaDRqdjZuajUrSlVvRkoxSnJ1UStqdU9yMk5YVlR4Q3EwWXJ3RncKWWY0TURESGJ5aGxYL3V6V1pyaEp3eHhIN3EyMWhsWkgrMzhPVmNGRXhSNUlwaTljVG4vemhEbWY4WDNHTk9BdApwN0RvcGxKZXRRL2ZpcVRDTWZKRXhUZkxlVlN0VkdYVjlKUVZZTnVOVHJnNHloMlFrZHpPKzhlZ0trSlF5a2NQClFqemVJVHROQ29vcUxLRnp5RldMZHExOTZVcnJLdG44cExaQVRmQ28wWnhLZXo1WlpPOFhyQWJVWG1KMGRDQmUKb0VKSGVNOVJ3aEpjU0VrbWtGUGlFcFprdG9aaittMWVraXZYUjJxek50R3IxYk5aCi0tLS0tRU5EIENFUlRJRklDQVRFLS0tLS0KLS0tLS1CRUdJTiBDRVJUSUZJQ0FURS0tLS0tCk1JSUZCRENDQSt5Z0F3SUJBZ0lFQVZKeVJEQU5CZ2txaGtpRzl3MEJBUXNGQURDQnVURUxNQWtHQTFVRUJoTUMKU1U0eEdEQVdCZ05WQkFvVEQyVk5kV1JvY21FZ1RHbHRhWFJsWkRFZE1Cc0dBMVVFQ3hNVVEyVnlkR2xtZVdsdQpaeUJCZFhSb2IzSnBkSGt4RHpBTkJnTlZCQkVUQmpVMk1ERXdNekVTTUJBR0ExVUVDQk1KUzJGeWJtRjBZV3RoCk1SSXdFQVlEVlFRSkV3bENaVzVuWVd4MWNuVXhIVEFiQmdOVkJETVRGRE55WkNCR2JHOXZjaXhUWVdrZ1FYSmoKWVdSbE1Sa3dGd1lEVlFRREV4QmxMVTExWkdoeVlTQkRRU0F5TURJeU1CNFhEVEl5TURJeE9ERXlNelF5TUZvWApEVE15TURJeE5URXlNelF5TUZvd2dZRXhDekFKQmdOVkJBWVRBa2xPTVJnd0ZnWURWUVFLRXc5bFRYVmthSEpoCklFeHBiV2wwWldReEhUQWJCZ05WQkFzVEZFTmxjblJwWm5scGJtY2dRWFYwYUc5eWFYUjVNVGt3TndZRFZRUUQKRXpCbExVMTFaR2h5WVNCVGRXSWdRMEVnWm05eUlFTnNZWE56SURJZ1JHOWpkVzFsYm5RZ1UybG5ibVZ5SURJdwpNakl3Z2dFaU1BMEdDU3FHU0liM0RRRUJBUVVBQTRJQkR3QXdnZ0VLQW9JQkFRQ3BUUTl1Zk1MMmY2SkorclIrCktSUDBXQ1NXV0ppUDBvT3A0VE1tVS9FVW9OYTVCT0VUWkNacVlOVHJJODJZSUN1NUpVbWFHRExoaXVVNlVOelcKejVYWmFsSlJmV1hKc1UyVUxKNC9KamFybnJxUDdhSlVzUlFaTXlmWFRqL2pFaWlxbW5abWlKYlk1THFoeElGMgpUL2M4UFRYdUg3NVdEMXV2Q3ZxNzBTTm9yVXR2MnF2WFNCYlJJU2haczJzTUwxQWt2OGJ1ejdjQ2l5aGV6QklTCm0wVitWUVY0ZFpzM3pEUVZMQ2VCV1pnanlwN0NuUnZSUVNURVBrQlNqNTd0R2JrcDFGTTZrZ3V4RHJBcDNBL0sKak5VaWdrcm9XMWxlUWFtWHJ6MnFzeHBRSHNWSTF0c25scVA5UFRWV3RnZm90d2JneVJtdXlDZjg1alY3L2ZXWQprVVVsQWdNR1ZUZWpnZ0ZJTUlJQlJEQWZCZ05WSFNNRUdEQVdnQlFFNExsMGZNQ1MvKzl2eE5ZMUpQKzYvUkE2ClREQWRCZ05WSFE0RUZnUVVxLyt1dzEybTB1MDhGQUU4VlIxclUxN3F5KzB3RWdZRFZSMFRBUUgvQkFnd0JnRUIKL3dJQkFEQU9CZ05WSFE4QkFmOEVCQU1DQVFZd0VnWURWUjBnQkFzd0NUQUhCZ1ZnZ21Sa0FqQitCZ2dyQmdFRgpCUWNCQVFSeU1IQXdKQVlJS3dZQkJRVUhNQUdHR0doMGRIQTZMeTl2WTNOd0xtVXRiWFZrYUhKaExtTnZiVEJJCkJnZ3JCZ0VGQlFjd0FvWThhSFIwY0RvdkwzZDNkeTVsTFcxMVpHaHlZUzVqYjIwdmNtVndiM05wZEc5eWVTOWoKWVdObGNuUnpMMlZ0ZFdSb2NtRmpZVEl3TWpJdVkzSjBNRW9HQTFVZEh3UkRNRUV3UDZBOW9EdUdPV2gwZEhBNgpMeTkzZDNjdVpTMXRkV1JvY21FdVkyOXRMM0psY0c5emFYUnZjbmt2WTNKc2N5OWxiWFZrYUhKaFkyRXlNREl5CkxtTnliREFOQmdrcWhraUc5dzBCQVFzRkFBT0NBUUVBbVBaZmd4NXpnTTdEcFBZTjdMMTM5SkxhUDNDQTYvQjEKSk1xcnlEZkNQajlWQkVHenVYNGRRb3lPY3R1Y21VY1FiRktwWS8zYWpsdFZ5NFREMU02enFOR21oaEhqVmIrZgpOS2laMHZ2dUU1U1lFUnZURkl6NXZyTjJQZXdQMWwyenNTOEVXd3lvN2U3VHpJcVVaU29kVFZJSjMvMnAwb1JjCm1rRW13b1VYOHUzMWJ4S0FDVXZNNFYzSTdGSFVYbWVlQkJTaTdqU051ckF6U2N4MnlBRG93aU1kczZNOEJ1a0EKeUhiVDJXV1hHdE51MUdHR0ZXN2t6RU4wUkpZSTBVaHpQb1JVUjJVMXRXK2ZvdEdUZXd1MUUvRnc0OFNCUU5BUApFYXRRL3E4eWFiUmxzUUZuWVV4RFJnMFRzNjlhQzZiTktUajl3RnloakVrVGhtSjhiNjFpSGc9PQotLS0tLUVORCBDRVJUSUZJQ0FURS0tLS0tCi0tLS0tQkVHSU4gQ0VSVElGSUNBVEUtLS0tLQpNSUlGQkRDQ0EreWdBd0lCQWdJRUFWSnlUVEFOQmdrcWhraUc5dzBCQVFzRkFEQ0J1VEVMTUFrR0ExVUVCaE1DClNVNHhHREFXQmdOVkJBb1REMlZOZFdSb2NtRWdUR2x0YVhSbFpERWRNQnNHQTFVRUN4TVVRMlZ5ZEdsbWVXbHUKWnlCQmRYUm9iM0pwZEhreER6QU5CZ05WQkJFVEJqVTJNREV3TXpFU01CQUdBMVVFQ0JNSlMyRnlibUYwWVd0aApNUkl3RUFZRFZRUUpFd2xDWlc1bllXeDFjblV4SFRBYkJnTlZCRE1URkROeVpDQkdiRzl2Y2l4VFlXa2dRWEpqCllXUmxNUmt3RndZRFZRUURFeEJsTFUxMVpHaHlZU0JEUVNBeU1ESXlNQjRYRFRJeU1ESXhPREV5TXpVek4xb1gKRFRNeU1ESXhOVEV5TXpVek4xb3dnWUV4Q3pBSkJnTlZCQVlUQWtsT01SZ3dGZ1lEVlFRS0V3OWxUWFZrYUhKaApJRXhwYldsMFpXUXhIVEFiQmdOVkJBc1RGRU5sY25ScFpubHBibWNnUVhWMGFHOXlhWFI1TVRrd053WURWUVFECkV6QmxMVTExWkdoeVlTQlRkV0lnUTBFZ1ptOXlJRU5zWVhOeklETWdSRzlqZFcxbGJuUWdVMmxuYm1WeUlESXcKTWpJd2dnRWlNQTBHQ1NxR1NJYjNEUUVCQVFVQUE0SUJEd0F3Z2dFS0FvSUJBUUNOb2JsSWRHNWVvcERFVmV2TgozaDNIK25NVE1zbWZzWDJWcFRzVTdSZ2EyWTVzN24wZGNHKzlYbXRxajU3V1R0dThvSmduOHJuZUJFL2FYRHFhCkZNR0tab0oyQUY1Mk1ZT0trY0g1SlJuRkh5Zi9PQ0JaY3paL1lKZ1JpWkE1dTZ6ekV2cmpOcVVreUpna3ptQkEKdDRZaSsvTGZkRmNBL2NtRlJTaytxK3ZzT1VNVVJVV0Y3V1k2V0ltWkpYVldZeXJyNDhNVzZRUjJMNGd6SDYwbQpHZy9lQTduS3hkTjBncXlHcFlmR1hFSUZnbGxJU1Q1Q0s5VEFDQW1WejNLemdBelNjUXNEdmJNNWJ4YnhQdStWCldwajhaSnM4QytzeTJWM1h4aEtJVXZaSkJsYjBCK0cxZUo2ODhnMnpRL05TWWhwcmhJNXhUUWc2M3VnN1NUYWEKeU5oN0FnTUdWVGVqZ2dGSU1JSUJSREFmQmdOVkhTTUVHREFXZ0JRRTRMbDBmTUNTLys5dnhOWTFKUCs2L1JBNgpUREFkQmdOVkhRNEVGZ1FVSG53a1lFZllKbzR2RWJ1L2FORlZwWlRNZnlnd0VnWURWUjBUQVFIL0JBZ3dCZ0VCCi93SUJBREFPQmdOVkhROEJBZjhFQkFNQ0FRWXdFZ1lEVlIwZ0JBc3dDVEFIQmdWZ2dtUmtBakIrQmdnckJnRUYKQlFjQkFRUnlNSEF3SkFZSUt3WUJCUVVITUFHR0dHaDBkSEE2THk5dlkzTndMbVV0YlhWa2FISmhMbU52YlRCSQpCZ2dyQmdFRkJRY3dBb1k4YUhSMGNEb3ZMM2QzZHk1bExXMTFaR2h5WVM1amIyMHZjbVZ3YjNOcGRHOXllUzlqCllXTmxjblJ6TDJWdGRXUm9jbUZqWVRJd01qSXVZM0owTUVvR0ExVWRId1JETUVFd1A2QTlvRHVHT1doMGRIQTYKTHk5M2QzY3VaUzF0ZFdSb2NtRXVZMjl0TDNKbGNHOXphWFJ2Y25rdlkzSnNjeTlsYlhWa2FISmhZMkV5TURJeQpMbU55YkRBTkJna3Foa2lHOXcwQkFRc0ZBQU9DQVFFQUJreEZUdjYxMC95YldiaXZiODhjL2F4NFVLWmZpV1paCmRCT2lua1Z6UGlOVGdFUUR2bEFuTnlneDgwUEVuNFlVY2Q3UG41QjZjRFVBQ05pWEluU3VoQm5lZnV4TExXcWoKZm51Y3FtcVpXVHVwS0g2a1c3TmRhWjRqYU9XNHZsVWltSU9LeVh0Y1Qvd2lEVXlDaTRVdnlMdS9KVUU3KzhqWgpkU1AzOUZVd0d1YUdvOTJHenZJQ1NJK25IcXdSeGFLdjlhK0JXaUgxRnJUV253S3hjSW1ZQWhkNnVpRWNXbWVKCkVMZG1wRGt5VVBxUlhrdzdQMC94UG1meU1CRjA2NzVEVWFqMU1mWW8zVE5zU2REMTZlRFNmYXI2M0dxWTB4RG8KWk1kWGtIYVBEd2cvNVFQcVQweU1SOXVKWWVkTzM4dlVac2U5VTR2YkdxMndYMDNBNCtJd01BPT0KLS0tLS1FTkQgQ0VSVElGSUNBVEUtLS0tLQo="
write_chain_jar() {
    mkdir -p "$SHARE_DIR" "$CA_DIR"
    printf '%s' "$CHAIN_JAR_B64" | base64 -d > "$CHAIN_JAR.tmp" && [ "$(sha "$CHAIN_JAR.tmp")" = "$CHAIN_JAR_SHA" ] &&
        mv -f "$CHAIN_JAR.tmp" "$CHAIN_JAR" || { rm -f "$CHAIN_JAR.tmp"; warn "could not write the certificate-chain agent"; }
    printf '%s' "$CA_BUNDLE_B64" | base64 -d > "$CA_DIR/suite-bundle.pem.tmp" && [ "$(sha "$CA_DIR/suite-bundle.pem.tmp")" = "$CA_BUNDLE_SHA" ] &&
        mv -f "$CA_DIR/suite-bundle.pem.tmp" "$CA_DIR/suite-bundle.pem" || { rm -f "$CA_DIR/suite-bundle.pem.tmp"; warn "could not write the CA certificate bundle"; }
}

write_launcher() {
    mkdir -p "$SHARE_DIR"
    {
        echo '#!/usr/bin/env bash'
        echo "# Generated by railway-dsc-suite $SUITE_VERSION - do not edit; re-run \"railway-dsc install\"."
        echo '# usage: launch.sh eoffice|cris|ireps'
        local v
        for v in U_HOME LAF_JAR SCALE_JAR CHAIN_JAR CA_DIR E7_DIR E7_JAR E7_LOGS EOFFICE_DIR EOFFICE_JAR EOFFICE_JKS EOFFICE_LOGS CRIS_DIR IREPS_DIR CONF_FILE \
                 JRE8_DIR JRE17_DIR LEGACY_706_DIR HOSTS_NAME P11_CANDIDATES OPENSC_LIBS MTOKEN_LIB PROBE \
                 TOKEN_VIDS FEITIAN2_LIB HYPERSECU_LIB INNAIT_LIB PROXKEY_LIB; do
            printf '%s=%q\n' "$v" "${!v}"
        done
        declare -f java_major java_has_gui find_java8 find_java_modern find_p11_lib p11_override_fits plugged_vids p11_for_vid
    } > "$LAUNCH"
    cat >> "$LAUNCH" <<'LAUNCH_EOF'
SVC="${1:-}"
DSC_UI_SCALE=auto; DSC_EOFFICE_SCALE=auto; DSC_LOOK=native; P11_LIB=""; P11_FORCE=""; JAVA8=""; JAVA17=""; DSC_CHAIN_FILL=yes
[ -f "$CONF_FILE" ] && . "$CONF_FILE"

# --- Display: these are Swing apps and the PIN prompt needs an X display -------
# Java fixes its display the first time it draws a window and never recovers if that fails, so
# only start on a display that really accepts us. The inherited DISPLAY can be a stale one from
# the moment the login was still settling (seen: ":1024" without XAUTHORITY), so the desktop
# session's current values are tried first; every candidate is checked with a real X handshake.
x_works() {   # DISPLAY XAUTHORITY
    if command -v python3 >/dev/null 2>&1 && [ -f "$PROBE" ]; then
        python3 -I "$PROBE" x11 "$1" "$2" >/dev/null 2>&1
    else
        local n="${1#*:}" o; n="${n%%.*}"
        [ -n "$1" ] && [ -S "/tmp/.X11-unix/X$n" ] && o=$(stat -c %u "/tmp/.X11-unix/X$n" 2>/dev/null) \
            && { [ "$o" = 0 ] || [ "$o" = "$(id -u)" ]; }
    fi
}
guess_xauth() {
    local f
    for f in /run/user/$(id -u)/.mutter-Xwaylandauth.* /run/user/$(id -u)/xauth_* "$HOME/.Xauthority"; do
        [ -f "$f" ] && { echo "$f"; return; }
    done
}
pick_display() {
    local env="" d="" a="" s
    if command -v systemctl >/dev/null 2>&1; then
        env=$(systemctl --user show-environment 2>/dev/null)
        d=$(printf '%s\n' "$env" | sed -n 's/^DISPLAY=//p'); a=$(printf '%s\n' "$env" | sed -n 's/^XAUTHORITY=//p')
        [ -n "$d" ] && x_works "$d" "${a:-$(guess_xauth)}" && { DISPLAY="$d"; XAUTHORITY="${a:-$(guess_xauth)}"; return 0; }
    fi
    local named="$d"
    if [ -n "$IN_DISPLAY" ]; then
        a="${IN_XAUTHORITY:-$(guess_xauth)}"
        x_works "$IN_DISPLAY" "$a" && { DISPLAY="$IN_DISPLAY"; XAUTHORITY="$a"; return 0; }
    fi
    # Guess from the socket folder only when nobody named a display (no session manager);
    # a named display that does not answer yet is retried instead.
    [ -n "$named$IN_DISPLAY" ] && return 1
    a="${IN_XAUTHORITY:-$(guess_xauth)}"
    for s in /tmp/.X11-unix/X*; do
        [ -S "$s" ] && x_works ":${s##*/X}" "$a" && { DISPLAY=":${s##*/X}"; XAUTHORITY="$a"; return 0; }
    done
    return 1
}
IN_DISPLAY="${DISPLAY:-}"; IN_XAUTHORITY="${XAUTHORITY:-}"
# exec keeps the PID, so the watchdog reads "this run's" log as everything after this line
started_marker() { echo "=== railway-dsc: started $SVC pid $$ display ${DISPLAY:-?} $(date '+%F %T')"; }
i=0
until pick_display; do
    i=$((i+1)); [ $i -ge 30 ] && { echo "No working X display yet - will retry."; exit 1; }
    sleep 2
done
export DISPLAY
if [ -n "${XAUTHORITY:-}" ]; then export XAUTHORITY; else unset XAUTHORITY; fi

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
    started_marker; started_marker >&2
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
    started_marker; started_marker >&2
    # Java 8 cannot scale Swing on Linux: the scaling agent enlarges NIC's PIN window instead.
    case "$DSC_EOFFICE_SCALE" in ""|auto) ES="$DSC_UI_SCALE";; *) ES="$DSC_EOFFICE_SCALE";; esac
    AGENT=()
    if [ -f "$SCALE_JAR" ] && awk -v s="$ES" 'BEGIN{exit !(s+0 > 1.01)}'; then AGENT=("-javaagent:$SCALE_JAR=$ES"); fi
    # Completes a DSC chain the token holds only partly (see DSCSN05 in the README).
    if [ -f "$CHAIN_JAR" ] && [ "$DSC_CHAIN_FILL" != no ]; then AGENT+=("-javaagent:$CHAIN_JAR=$CA_DIR"); fi
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
started_marker
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
    echo "$LAUNCH"; echo "$PROBE"; echo "$LAF_JAR"; echo "$SCALE_JAR"; echo "$CHAIN_JAR"
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
    local k f                                         # vendor token drivers: pinned builds only
    for k in $DRV_KINDS; do
        for f in "$DRV_CACHE/$k/$(drv_file "$k")" "$(drv_target "$k")"; do
            [ -f "$f" ] && [ "$(drv_known "$(sha "$f")" || true)" = "$k" ] && { mkdir -p "$st/drivers/vendor/$k"; cp -p "$f" "$st/drivers/vendor/$k/"; break; }
        done
    done
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

# ========================================================= vendor drivers ===
# Token drivers taken from the vendors' own Linux downloads (eMudhra repository, Feitian, Hypersecu,
# Precision/InnaIT, WatchData). Only the PKCS#11 library is used: the vendors' installers are never
# run (they add world-writable udev rules, init scripts, autostart entries and their own pcscd).
# Unknown builds are taken only when named with --driver=FILE.
KNOWN_DRIVERS="69ecb65fc0f97acacbe8036a90caee0f33f690ef6ad6a843f45599a21312f0d4:feitian
9603b9b724336688b2d8dea24188cc64a76a106076e7e74affc22bc0c96fccf8:feitian2
6bb6e82f4340946c3bc20fb4c98adc185a5419b71d152a6ddfa886a4ae5de3ce:innait
78f813d1d9831e044dba84a1c11553699e016d992b2d1bac52e07dbfd0d6a578:proxkey
36bde09fcf08ecf2dbecdbf350c8398d443ed93e5421004c0d867a7c8526aa87:proxkey
75df0f4a474f88996b0218e6c0b41f99a0d5825b03900a3d48b6d38384f8e9e0:hypersecu"   # per kind: newest build first
#  feitian  = libcastle.so.1.0.0     ePass2003-Linux-x64.zip (Feitian/signaturehub)
#  feitian2 = libcastle_v2.so.1.0.0  ePass2003_Linux.zip (eMudhra repository)
#  innait   = InnaITDSC_Setup.zip / .deb 4.0.7.2 (technical.innait.com, linked from eMudhra)
#  proxkey  = ProxKey_Linux.zip (eMudhra, RAR inside) 1.1.1-2, proxkey_ubantu.deb (cryptoplanet)
#  hypersecu = libcastle_v2.so.1.0.0  HYP2003-Linux-x86_64-FIPS140-3.zip (hypersecu.com/india-support, 2026-06 build)
DRV_KINDS="feitian feitian2 hypersecu innait proxkey"
# PC/SC (CCID) readers that Ubuntu's libccid does not list yet: vid:pid:name
CCID_ADD="2ccf:080a:Hypersecu_HYP2003 338c:0031:InnaitKey_DSC 338c:0022:InnaitKey_DSC 338c:0032:InnaitKey_DSC"

drv_file() { case "$1" in feitian) echo libcastle.so.1.0.0;; feitian2|hypersecu) echo libcastle_v2.so.1.0.0;;
                          innait) echo libInnaITPKCS11Driver.so;; proxkey) echo libwdpkcs_SignatureP11.so;; esac; }
drv_target() { case "$1" in feitian) echo "$CASTLE_LIB";; feitian2) echo "$FEITIAN2_LIB";; hypersecu) echo "$HYPERSECU_LIB";;
                            innait) echo "$INNAIT_LIB";; proxkey) echo "$PROXKEY_LIB";; esac; }
drv_known() { local k; for k in $KNOWN_DRIVERS; do [ "${k%%:*}" = "$1" ] && { echo "${k#*:}"; return 0; }; done; return 1; }
drv_rank() { local k n=0; for k in $KNOWN_DRIVERS; do n=$((n+1)); [ "${k%%:*}" = "$1" ] && { echo $n; return; }; done; echo 999; }
elf_x64_so() {                # 64-bit little-endian x86-64 shared object
    [ "$(od -An -tx1 -N20 "$1" 2>/dev/null | tr -d ' \n')" = "7f454c4602010100000000000000000003003e00" ] ||
    [ "$(od -An -tx1 -j0 -N6 "$1" 2>/dev/null | tr -d ' \n')$(od -An -tx1 -j16 -N4 "$1" 2>/dev/null | tr -d ' \n')" = "7f454c46020103003e00" ]
}
sys_lib() { ldconfig -p 2>/dev/null | awk -v n="$1" '$1==n && /x86-64/ {print $NF; exit}'; }
plugged_ids() { local d; for d in /sys/bus/usb/devices/*; do [ -f "$d/idVendor" ] && echo "$(cat "$d/idVendor"):$(cat "$d/idProduct" 2>/dev/null)"; done 2>/dev/null | sort -u; }

unrar_py() {                  # $1 RAR  $2 dir: pull archives / libraries out with the system libarchive (no unrar needed)
    python3 -I - "$1" "$2" <<'PY'
import ctypes, ctypes.util, os, sys
la = ctypes.CDLL(ctypes.util.find_library("archive") or "libarchive.so.13")
V = ctypes.c_void_p
la.archive_read_new.restype = V
for f in ("archive_read_support_format_all", "archive_read_support_filter_all", "archive_read_free", "archive_read_data_skip"):
    getattr(la, f).argtypes = [V]
la.archive_read_open_filename.argtypes = [V, ctypes.c_char_p, ctypes.c_size_t]
la.archive_read_next_header.argtypes = [V, ctypes.POINTER(V)]
la.archive_entry_pathname.argtypes = [V]; la.archive_entry_pathname.restype = ctypes.c_char_p
la.archive_read_data.argtypes = [V, V, ctypes.c_size_t]; la.archive_read_data.restype = ctypes.c_ssize_t
a = la.archive_read_new(); la.archive_read_support_format_all(a); la.archive_read_support_filter_all(a)
if la.archive_read_open_filename(a, sys.argv[1].encode(), 65536) != 0:
    sys.exit(1)
e, buf, i = V(), ctypes.create_string_buffer(65536), 0
while la.archive_read_next_header(a, ctypes.byref(e)) in (0, -20):
    name = os.path.basename((la.archive_entry_pathname(e) or b"").decode("utf-8", "replace"))
    if not name.lower().endswith((".deb", ".zip", ".so", ".tar.bz2", ".tar.gz", ".tar.xz", ".tgz")) and ".so." not in name:
        la.archive_read_data_skip(a); continue
    i += 1
    with open(os.path.join(sys.argv[2], f"{i}-{name}"), "wb") as o:   # flat: no paths from the archive are used
        while (n := la.archive_read_data(a, buf, 65536)) > 0:
            o.write(buf.raw[:n])
la.archive_read_free(a)
PY
}
unpack_any() {                # $1 archive  $2 empty dir  $3 depth - zip/deb/rar/tar, then the archives inside (vendors nest them)
    local f="$1" d="$2" n="${3:-0}" m i=0 sub
    m=$(od -An -tx1 -N8 "$f" 2>/dev/null | tr -d ' \n')
    case "$m" in
        504b0304*) unzip -q -o "$f" -d "$d" >/dev/null 2>&1;;
        213c617263683e0a) have dpkg-deb && dpkg-deb -x "$f" "$d" 2>/dev/null;;
        526172211a07*) if have bsdtar; then bsdtar -xf "$f" -C "$d" 2>/dev/null; else unrar_py "$f" "$d" 2>/dev/null; fi;;
        425a68*|1f8b*|fd377a585a00*) tar -xf "$f" -C "$d" --no-same-owner 2>/dev/null;;
        *) return 1;;
    esac
    [ "$n" -ge 3 ] && return 0
    local subs=(); mapfile -t subs < <(find "$d" -type f \( -iname '*.zip' -o -iname '*.deb' -o -iname '*.rar' -o -iname '*.tar.bz2' \
        -o -iname '*.tar.gz' -o -iname '*.tgz' \) 2>/dev/null)                 # listed before anything more is unpacked here
    for sub in "${subs[@]}"; do
        i=$((i+1)); mkdir -p "$d/.u$n-$i"; unpack_any "$sub" "$d/.u$n-$i" $((n+1))
    done
    return 0
}
archive_kinds() {             # driver kinds a download's name points to
    case "${1,,}" in
        *hyp2003*|*hypersecu*) echo hypersecu;; *epass*) echo "feitian feitian2";;
        *innait*) echo innait;; *proxkey*|*wdtokentool*) echo proxkey;; *) echo "$DRV_KINDS";;
    esac
}
find_driver_archives() {      # vendor driver downloads in ~/Downloads, ~/Desktop
    find "$U_HOME/Downloads" "$U_HOME/Desktop" -maxdepth 4 -type f -size -200M \( -iname 'ePass2003*Linux*.zip' \
        -o -iname 'HYP2003*Linux*.zip' -o -iname '*hypersecu*linux*.zip' -o -iname 'InnaITDSC_Setup*.zip' -o -iname 'InnaITDSC_Setup*.deb' \
        -o -iname 'innait-dsc*.deb' -o -iname 'ProxKey_Linux*' -o -iname '*proxkey*.deb' -o -iname 'wdtokentool-proxkey*.deb' \) 2>/dev/null
}
cache_driver() {              # $1 library  $2 kind  $3 explicit(1/0)  $4 where from: verify, then keep in $DRV_CACHE/<kind>/
    local lib="$1" k="$2" s want dst
    elf_x64_so "$lib" || return 1
    s=$(sha "$lib"); dst="$DRV_CACHE/$k/$(drv_file "$k")"
    [ -f "$dst" ] && [ "$(sha "$dst")" = "$s" ] && return 0
    want=$(drv_known "$s" || true)
    if [ "$3" != 1 ] && [ -f "$dst" ] && [ "$(drv_rank "$(sha "$dst")")" -le "$(drv_rank "$s")" ]; then return 0; fi   # keep the newer build
    if [ "$want" = "$k" ] || { [ -z "$want" ] && [ "$3" = 1 ]; }; then
        [ -z "$want" ] && warn "$(basename "$4"): $k driver build not known to the suite (sha256 ${s:0:16}...) - used because you named it"
        mkdir -p "$DRV_CACHE/$k" && install -m 0644 "$lib" "$dst" && ok "$k token driver taken from $(basename "$4")"
    elif [ -z "$want" ]; then info "skipped an unknown $k driver build in $(basename "$4") (use --driver=FILE to take it)"
    fi
}
stage_vendor_drivers() {      # args: files from --driver/--epass-zip.  Fills $DRV_CACHE; sets DRV_PENDING = kinds root must install
    local f k t s lib missing="" want ex
    DRV_PENDING=""; mkdir -p "$DRV_CACHE"
    if [ -n "${PAYLOAD:-}" ] && [ -d "$PAYLOAD/drivers/vendor" ]; then           # shipped in the bundle (pinned builds only)
        for k in $DRV_KINDS; do f="$PAYLOAD/drivers/vendor/$k/$(drv_file "$k")"; [ -f "$f" ] && cache_driver "$f" "$k" 0 "the bundle"; done
    fi
    for k in $DRV_KINDS; do [ -f "$DRV_CACHE/$k/$(drv_file "$k")" ] || [ -f "$(drv_target "$k")" ] || missing="$missing $k"; done
    { for f in "$@"; do echo "1 $f"; done
      [ -n "$missing" ] && find_driver_archives | sed 's/^/0 /'; } | while read -r ex f; do
        [ -f "$f" ] || { warn "driver file not found: $f"; continue; }
        want=""; for k in $(archive_kinds "$(basename "$f")"); do case " $missing " in *" $k "*) want=1;; esac; done
        [ "$ex" = 1 ] || [ -n "$want" ] || continue
        t=$(mktemp -d); mkdir -p "$t/x"
        if elf_x64_so "$f"; then cp "$f" "$t/x/"; elif ! unpack_any "$f" "$t/x" 0; then warn "cannot unpack $(basename "$f")"; chmod -R u+rwX "$t"; rm -rf "$t"; continue; fi
        while IFS= read -r lib; do
            case "$(basename "$lib")" in
                *libcastle.so.1.0.0) k=feitian;;
                *libcastle_v2.so.1.0.0) case " $(archive_kinds "$(basename "$f")") " in *" hypersecu "*) k=hypersecu;; *) k=feitian2;; esac
                                        s=$(drv_known "$(sha "$lib")" || true); [ -n "$s" ] && k=$s;;
                *libInnaITPKCS11Driver.so) k=innait;;
                *libwdpkcs_SignatureP11.so) k=proxkey;;
                *) continue;;
            esac
            cache_driver "$lib" "$k" "$ex" "$f"
        done < <(find "$t/x" -type f \( -name '*libcastle.so.1.0.0' -o -name '*libcastle_v2.so.1.0.0' -o -name '*libInnaITPKCS11Driver.so' -o -name '*libwdpkcs_SignatureP11.so' \) 2>/dev/null)
        chmod -R u+rwX "$t" 2>/dev/null; rm -rf "$t"           # vendor zips can hold read-only folders
    done
    for k in $DRV_KINDS; do
        f="$DRV_CACHE/$k/$(drv_file "$k")"; t=$(drv_target "$k"); [ -f "$f" ] || continue
        case "$k" in
            feitian|proxkey) [ -f "$t" ] || DRV_PENDING="$DRV_PENDING $k";;      # never replace a vendor's own install
            *) [ "$(sha "$t")" = "$(sha "$f")" ] || DRV_PENDING="$DRV_PENDING $k";;
        esac
    done
    DRV_PENDING="${DRV_PENDING# }"
}
proxkey_compat_ok() { [ ! -f "$PROXKEY_LIB" ] || ! ldd "$PROXKEY_LIB" 2>/dev/null | grep -q 'not found'; }
ccid_plist() { find /usr/lib /usr/lib64 /usr/local/lib -path '*ifd-ccid.bundle/Contents/Info.plist' 2>/dev/null | head -1; }
ccid_has() {                  # $1 vid  $2 pid (hex, any case)
    local p; p=$(ccid_plist); [ -n "$p" ] || return 1
    python3 -I - "$p" "$1" "$2" <<'PY'
import plistlib, sys
d = plistlib.load(open(sys.argv[1], "rb"))
want = (int(sys.argv[2], 16), int(sys.argv[3], 16))
sys.exit(0 if want in {(int(v, 16), int(p, 16)) for v, p in zip(d["ifdVendorID"], d["ifdProductID"])} else 1)
PY
}
ccid_missing() {              # CCID_ADD entries still to add: for tokens whose driver is here or that are plugged in
    local e v p have_drv plugged; plugged=$(plugged_vids)
    [ -n "$(ccid_plist)" ] || return 0
    for e in $CCID_ADD; do
        v=${e%%:*}; p=${e#*:}; p=${p%%:*}; have_drv=""
        case "$v" in 2ccf) [ -f "$HYPERSECU_LIB" ] || [ -f "$DRV_CACHE/hypersecu/$(drv_file hypersecu)" ] && have_drv=1;;
                     338c) [ -f "$INNAIT_LIB" ] || [ -f "$DRV_CACHE/innait/$(drv_file innait)" ] && have_drv=1;; esac
        { [ -n "$have_drv" ] || printf '%s\n' "$plugged" | grep -qx "$v"; } && ! ccid_has "$v" "$p" && echo "$e"
    done
}
ccid_register() {             # root: add reader ids to libccid's Info.plist (backup kept; libccid updates undo it - doctor notices)
    local p e add=(); p=$(ccid_plist); [ -n "$p" ] || return 0
    for e in $(ccid_missing); do add+=("$e"); done
    [ ${#add[@]} -gt 0 ] || return 0
    [ -f "$p.bak-railway-dsc" ] || cp -p "$p" "$p.bak-railway-dsc"
    if python3 -I - "$p" "${add[@]}" <<'PY'
import os, plistlib, re, sys
path, add = sys.argv[1], [a.split(":", 2) for a in sys.argv[2:]]
s = open(path, encoding="utf-8").read()
cols = {"ifdVendorID": ["0x" + v.upper() for v, _, _ in add], "ifdProductID": ["0x" + p.upper() for _, p, _ in add],
        "ifdFriendlyName": [n.replace("_", " ") + " (railway-dsc)" for _, _, n in add]}
for key, vals in cols.items():
    m = re.search(r"<key>%s</key>\s*<array>(.*?)</array>" % key, s, re.S)
    if not m:
        sys.exit(2)
    at = m.start(1) + m.group(1).rfind("\n") + 1          # start of the line holding </array>
    s = s[:at] + "".join("\t\t<string>%s</string>\n" % v for v in vals) + s[at:]
d = plistlib.loads(s.encode())
n = len(d["ifdVendorID"])
if not (n == len(d["ifdProductID"]) == len(d["ifdFriendlyName"])):
    sys.exit(3)
tmp = path + ".railway-dsc-tmp"
with open(tmp, "w", encoding="utf-8") as f:
    f.write(s)
os.chmod(tmp, os.stat(path).st_mode & 0o7777)
os.replace(tmp, path)
PY
    then ok "smart-card reader list: added ${add[*]//_/ }"
         have systemctl && systemctl try-restart pcscd.service >/dev/null 2>&1 || true
    else warn "could not add the token ids to $p (left unchanged)"; fi
}
install_vendor_drivers() {    # root.  $1 = the user's $DRV_CACHE
    local k f t
    for k in $DRV_KINDS; do
        f="$1/$k/$(drv_file "$k")"; t=$(drv_target "$k")
        [ -f "$f" ] && [ ! -L "$f" ] && elf_x64_so "$f" || continue
        case "$k" in feitian|proxkey) [ -f "$t" ] && continue;; esac
        [ -f "$t" ] && [ "$(sha "$t")" = "$(sha "$f")" ] && continue
        install -D -o root -g root -m 0644 "$f" "$t" && ok "$k token driver installed ($t)"
    done
    if [ -f "$PROXKEY_LIB" ] && [ ! -e "$PROXKEY_COMPAT/pcscd_wd" ]; then     # not WatchData's own install (own daemon)
        # The ProxKey driver looks in $PROXKEY_COMPAT for WatchData's pcsc-lite fork and an old libxml2.
        # CCID ProxKeys work with the system pcscd, and libxml2.so.16 still has the 7 functions it uses.
        local pc x; pc=$(sys_lib libpcsclite.so.1); x=$(sys_lib libxml2.so.2); [ -n "$x" ] || x=$(sys_lib libxml2.so.16)
        mkdir -p "$PROXKEY_COMPAT"
        [ -n "$pc" ] && [ ! -e "$PROXKEY_COMPAT/libpcsclite_wd.so.1" ] && ln -s "$pc" "$PROXKEY_COMPAT/libpcsclite_wd.so.1"
        [ -n "$x" ] && [ ! -e "$PROXKEY_COMPAT/libxml2.so.2" ] && ln -s "$x" "$PROXKEY_COMPAT/libxml2.so.2"
        proxkey_compat_ok && ok "ProxKey driver linked to the system smart-card service" || warn "ProxKey driver still misses libraries: $(ldd "$PROXKEY_LIB" | awk '/not found/{print $1}' | paste -sd' ')"
    fi
}

cmd_root() {                  # internal: runs under sudo.  args: user payload_dir need_java8 need_java17 need_cab drivers pdf
                              #   drivers = the user's driver cache dir (older versions passed an ePass2003 zip)
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
    if [ -n "$epass" ] && [ -d "$epass" ] && [ "$(uname -m)" = x86_64 ]; then
        install_vendor_drivers "$epass"
    elif [ -n "$epass" ] && [ -f "$epass" ] && [ ! -f "$CASTLE_LIB" ] && [ "$(uname -m)" = x86_64 ]; then
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
    ccid_register
    if [ -d /etc/udev/rules.d ] && { [ -f "$UDEV_RULE" ] || ! udev_rule_present; } && ! udev_rule_current; then
        udev_rule_text > "$UDEV_RULE"
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
SIGNPDF_SHA="b549d19ed05b3377e10d9f2ed69ffd80474a8ac00509db838c65bb139e67d197"
SIGNPDF_B64="IiIiU2lnbiBhIFBERiB3aXRoIHRoZSBEU0MgVVNCIHRva2VuIChQQWRFUywgdmlzaWJsZSBzaWduYXR1cmUgYm94IGJ5IGRlZmF1bHQpLgoKICAgIHNpZ24tcGRmIGxldHRlci5wZGYgICAgICAgICAgICAgICAgICAgICAgICAgLT4gbGV0dGVyX3NpZ25lZC5wZGYsIGJveCBhdCBib3R0b20tcmlnaHQgb2YgdGhlIGxhc3QgcGFnZQogICAgc2lnbi1wZGYgbGV0dGVyLnBkZiAtbyBvdXQucGRmIC0tcmVhc29uICJBcHByb3ZlZCIgLS1sb2NhdGlvbiAiUmF0bGFtIgogICAgc2lnbi1wZGYgbGV0dGVyLnBkZiAtLXBhZ2UgMSAtLXBvcyBibCAgICAgICBmaXJzdCBwYWdlLCBib3R0b20tbGVmdAogICAgc2lnbi1wZGYgbGV0dGVyLnBkZiAtLXBhZ2VzIGFsbCAgICAgICAgICAgICBhIHNpZ25hdHVyZSBib3ggb24gZXZlcnkgcGFnZSAoUElOIGFza2VkIG9uY2UpCiAgICBzaWduLXBkZiBsZXR0ZXIucGRmIC0tcGFnZXMgMSwzLDUtNyAgICAgICAgIHRob3NlIHBhZ2VzIG9ubHkKICAgIHNpZ24tcGRmIGxldHRlci5wZGYgLS1kcmF3ICAgICAgICAgICAgICAgICAgYSB3aW5kb3cgc2hvd3MgdGhlIHBhZ2U6IGRyYXcgdGhlIGJveCwgY2hvb3NlIHRoZSBwYWdlcwogICAgc2lnbi1wZGYgbGV0dGVyLnBkZiAtLWJveCAwLjYsMC44NSwwLjk1LDAuOTUgICBib3ggYXMgZnJhY3Rpb25zIG9mIHRoZSBwYWdlIChsZWZ0LHRvcCxyaWdodCxib3R0b20pCiAgICBzaWduLXBkZiBsZXR0ZXIucGRmIC0taW52aXNpYmxlICAgICAgICAgICAgIG5vIGJveCAodGhlIHNpZ25hdHVyZSBpcyBzdGlsbCBpbiB0aGUgZmlsZSkKClN0YXJ0ZWQgZnJvbSB0aGUgZmlsZSBtYW5hZ2VyIG9yIHRoZSBhcHAgbWVudSwgdGhlIGRyYXcgd2luZG93IG9wZW5zIGJ5IGl0c2VsZiAoLS1uby1kcmF3IHNraXBzIGl0KS4KRXZlcnkgcGFnZSBjaG9zZW4gZ2V0cyBpdHMgb3duIHNpZ25hdHVyZSwgYWxsIG1hZGUgaW4gb25lIHRva2VuIHNlc3Npb24sIHNvIHRoZSBQSU4gaXMgYXNrZWQgb25jZS4KVGhlIHRva2VuIFBJTiBpcyBhc2tlZCBmb3IgZXZlcnkgdGltZSAodGVybWluYWwsIG9yIGEgcGFzc3dvcmQgYm94IHdoZW4gc3RhcnRlZCBmcm9tIHRoZSBmaWxlIG1hbmFnZXIpIGFuZCBpcwpuZXZlciBzdG9yZWQuIFRoZSB0b2tlbidzIGRyaXZlciBpcyBjaG9zZW4gYnkgdGhlIHRva2VuIHBsdWdnZWQgaW4gKHNhbWUgdGFibGUgYXMgcmFpbHdheS1kc2MpLgoiIiIKaW1wb3J0IGFyZ3BhcnNlCmltcG9ydCBnZXRwYXNzCmltcG9ydCBpbwppbXBvcnQganNvbgppbXBvcnQgb3MKaW1wb3J0IHJlCmltcG9ydCBzaHV0aWwKaW1wb3J0IHN1YnByb2Nlc3MKaW1wb3J0IHN5cwppbXBvcnQgdGVtcGZpbGUKCk9QRU5TQyA9IFsiL3Vzci9saWIveDg2XzY0LWxpbnV4LWdudS9vcGVuc2MtcGtjczExLnNvIiwgIi91c3IvbGliL3g4Nl82NC1saW51eC1nbnUvcGtjczExL29wZW5zYy1wa2NzMTEuc28iXQpEUklWRVJTID0geyAgIyBVU0IgdmVuZG9yIGlkIC0+IFBLQ1MjMTEgZHJpdmVycywgYmVzdCBmaXJzdCAobWlycm9ycyByYWlsd2F5LWRzYydzIHAxMV9mb3JfdmlkKQogICAgIjA1NWMiOiBbIi91c3IvbGliL2xpYmNyeXB0b2lkX3BrY3MxMS5zbyIsICIvdXNyL2xpYi9saWJtVG9rZW5QS0NTMTEuc28iXSwKICAgICIwOTZlIjogWyIvdXNyL2xpYi9saWJjYXN0bGUuc28uMS4wLjAiLCAiL3Vzci9saWIvcmFpbHdheS1kc2MvZmVpdGlhbi9saWJjYXN0bGVfdjIuc28uMS4wLjAiLCAiL3Vzci9saWIvbGliY2FzdGxlLnNvIiwKICAgICAgICAgICAgICIvdXNyL2xpYi94ODZfNjQtbGludXgtZ251L2xpYmNhc3RsZS5zbyJdICsgT1BFTlNDLAogICAgIjJjY2YiOiBbIi91c3IvbGliL3JhaWx3YXktZHNjL2h5cGVyc2VjdS9saWJjYXN0bGVfdjIuc28uMS4wLjAiLCAiL3Vzci9saWIvbGliY2FzdGxlX3YyLnNvLjEuMC4wIl0sCiAgICAiMzM4YyI6IFsiL3Vzci9saWIvcmFpbHdheS1kc2MvaW5uYWl0L2xpYklubmFJVFBLQ1MxMURyaXZlci5zbyIsCiAgICAgICAgICAgICAiL29wdC9QcmVjaXNpb25fQmlvbWV0cmljL0lubmFJVERTQy9saWJyYXJpZXMvbGliSW5uYUlUUEtDUzExRHJpdmVyLnNvIl0sCiAgICAiMTYzYyI6IFsiL3Vzci9saWIvV2F0Y2hEYXRhL1Byb3hLZXkvbGliL2xpYndkcGtjc19TaWduYXR1cmVQMTEuc28iLCAiL3Vzci9saWIvV2F0Y2hEYXRhL1RSVVNUS0VZL2xpYi9saWJ3ZHBrY3NfVFJVU1RLRVkuc28iLAogICAgICAgICAgICAgIi91c3IvbGliL1dhdGNoRGF0YS9lTXVkaHJhXzMuNC4zL2xpYi9saWJ3ZHBrY3NfZU11ZGhyYV8zNDMuc28iLCAiL3Vzci9saWIvV2F0Y2hEYXRhL1BST1hLZXkvbGliL2xpYndkcGtjcy5zbyIsCiAgICAgICAgICAgICAiL3Vzci9saWIvbGlid2Rwa2NzLnNvIl0sCiAgICAiMDUyOSI6IFsiL3Vzci9saWIvbGliZVRQa2NzMTEuc28iLCAiL3Vzci9saWIvbGliZVRva2VuLnNvIl0sCiAgICAiMDhlNiI6IFsiL3Vzci9saWIvcGtjczExL2xpYmd0b3AxMWRvdG5ldC5zbyIsICIvdXNyL2xpYi9saWJndG9wMTFkb3RuZXQuc28iXSArIE9QRU5TQywKICAgICIyNGRjIjogWyIvdXNyL2xpYi9saWJqY1BLQ1MxMS0yLnNvIiwgIi91c3IvbGliL3g4Nl82NC1saW51eC1nbnUvbGliamNQS0NTMTEtMi5zbyJdLAogICAgIjA0ZTYiOiBPUEVOU0MsICIwNzJmIjogT1BFTlNDLAp9CkdVSSA9IG5vdCBzeXMuc3RkaW4uaXNhdHR5KCkKQk9YX1csIEJPWF9ILCBNQVJHSU4gPSAyMTAsIDY0LCAzMCAgICAgICAgICAjIHRoZSBkZWZhdWx0IGJveCwgaW4gcG9pbnRzIChib3R0b20tcmlnaHQgb2YgYW4gQTQgcGFnZSkKCgpkZWYgc2F5KG1zZywgZXJyb3I9RmFsc2UpOgogICAgcHJpbnQobXNnLCBmaWxlPXN5cy5zdGRlcnIgaWYgZXJyb3IgZWxzZSBzeXMuc3Rkb3V0LCBmbHVzaD1UcnVlKQoKCmRlZiBmYWlsKG1zZyk6CiAgICBzYXkoInNpZ24tcGRmOiAiICsgbXNnLCBlcnJvcj1UcnVlKQogICAgaWYgR1VJIGFuZCBzaHV0aWwud2hpY2goInplbml0eSIpOgogICAgICAgIHN1YnByb2Nlc3MucnVuKFsiemVuaXR5IiwgIi0tZXJyb3IiLCAiLS10aXRsZT1TaWduIFBERiIsICItLW5vLXdyYXAiLCAiLS10ZXh0PSIgKyBtc2ddKQogICAgc3lzLmV4aXQoMSkKCgpkZWYgcGx1Z2dlZF92aWRzKCk6CiAgICBvdXQgPSBbXQogICAgZm9yIGQgaW4gb3MubGlzdGRpcigiL3N5cy9idXMvdXNiL2RldmljZXMiKToKICAgICAgICB0cnk6CiAgICAgICAgICAgIHdpdGggb3BlbihmIi9zeXMvYnVzL3VzYi9kZXZpY2VzL3tkfS9pZFZlbmRvciIpIGFzIGY6CiAgICAgICAgICAgICAgICBvdXQuYXBwZW5kKGYucmVhZCgpLnN0cmlwKCkubG93ZXIoKSkKICAgICAgICBleGNlcHQgT1NFcnJvcjoKICAgICAgICAgICAgcGFzcwogICAgcmV0dXJuIG91dAoKCmRlZiBmaW5kX2RyaXZlcihvdmVycmlkZSk6CiAgICBpZiBvdmVycmlkZToKICAgICAgICByZXR1cm4gb3ZlcnJpZGUgaWYgb3MucGF0aC5pc2ZpbGUob3ZlcnJpZGUpIGVsc2UgZmFpbCgibm8gc3VjaCBQS0NTIzExIGRyaXZlcjogIiArIG92ZXJyaWRlKQogICAga25vd24gPSBGYWxzZQogICAgZm9yIHYgaW4gcGx1Z2dlZF92aWRzKCk6CiAgICAgICAgaWYgdiBpbiBEUklWRVJTOgogICAgICAgICAgICBrbm93biA9IFRydWUKICAgICAgICAgICAgZm9yIGxpYiBpbiBEUklWRVJTW3ZdOgogICAgICAgICAgICAgICAgaWYgb3MucGF0aC5pc2ZpbGUobGliKToKICAgICAgICAgICAgICAgICAgICByZXR1cm4gbGliCiAgICBpZiBrbm93bjoKICAgICAgICBmYWlsKCJ0aGUgcGx1Z2dlZCB0b2tlbidzIGRyaXZlciBpcyBub3QgaW5zdGFsbGVkIChydW46IHJhaWx3YXktZHNjIGRvY3RvcikiKQogICAgZmFpbCgibm8gRFNDIHRva2VuIGZvdW5kIC0gcGx1ZyBpbiB0aGUgVVNCIHRva2VuIGFuZCB0cnkgYWdhaW4iKQoKCmRlZiBhc2tfcGluKCk6CiAgICBpZiBHVUkgYW5kIHNodXRpbC53aGljaCgiemVuaXR5Iik6CiAgICAgICAgciA9IHN1YnByb2Nlc3MucnVuKFsiemVuaXR5IiwgIi0tcGFzc3dvcmQiLCAiLS10aXRsZT1EU0MgdG9rZW4gUElOIl0sIGNhcHR1cmVfb3V0cHV0PVRydWUsIHRleHQ9VHJ1ZSkKICAgICAgICBpZiByLnJldHVybmNvZGUgIT0gMDoKICAgICAgICAgICAgc3lzLmV4aXQoMSkKICAgICAgICByZXR1cm4gci5zdGRvdXQucnN0cmlwKCJcbiIpCiAgICByZXR1cm4gZ2V0cGFzcy5nZXRwYXNzKCJUb2tlbiBQSU46ICIpCgoKZGVmIGN1cnJlbnRfdW1hc2soKToKICAgIG0gPSBvcy51bWFzaygwKQogICAgb3MudW1hc2sobSkKICAgIHJldHVybiBtCgoKZGVmIGlzX2NhKGNlcnQpOgogICAgYmMgPSBjZXJ0LmJhc2ljX2NvbnN0cmFpbnRzX3ZhbHVlCiAgICByZXR1cm4gYm9vbChiYyBhbmQgYmNbImNhIl0ubmF0aXZlKQoKCiMgLS0tLSBwYWdlcyBhbmQgYm94ZXMgLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLQoKZGVmIHBhcnNlX3BhZ2VzKHNwZWMsIG4pOgogICAgIiIiJ2FsbCcsICdmaXJzdCcsICdsYXN0Jywgb3IgJzEsMyw1LTcnIC0+IHNvcnRlZCAwLWJhc2VkIHBhZ2UgaW5kZXhlczsgcmFpc2VzIFZhbHVlRXJyb3Igd2hlbiBpbnZhbGlkLiIiIgogICAgc3BlYyA9IChzcGVjIG9yICJsYXN0Iikuc3RyaXAoKS5sb3dlcigpLnJlcGxhY2UoIiAiLCAiIikKICAgIGlmIHNwZWMgPT0gImFsbCI6CiAgICAgICAgcmV0dXJuIGxpc3QocmFuZ2UobikpCiAgICBvdXQgPSBzZXQoKQogICAgZm9yIHBhcnQgaW4gc3BlYy5zcGxpdCgiLCIpOgogICAgICAgIGlmIHBhcnQgaW4gKCJmaXJzdCIsICJsYXN0Iik6CiAgICAgICAgICAgIG91dC5hZGQoMCBpZiBwYXJ0ID09ICJmaXJzdCIgZWxzZSBuIC0gMSkKICAgICAgICAgICAgY29udGludWUKICAgICAgICBtID0gcmUuZnVsbG1hdGNoKHIiKFxkKykoPzotKFxkK3xsYXN0KSk/IiwgcGFydCkKICAgICAgICBpZiBub3QgbToKICAgICAgICAgICAgcmFpc2UgVmFsdWVFcnJvcihmIid7cGFydH0nIGlzIG5vdCBhIHBhZ2UgbnVtYmVyIG9yIHJhbmdlIikKICAgICAgICBsbyA9IGludChtLmdyb3VwKDEpKQogICAgICAgIGhpID0gbG8gaWYgbS5ncm91cCgyKSBpcyBOb25lIGVsc2UgKG4gaWYgbS5ncm91cCgyKSA9PSAibGFzdCIgZWxzZSBpbnQobS5ncm91cCgyKSkpCiAgICAgICAgaWYgbG8gPiBoaToKICAgICAgICAgICAgbG8sIGhpID0gaGksIGxvCiAgICAgICAgaWYgbG8gPCAxIG9yIGhpID4gbjoKICAgICAgICAgICAgcmFpc2UgVmFsdWVFcnJvcihmInBhZ2Uge2xvIGlmIGxvIDwgMSBlbHNlIGhpfSBpcyBub3QgaW4gdGhlIGRvY3VtZW50IChpdCBoYXMge259KSIpCiAgICAgICAgb3V0LnVwZGF0ZShyYW5nZShsbyAtIDEsIGhpKSkKICAgIGlmIG5vdCBvdXQ6CiAgICAgICAgcmFpc2UgVmFsdWVFcnJvcigibm8gcGFnZXMgY2hvc2VuIikKICAgIHJldHVybiBzb3J0ZWQob3V0KQoKCmRlZiBwYXJzZV9ib3godGV4dCk6CiAgICB0cnk6CiAgICAgICAgdiA9IFtmbG9hdCh4KSBmb3IgeCBpbiB0ZXh0LnNwbGl0KCIsIildCiAgICBleGNlcHQgVmFsdWVFcnJvcjoKICAgICAgICB2ID0gW10KICAgIGlmIGxlbih2KSAhPSA0IG9yIG5vdCBhbGwoMCA8PSB4IDw9IDEgZm9yIHggaW4gdikgb3IgdlswXSA9PSB2WzJdIG9yIHZbMV0gPT0gdlszXToKICAgICAgICByYWlzZSBWYWx1ZUVycm9yKCItLWJveCBuZWVkcyBmb3VyIGZyYWN0aW9ucyAwLi4xOiBsZWZ0LHRvcCxyaWdodCxib3R0b20iKQogICAgcmV0dXJuIFttaW4odlswXSwgdlsyXSksIG1pbih2WzFdLCB2WzNdKSwgbWF4KHZbMF0sIHZbMl0pLCBtYXgodlsxXSwgdlszXSldCgoKZGVmIHBhZ2VfZ2VvbWV0cnkodywgcGFnZV9peCk6CiAgICAiIiJUaGUgcGFnZSdzIHZpc2libGUgYXJlYSAoQ3JvcEJveCwgZWxzZSBNZWRpYUJveCwgaW5oZXJpdGVkIG9uZXMgaW5jbHVkZWQpIGFuZCBpdHMgL1JvdGF0ZS4iIiIKICAgIGJveCwgcm90ID0gTm9uZSwgTm9uZQogICAgdHJ5OgogICAgICAgIG5vZGUgPSB3LmZpbmRfcGFnZV9mb3JfbW9kaWZpY2F0aW9uKHBhZ2VfaXgpWzBdLmdldF9vYmplY3QoKQogICAgICAgIHdoaWxlIG5vZGUgaXMgbm90IE5vbmU6CiAgICAgICAgICAgIGZvciBrZXkgaW4gKCIvQ3JvcEJveCIsICIvTWVkaWFCb3giKToKICAgICAgICAgICAgICAgIGlmIGJveCBpcyBOb25lIGFuZCBrZXkgaW4gbm9kZToKICAgICAgICAgICAgICAgICAgICBib3ggPSBbZmxvYXQoeCkgZm9yIHggaW4gbm9kZVtrZXldXQogICAgICAgICAgICBpZiByb3QgaXMgTm9uZSBhbmQgIi9Sb3RhdGUiIGluIG5vZGU6CiAgICAgICAgICAgICAgICByb3QgPSBpbnQobm9kZVsiL1JvdGF0ZSJdKSAlIDM2MAogICAgICAgICAgICBwYXJlbnQgPSBub2RlLmdldCgiL1BhcmVudCIpCiAgICAgICAgICAgIG5vZGUgPSBwYXJlbnQuZ2V0X29iamVjdCgpIGlmIHBhcmVudCBpcyBub3QgTm9uZSBlbHNlIE5vbmUKICAgIGV4Y2VwdCBFeGNlcHRpb246CiAgICAgICAgcGFzcwogICAgYm94ID0gYm94IG9yIFswLjAsIDAuMCwgNTk1LjAsIDg0Mi4wXQogICAgcmV0dXJuIFttaW4oYm94WzBdLCBib3hbMl0pLCBtaW4oYm94WzFdLCBib3hbM10pLCBtYXgoYm94WzBdLCBib3hbMl0pLCBtYXgoYm94WzFdLCBib3hbM10pXSwgKHJvdCBvciAwKQoKCmRlZiBmcmFjX3RvX3JlY3QoZnJhYywgZ2VvbSk6CiAgICAiIiJBIGJveCBkcmF3biBvbiB0aGUgcGFnZSBhcyBpdCBpcyBzaG93biAoZnJhY3Rpb25zLCB0b3AtbGVmdCBvcmlnaW4pIC0+IFBERiB1c2VyLXNwYWNlIHJlY3RhbmdsZS4iIiIKICAgIChsbHgsIGxseSwgdXJ4LCB1cnkpLCByb3QgPSBnZW9tCiAgICBXLCBIID0gdXJ4IC0gbGx4LCB1cnkgLSBsbHkKCiAgICBkZWYgcHQoZngsIGZ5KToKICAgICAgICBpZiByb3QgPT0gOTA6CiAgICAgICAgICAgIHJldHVybiBsbHggKyBmeSAqIFcsIGxseSArIGZ4ICogSAogICAgICAgIGlmIHJvdCA9PSAxODA6CiAgICAgICAgICAgIHJldHVybiB1cnggLSBmeCAqIFcsIGxseSArIGZ5ICogSAogICAgICAgIGlmIHJvdCA9PSAyNzA6CiAgICAgICAgICAgIHJldHVybiB1cnggLSBmeSAqIFcsIHVyeSAtIGZ4ICogSAogICAgICAgIHJldHVybiBsbHggKyBmeCAqIFcsIHVyeSAtIGZ5ICogSAoKICAgICh4MCwgeTApLCAoeDEsIHkxKSA9IHB0KGZyYWNbMF0sIGZyYWNbMV0pLCBwdChmcmFjWzJdLCBmcmFjWzNdKQogICAgcmV0dXJuIChpbnQobWluKHgwLCB4MSkpLCBpbnQobWluKHkwLCB5MSkpLCBpbnQocm91bmQobWF4KHgwLCB4MSkpKSwgaW50KHJvdW5kKG1heCh5MCwgeTEpKSkpCgoKZGVmIGNvcm5lcl9mcmFjKHBvcywgZ2VvbSk6CiAgICAiIiJUaGUgZml4ZWQtc2l6ZSBkZWZhdWx0IGJveCBpbiBhIGNvcm5lciBvZiB0aGUgcGFnZSBhcyBpdCBpcyBzaG93biwgYXMgZnJhY3Rpb25zLiIiIgogICAgKGxseCwgbGx5LCB1cngsIHVyeSksIHJvdCA9IGdlb20KICAgIFcsIEggPSB1cnggLSBsbHgsIHVyeSAtIGxseQogICAgaWYgcm90IGluICg5MCwgMjcwKToKICAgICAgICBXLCBIID0gSCwgVwogICAgYncsIGJoLCBteCwgbXkgPSBCT1hfVyAvIFcsIEJPWF9IIC8gSCwgTUFSR0lOIC8gVywgTUFSR0lOIC8gSAogICAgeDAgPSAxIC0gbXggLSBidyBpZiBwb3MgaW4gKCJiciIsICJ0ciIpIGVsc2UgbXgKICAgIHkwID0gMSAtIG15IC0gYmggaWYgcG9zIGluICgiYnIiLCAiYmwiKSBlbHNlIG15CiAgICByZXR1cm4gW3gwLCB5MCwgeDAgKyBidywgeTAgKyBiaF0KCgojIC0tLS0gc2lnbmluZyAtLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0KCmRlZiBzdGFtcF9zdHlsZShhKToKICAgIGZyb20gcHloYW5rby5zdGFtcCBpbXBvcnQgVGV4dFN0YW1wU3R5bGUKICAgIGxpbmVzID0gIkRpZ2l0YWxseSBzaWduZWQgYnkgJShzaWduZXIpc1xuRGF0ZTogJSh0cylzIgogICAgaWYgYS5yZWFzb246CiAgICAgICAgbGluZXMgKz0gIlxuUmVhc29uOiAiICsgYS5yZWFzb24ucmVwbGFjZSgiJSIsICIlJSIpCiAgICBpZiBhLmxvY2F0aW9uOgogICAgICAgIGxpbmVzICs9ICJcbkxvY2F0aW9uOiAiICsgYS5sb2NhdGlvbi5yZXBsYWNlKCIlIiwgIiUlIikKICAgIHJldHVybiBUZXh0U3RhbXBTdHlsZShzdGFtcF90ZXh0PWxpbmVzLCB0aW1lc3RhbXBfZm9ybWF0PSIlZC0lbS0lWSAlSDolTTolUyAleiIsIGJvcmRlcl93aWR0aD0xKQoKCmRlZiBzaWduX29uY2UoYSwgZGF0YSwgcGFnZV9peCwgc2lnbmVyKToKICAgICIiIkFkZCBvbmUgc2lnbmF0dXJlIChhIGJveCBvbiBwYWdlX2l4LCBvciBpbnZpc2libGUgd2hlbiBwYWdlX2l4IGlzIE5vbmUpIHRvIHRoZSBQREYgYnl0ZXM7IHJldHVybiBuZXcgYnl0ZXMuIiIiCiAgICBmcm9tIHB5aGFua28ucGRmX3V0aWxzLmluY3JlbWVudGFsX3dyaXRlciBpbXBvcnQgSW5jcmVtZW50YWxQZGZGaWxlV3JpdGVyCiAgICBmcm9tIHB5aGFua28uc2lnbiBpbXBvcnQgZmllbGRzLCBzaWduZXJzCiAgICB3ID0gSW5jcmVtZW50YWxQZGZGaWxlV3JpdGVyKGlvLkJ5dGVzSU8oZGF0YSksIHN0cmljdD1GYWxzZSkKICAgIHVzZWQgPSBzZXQoKQogICAgdHJ5OgogICAgICAgIGZvciB4IGluIHcucm9vdFsiL0Fjcm9Gb3JtIl1bIi9GaWVsZHMiXToKICAgICAgICAgICAgdXNlZC5hZGQoc3RyKHguZ2V0X29iamVjdCgpLmdldCgiL1QiKSkpCiAgICBleGNlcHQgRXhjZXB0aW9uOgogICAgICAgIHBhc3MKICAgIGZpZWxkID0gbmV4dChmIlNpZ25hdHVyZXtpfSIgZm9yIGkgaW4gcmFuZ2UoMSwgOTk5OSkgaWYgZiJTaWduYXR1cmV7aX0iIG5vdCBpbiB1c2VkKQogICAgc3R5bGUgPSBOb25lCiAgICBpZiBwYWdlX2l4IGlzIE5vbmU6CiAgICAgICAgc3BlYyA9IGZpZWxkcy5TaWdGaWVsZFNwZWMoZmllbGQpCiAgICBlbHNlOgogICAgICAgIGdlb20gPSBwYWdlX2dlb21ldHJ5KHcsIHBhZ2VfaXgpCiAgICAgICAgZnJhYyA9IGEuYm94IGlmIGEuYm94IGVsc2UgY29ybmVyX2ZyYWMoYS5wb3MsIGdlb20pCiAgICAgICAgc3BlYyA9IGZpZWxkcy5TaWdGaWVsZFNwZWMoZmllbGQsIG9uX3BhZ2U9cGFnZV9peCwgYm94PWZyYWNfdG9fcmVjdChmcmFjLCBnZW9tKSkKICAgICAgICBzdHlsZSA9IHN0YW1wX3N0eWxlKGEpCiAgICBtZXRhID0gc2lnbmVycy5QZGZTaWduYXR1cmVNZXRhZGF0YShmaWVsZF9uYW1lPWZpZWxkLCByZWFzb249YS5yZWFzb24sIGxvY2F0aW9uPWEubG9jYXRpb24sCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBtZF9hbGdvcml0aG09InNoYTI1NiIsIHN1YmZpbHRlcj1maWVsZHMuU2lnU2VlZFN1YkZpbHRlci5QQURFUykKICAgIG91dCA9IGlvLkJ5dGVzSU8oKQogICAgc2lnbmVycy5QZGZTaWduZXIobWV0YSwgc2lnbmVyLCBzdGFtcF9zdHlsZT1zdHlsZSwgbmV3X2ZpZWxkX3NwZWM9c3BlYykuc2lnbl9wZGYodywgb3V0cHV0PW91dCkKICAgIHJldHVybiBvdXQuZ2V0dmFsdWUoKQoKCmRlZiBzaWduX2ZpbGUoYSwgc3JjLCBvdXQsIHNpZ25lciwgcGFnZXMpOgogICAgd2l0aCBvcGVuKHNyYywgInJiIikgYXMgZjoKICAgICAgICBkYXRhID0gZi5yZWFkKCkKICAgIHRhcmdldHMgPSBbTm9uZV0gaWYgYS5pbnZpc2libGUgZWxzZSBwYWdlcwogICAgZm9yIGssIGl4IGluIGVudW1lcmF0ZSh0YXJnZXRzLCAxKToKICAgICAgICBpZiBsZW4odGFyZ2V0cykgPiAxOgogICAgICAgICAgICBzYXkoZiJzaWduaW5nIDogcGFnZSB7aXggKyAxfSAgKHtrfSBvZiB7bGVuKHRhcmdldHMpfSkiKQogICAgICAgIGRhdGEgPSBzaWduX29uY2UoYSwgZGF0YSwgaXgsIHNpZ25lcikKICAgICMgYSBuZXcsIHVucHJlZGljdGFibGUgdGVtcCBmaWxlIGJlc2lkZSB0aGUgb3V0cHV0IChPX0VYQ0w6IG5ldmVyIGZvbGxvd3MgYSBwbGFudGVkIGxpbmspLCB0aGVuIHJlbmFtZWQKICAgIGZkLCB0bXAgPSB0ZW1wZmlsZS5ta3N0ZW1wKHByZWZpeD0iLnNpZ24tcGRmLSIsIHN1ZmZpeD0iLnBhcnQiLCBkaXI9b3MucGF0aC5kaXJuYW1lKG91dCkgb3IgIi4iKQogICAgdHJ5OgogICAgICAgIHdpdGggb3MuZmRvcGVuKGZkLCAid2IiKSBhcyBvOgogICAgICAgICAgICBvLndyaXRlKGRhdGEpCiAgICAgICAgb3MuY2htb2QodG1wLCAwbzY0NCAmIH5jdXJyZW50X3VtYXNrKCkpCiAgICBleGNlcHQgQmFzZUV4Y2VwdGlvbjoKICAgICAgICBpZiBvcy5wYXRoLmV4aXN0cyh0bXApOgogICAgICAgICAgICBvcy5yZW1vdmUodG1wKQogICAgICAgIHJhaXNlCiAgICBvcy5yZXBsYWNlKHRtcCwgb3V0KQoKCmRlZiByZXBvcnQob3V0KToKICAgIHNheShmInNpZ25lZCAgOiB7b3V0fSIpCiAgICBpZiBzaHV0aWwud2hpY2goInBkZnNpZyIpOgogICAgICAgIHIgPSBzdWJwcm9jZXNzLnJ1bihbInBkZnNpZyIsIG91dF0sIGNhcHR1cmVfb3V0cHV0PVRydWUsIHRleHQ9VHJ1ZSkKICAgICAgICB0b3RhbCA9IGxlbihyZS5maW5kYWxsKHIiXlNpZ25hdHVyZSAjXGQrIiwgci5zdGRvdXQsIHJlLk0pKQogICAgICAgIGdvb2QgPSByLnN0ZG91dC5jb3VudCgiU2lnbmF0dXJlIFZhbGlkYXRpb246IFNpZ25hdHVyZSBpcyBWYWxpZCIpCiAgICAgICAgb2sgPSB0b3RhbCA+IDAgYW5kIGdvb2QgPT0gdG90YWwKICAgICAgICBzYXkoImNoZWNrICAgOiAiICsgKGYieyd0aGUgc2lnbmF0dXJlIGlzJyBpZiB0b3RhbCA9PSAxIGVsc2UgZidhbGwge3RvdGFsfSBzaWduYXR1cmVzIGFyZSd9IHZhbGlkIiBpZiBvawogICAgICAgICAgICAgICAgICAgICAgICAgICAgZWxzZSAicGRmc2lnIGNvdWxkIG5vdCBjb25maXJtIGl0OlxuIiArIHIuc3Rkb3V0LnN0cmlwKCkpKQogICAgaWYgR1VJIGFuZCBzaHV0aWwud2hpY2goIm5vdGlmeS1zZW5kIik6CiAgICAgICAgc3VicHJvY2Vzcy5ydW4oWyJub3RpZnktc2VuZCIsICJQREYgc2lnbmVkIiwgb3MucGF0aC5iYXNlbmFtZShvdXQpXSkKICAgIGlmIEdVSSBhbmQgb3MuZW52aXJvbi5nZXQoIlNJR05fUERGX09QRU4iLCAiMSIpID09ICIxIiBhbmQgc2h1dGlsLndoaWNoKCJwYXBlcnMiKTogICAjIHNob3cgdGhlIHJlc3VsdAogICAgICAgIHN1YnByb2Nlc3MuUG9wZW4oWyJwYXBlcnMiLCBvdXRdLCBzdGRvdXQ9c3VicHJvY2Vzcy5ERVZOVUxMLCBzdGRlcnI9c3VicHJvY2Vzcy5ERVZOVUxMLCBzdGFydF9uZXdfc2Vzc2lvbj1UcnVlKQoKCmRlZiBjb3VudF9wYWdlcyhzcmMpOgogICAgZnJvbSBweWhhbmtvLnBkZl91dGlscy5yZWFkZXIgaW1wb3J0IFBkZkZpbGVSZWFkZXIKICAgIHdpdGggb3BlbihzcmMsICJyYiIpIGFzIGY6CiAgICAgICAgcmV0dXJuIGludChQZGZGaWxlUmVhZGVyKGYsIHN0cmljdD1GYWxzZSkucm9vdFsiL1BhZ2VzIl1bIi9Db3VudCJdKQoKCiMgLS0tLSB0aGUgZHJhdyB3aW5kb3cgKHJ1bnMgdW5kZXIgdGhlIHN5c3RlbSBQeXRob24sIHdoaWNoIGhhcyBHVEs7IHRoZSB2ZW52IGRvZXMgbm90KSAtLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0KCmRlZiBydW5fcGlja2VyKHNyYywgbl9wYWdlcywgYSk6CiAgICAiIiJTaG93IHRoZSBkcmF3IHdpbmRvdzsgcmV0dXJucyAoYm94IGZyYWN0aW9ucywgcGFnZXMgc3BlYywgcmVhc29uLCBsb2NhdGlvbiksIG9yIGV4aXRzIHdoZW4gY2FuY2VsbGVkLiIiIgogICAgcHkgPSAiL3Vzci9iaW4vcHl0aG9uMyIKICAgIGlmIG5vdCAob3MucGF0aC5leGlzdHMocHkpIGFuZCBzaHV0aWwud2hpY2goInBkZnRvcHBtIikpOgogICAgICAgIGZhaWwoInRoZSBkcmF3IHdpbmRvdyBuZWVkcyB0aGUgc3lzdGVtIFB5dGhvbiB3aXRoIEdUSyA0IGFuZCBwb3BwbGVyLXV0aWxzIChwZGZ0b3BwbSkiKQogICAgc3RhcnQgPSAoYS5wYWdlIGlmIGEucGFnZSBlbHNlIG5fcGFnZXMpCiAgICByID0gc3VicHJvY2Vzcy5ydW4oW3B5LCAiLUkiLCBvcy5wYXRoLmFic3BhdGgoX19maWxlX18pLCAiLS1waWNrLXVpPSIgKyBzcmMsIGYiLS1waWNrLXBhZ2VzPXtuX3BhZ2VzfSIsCiAgICAgICAgICAgICAgICAgICAgICAgIGYiLS1waWNrLXN0YXJ0PXtzdGFydH0iLCAiLS1waWNrLXNwZWM9IiArIChhLnBhZ2VzIG9yICIiKSwKICAgICAgICAgICAgICAgICAgICAgICAgIi0tcGljay1ib3g9IiArICgiLCIuam9pbihtYXAoc3RyLCBhLmJveCkpIGlmIGEuYm94IGVsc2UgIiIpLAogICAgICAgICAgICAgICAgICAgICAgICAiLS1yZWFzb249IiArIChhLnJlYXNvbiBvciAiIiksICItLWxvY2F0aW9uPSIgKyAoYS5sb2NhdGlvbiBvciAiIildLAogICAgICAgICAgICAgICAgICAgICAgIHN0ZG91dD1zdWJwcm9jZXNzLlBJUEUsIHRleHQ9VHJ1ZSkKICAgIGlmIHIucmV0dXJuY29kZSA9PSAyOgogICAgICAgIHN5cy5leGl0KDApICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAjIGNhbmNlbGxlZAogICAgdHJ5OgogICAgICAgIHJlcyA9IGpzb24ubG9hZHMoci5zdGRvdXQpCiAgICBleGNlcHQgVmFsdWVFcnJvcjoKICAgICAgICBmYWlsKCJ0aGUgZHJhdyB3aW5kb3cgZGlkIG5vdCBvcGVuIChHVEsgNCBmb3IgUHl0aG9uIG1pc3Npbmc/IFVidW50dTogc3VkbyBhcHQgaW5zdGFsbCBnaXIxLjItZ3RrLTQuMCkiKQogICAgcmV0dXJuIHJlc1siYm94Il0sIHJlc1sicGFnZXMiXSwgcmVzLmdldCgicmVhc29uIikgb3IgTm9uZSwgcmVzLmdldCgibG9jYXRpb24iKSBvciBOb25lCgoKZGVmIHBpY2tlcl9tYWluKGFyZ3YpOgogICAgaW1wb3J0IGdpCiAgICBnaS5yZXF1aXJlX3ZlcnNpb24oIkd0ayIsICI0LjAiKQogICAgZ2kucmVxdWlyZV92ZXJzaW9uKCJHZGsiLCAiNC4wIikKICAgIGZyb20gZ2kucmVwb3NpdG9yeSBpbXBvcnQgR2RrLCBHdGsKCiAgICBhcCA9IGFyZ3BhcnNlLkFyZ3VtZW50UGFyc2VyKCkKICAgIGFwLmFkZF9hcmd1bWVudCgiLS1waWNrLXVpIikKICAgIGFwLmFkZF9hcmd1bWVudCgiLS1waWNrLXBhZ2VzIiwgdHlwZT1pbnQpCiAgICBhcC5hZGRfYXJndW1lbnQoIi0tcGljay1zdGFydCIsIHR5cGU9aW50KQogICAgYXAuYWRkX2FyZ3VtZW50KCItLXBpY2stc3BlYyIsIGRlZmF1bHQ9IiIpCiAgICBhcC5hZGRfYXJndW1lbnQoIi0tcGljay1ib3giLCBkZWZhdWx0PSIiKQogICAgYXAuYWRkX2FyZ3VtZW50KCItLXJlYXNvbiIsIGRlZmF1bHQ9IiIpCiAgICBhcC5hZGRfYXJndW1lbnQoIi0tbG9jYXRpb24iLCBkZWZhdWx0PSIiKQogICAgbyA9IGFwLnBhcnNlX2FyZ3MoYXJndikKICAgIHNyYywgbiA9IG8ucGlja191aSwgby5waWNrX3BhZ2VzCiAgICB0bXBkaXIgPSB0ZW1wZmlsZS5ta2R0ZW1wKHByZWZpeD0ic2lnbi1wZGYtdmlldy0iKQogICAgc3QgPSB7InBhZ2UiOiBtYXgoMSwgbWluKG8ucGlja19zdGFydCwgbikpLCAiYm94IjogTm9uZSwgImRyYWciOiBOb25lLCAicmVzdWx0IjogTm9uZX0KICAgIHN0WyJib3giXSA9IHBhcnNlX2JveChvLnBpY2tfYm94KSBpZiBvLnBpY2tfYm94IGVsc2UgTm9uZQogICAgTUFYUFggPSA3ODAKCiAgICBkZWYgcmVuZGVyKHApOgogICAgICAgIGJhc2UgPSBvcy5wYXRoLmpvaW4odG1wZGlyLCBmInB7cH0iKQogICAgICAgIGlmIG5vdCBvcy5wYXRoLmV4aXN0cyhiYXNlICsgIi5wbmciKToKICAgICAgICAgICAgc3VicHJvY2Vzcy5ydW4oWyJwZGZ0b3BwbSIsICItcG5nIiwgIi1zY2FsZS10byIsIHN0cihNQVhQWCksICItZiIsIHN0cihwKSwgIi1sIiwgc3RyKHApLCAiLXNpbmdsZWZpbGUiLAogICAgICAgICAgICAgICAgICAgICAgICAgICAgc3JjLCBiYXNlXSwgY2hlY2s9RmFsc2UsIHN0ZG91dD1zdWJwcm9jZXNzLkRFVk5VTEwsIHN0ZGVycj1zdWJwcm9jZXNzLkRFVk5VTEwpCiAgICAgICAgdHJ5OgogICAgICAgICAgICByZXR1cm4gR2RrLlRleHR1cmUubmV3X2Zyb21fZmlsZW5hbWUoYmFzZSArICIucG5nIikKICAgICAgICBleGNlcHQgRXhjZXB0aW9uOgogICAgICAgICAgICByZXR1cm4gTm9uZQoKICAgIGRlZiBkZWZhdWx0X2JveChzdXJmKToKICAgICAgICBXLCBIID0gc3VyZi5nZXRfd2lkdGgoKSwgc3VyZi5nZXRfaGVpZ2h0KCkgICAgICMgdGhlIGJveCBpcyBrZXB0IGFzIGZyYWN0aW9uczsgc2l6ZSBpdCBhcyBvbiBBNAogICAgICAgIHB3LCBwaCA9ICg1OTUuMCwgODQyLjApIGlmIEggPj0gVyBlbHNlICg4NDIuMCwgNTk1LjApCiAgICAgICAgYncsIGJoLCBteCwgbXkgPSBCT1hfVyAvIHB3LCBCT1hfSCAvIHBoLCBNQVJHSU4gLyBwdywgTUFSR0lOIC8gcGgKICAgICAgICByZXR1cm4gWzEgLSBteCAtIGJ3LCAxIC0gbXkgLSBiaCwgMSAtIG14LCAxIC0gbXldCgogICAgYXBwID0gR3RrLkFwcGxpY2F0aW9uKGFwcGxpY2F0aW9uX2lkPU5vbmUpCgogICAgZGVmIG9uX2FjdGl2YXRlKGFwcCk6CiAgICAgICAgd2luID0gR3RrLkFwcGxpY2F0aW9uV2luZG93KGFwcGxpY2F0aW9uPWFwcCwgdGl0bGU9IlNpZ24gUERGIC0gZHJhdyB0aGUgc2lnbmF0dXJlIGJveCIpCiAgICAgICAgb3V0ZXIgPSBHdGsuQm94KG9yaWVudGF0aW9uPUd0ay5PcmllbnRhdGlvbi5WRVJUSUNBTCwgc3BhY2luZz04LCBtYXJnaW5fdG9wPTEwLCBtYXJnaW5fYm90dG9tPTEwLAogICAgICAgICAgICAgICAgICAgICAgICBtYXJnaW5fc3RhcnQ9MTAsIG1hcmdpbl9lbmQ9MTApCiAgICAgICAgd2luLnNldF9jaGlsZChvdXRlcikKICAgICAgICBoaW50ID0gR3RrLkxhYmVsKGxhYmVsPSJEcmFnIG9uIHRoZSBwYWdlIHRvIGRyYXcgdGhlIHNpZ25hdHVyZSBib3guIERyYWcgaW5zaWRlIHRoZSBib3ggdG8gbW92ZSBpdC4iLCB4YWxpZ249MCkKICAgICAgICBvdXRlci5hcHBlbmQoaGludCkKCiAgICAgICAgY3NzID0gR3RrLkNzc1Byb3ZpZGVyKCkKICAgICAgICBjc3MubG9hZF9mcm9tX3N0cmluZygiLnNpZ2JveCB7IGJvcmRlcjogMnB4IHNvbGlkICMxYTY2ZTY7IGJhY2tncm91bmQ6IHJnYmEoMjYsMTAyLDIzMCwwLjE4KTsgfSIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAiIC5zaWdib3ggbGFiZWwgeyBjb2xvcjogIzFhNjZlNjsgZm9udC1zaXplOiAxMXB4OyB9IikKICAgICAgICBHdGsuU3R5bGVDb250ZXh0LmFkZF9wcm92aWRlcl9mb3JfZGlzcGxheSh3aW4uZ2V0X2Rpc3BsYXkoKSwgY3NzLCBHdGsuU1RZTEVfUFJPVklERVJfUFJJT1JJVFlfQVBQTElDQVRJT04pCiAgICAgICAgYXJlYSA9IEd0ay5GaXhlZChoYWxpZ249R3RrLkFsaWduLkNFTlRFUiwgdmFsaWduPUd0ay5BbGlnbi5DRU5URVIpCiAgICAgICAgcGljID0gR3RrLlBpY3R1cmUoY2FuX3Nocmluaz1GYWxzZSkKICAgICAgICBhcmVhLnB1dChwaWMsIDAsIDApCiAgICAgICAgYm94dyA9IEd0ay5Cb3goKQogICAgICAgIGJveHcuYWRkX2Nzc19jbGFzcygic2lnYm94IikKICAgICAgICBib3h3LmFwcGVuZChHdGsuTGFiZWwobGFiZWw9IlNpZ25hdHVyZSIsIHhhbGlnbj0wLCB2YWxpZ249R3RrLkFsaWduLlNUQVJULCBtYXJnaW5fc3RhcnQ9NCwKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgZWxsaXBzaXplPTMpKSAgICAgICMgUGFuZ28uRWxsaXBzaXplTW9kZS5FTkQKICAgICAgICBhcmVhLnB1dChib3h3LCAwLCAwKQogICAgICAgIGZyYW1lID0gR3RrLkZyYW1lKGNoaWxkPWFyZWEsIGhhbGlnbj1HdGsuQWxpZ24uQ0VOVEVSKQogICAgICAgIG91dGVyLmFwcGVuZChmcmFtZSkKICAgICAgICBzaXplID0geyJ3IjogMSwgImgiOiAxfQoKICAgICAgICBkZWYgcGxhY2VfYm94KCk6CiAgICAgICAgICAgIGIgPSBzdFsiYm94Il0KICAgICAgICAgICAgYm94dy5zZXRfdmlzaWJsZShib29sKGIpKQogICAgICAgICAgICBpZiBiOgogICAgICAgICAgICAgICAgdywgaCA9IHNpemVbInciXSwgc2l6ZVsiaCJdCiAgICAgICAgICAgICAgICBhcmVhLm1vdmUoYm94dywgYlswXSAqIHcsIGJbMV0gKiBoKQogICAgICAgICAgICAgICAgYm94dy5zZXRfc2l6ZV9yZXF1ZXN0KG1heCg0LCBpbnQoKGJbMl0gLSBiWzBdKSAqIHcpKSwgbWF4KDQsIGludCgoYlszXSAtIGJbMV0pICogaCkpKQoKICAgICAgICBkZWYgc2hvd19wYWdlKHApOgogICAgICAgICAgICBzdFsicGFnZSJdID0gcAogICAgICAgICAgICBzID0gcmVuZGVyKHApCiAgICAgICAgICAgIGlmIHM6CiAgICAgICAgICAgICAgICBzaXplWyJ3Il0sIHNpemVbImgiXSA9IHMuZ2V0X3dpZHRoKCksIHMuZ2V0X2hlaWdodCgpCiAgICAgICAgICAgICAgICBwaWMuc2V0X3BhaW50YWJsZShzKQogICAgICAgICAgICAgICAgcGljLnNldF9zaXplX3JlcXVlc3Qoc2l6ZVsidyJdLCBzaXplWyJoIl0pCiAgICAgICAgICAgICAgICBpZiBzdFsiYm94Il0gaXMgTm9uZToKICAgICAgICAgICAgICAgICAgICBzdFsiYm94Il0gPSBkZWZhdWx0X2JveChzKQogICAgICAgICAgICBwYWdlX2xibC5zZXRfbGFiZWwoZiJQYWdlIHtwfSBvZiB7bn0iKQogICAgICAgICAgICB0aGlzX3JiLnNldF9sYWJlbChmIlRoaXMgcGFnZSAoe3B9KSIpCiAgICAgICAgICAgIHByZXZfYi5zZXRfc2Vuc2l0aXZlKHAgPiAxKQogICAgICAgICAgICBuZXh0X2Iuc2V0X3NlbnNpdGl2ZShwIDwgbikKICAgICAgICAgICAgcGxhY2VfYm94KCkKCiAgICAgICAgZHJhZyA9IEd0ay5HZXN0dXJlRHJhZyhwcm9wYWdhdGlvbl9waGFzZT1HdGsuUHJvcGFnYXRpb25QaGFzZS5DQVBUVVJFKQoKICAgICAgICBkZWYgY2xhbXAodik6CiAgICAgICAgICAgIHJldHVybiBtYXgoMC4wLCBtaW4oMS4wLCB2KSkKCiAgICAgICAgZGVmIGRfYmVnaW4oZywgeCwgeSk6CiAgICAgICAgICAgIHcsIGggPSBzaXplWyJ3Il0sIHNpemVbImgiXQogICAgICAgICAgICBmeCwgZnkgPSB4IC8gdywgeSAvIGgKICAgICAgICAgICAgYiA9IHN0WyJib3giXQogICAgICAgICAgICBpbnNpZGUgPSBiIGFuZCBiWzBdIDw9IGZ4IDw9IGJbMl0gYW5kIGJbMV0gPD0gZnkgPD0gYlszXQogICAgICAgICAgICBzdFsiZHJhZyJdID0gKCJtb3ZlIiBpZiBpbnNpZGUgZWxzZSAibmV3IiwgZngsIGZ5LCBsaXN0KGIpIGlmIGIgZWxzZSBOb25lKQoKICAgICAgICBkZWYgZF91cGRhdGUoZywgZHgsIGR5KToKICAgICAgICAgICAgaWYgbm90IHN0WyJkcmFnIl06CiAgICAgICAgICAgICAgICByZXR1cm4KICAgICAgICAgICAgbW9kZSwgZngsIGZ5LCBiMCA9IHN0WyJkcmFnIl0KICAgICAgICAgICAgdywgaCA9IHNpemVbInciXSwgc2l6ZVsiaCJdCiAgICAgICAgICAgIGV4LCBleSA9IGNsYW1wKGZ4ICsgZHggLyB3KSwgY2xhbXAoZnkgKyBkeSAvIGgpCiAgICAgICAgICAgIGlmIG1vZGUgPT0gIm1vdmUiOgogICAgICAgICAgICAgICAgYncsIGJoID0gYjBbMl0gLSBiMFswXSwgYjBbM10gLSBiMFsxXQogICAgICAgICAgICAgICAgbnggPSBtYXgoMC4wLCBtaW4oMSAtIGJ3LCBiMFswXSArIGR4IC8gdykpCiAgICAgICAgICAgICAgICBueSA9IG1heCgwLjAsIG1pbigxIC0gYmgsIGIwWzFdICsgZHkgLyBoKSkKICAgICAgICAgICAgICAgIHN0WyJib3giXSA9IFtueCwgbnksIG54ICsgYncsIG55ICsgYmhdCiAgICAgICAgICAgIGVsaWYgYWJzKGR4KSA+IDYgYW5kIGFicyhkeSkgPiA2OgogICAgICAgICAgICAgICAgc3RbImJveCJdID0gW21pbihmeCwgZXgpLCBtaW4oZnksIGV5KSwgbWF4KGZ4LCBleCksIG1heChmeSwgZXkpXQogICAgICAgICAgICBwbGFjZV9ib3goKQoKICAgICAgICBkcmFnLmNvbm5lY3QoImRyYWctYmVnaW4iLCBkX2JlZ2luKQogICAgICAgIGRyYWcuY29ubmVjdCgiZHJhZy11cGRhdGUiLCBkX3VwZGF0ZSkKICAgICAgICBkcmFnLmNvbm5lY3QoImRyYWctZW5kIiwgbGFtYmRhIGcsIGR4LCBkeTogc3QudXBkYXRlKGRyYWc9Tm9uZSkpCiAgICAgICAgYXJlYS5hZGRfY29udHJvbGxlcihkcmFnKQoKICAgICAgICBuYXYgPSBHdGsuQm94KHNwYWNpbmc9NiwgaGFsaWduPUd0ay5BbGlnbi5DRU5URVIpCiAgICAgICAgcHJldl9iID0gR3RrLkJ1dHRvbihsYWJlbD0iPCBQcmV2aW91cyIpCiAgICAgICAgbmV4dF9iID0gR3RrLkJ1dHRvbihsYWJlbD0iTmV4dCA+IikKICAgICAgICBwYWdlX2xibCA9IEd0ay5MYWJlbCgpCiAgICAgICAgcHJldl9iLmNvbm5lY3QoImNsaWNrZWQiLCBsYW1iZGEgYjogc2hvd19wYWdlKHN0WyJwYWdlIl0gLSAxKSkKICAgICAgICBuZXh0X2IuY29ubmVjdCgiY2xpY2tlZCIsIGxhbWJkYSBiOiBzaG93X3BhZ2Uoc3RbInBhZ2UiXSArIDEpKQogICAgICAgIGZvciB3ZGcgaW4gKHByZXZfYiwgcGFnZV9sYmwsIG5leHRfYik6CiAgICAgICAgICAgIG5hdi5hcHBlbmQod2RnKQogICAgICAgIG91dGVyLmFwcGVuZChuYXYpCgogICAgICAgIGdyaWQgPSBHdGsuR3JpZChjb2x1bW5fc3BhY2luZz0xMCwgcm93X3NwYWNpbmc9NikKICAgICAgICBvdXRlci5hcHBlbmQoZ3JpZCkKICAgICAgICBncmlkLmF0dGFjaChHdGsuTGFiZWwobGFiZWw9IlNpZ24gb246IiwgeGFsaWduPTApLCAwLCAwLCAxLCAxKQogICAgICAgIHJib3ggPSBHdGsuQm94KHNwYWNpbmc9MTIpCiAgICAgICAgdGhpc19yYiA9IEd0ay5DaGVja0J1dHRvbihsYWJlbD0iVGhpcyBwYWdlIikKICAgICAgICBhbGxfcmIgPSBHdGsuQ2hlY2tCdXR0b24obGFiZWw9ZiJBbGwgcGFnZXMgKHtufSkiLCBncm91cD10aGlzX3JiKQogICAgICAgIGxhc3RfcmIgPSBHdGsuQ2hlY2tCdXR0b24obGFiZWw9Ikxhc3QgcGFnZSIsIGdyb3VwPXRoaXNfcmIpCiAgICAgICAgc29tZV9yYiA9IEd0ay5DaGVja0J1dHRvbihsYWJlbD0iUGFnZXM6IiwgZ3JvdXA9dGhpc19yYikKICAgICAgICBzb21lX2UgPSBHdGsuRW50cnkocGxhY2Vob2xkZXJfdGV4dD0iZS5nLiAxLDMsNS03Iiwgd2lkdGhfY2hhcnM9MTQpCiAgICAgICAgc29tZV9lLmNvbm5lY3QoImNoYW5nZWQiLCBsYW1iZGEgZTogc29tZV9yYi5zZXRfYWN0aXZlKFRydWUpIGlmIGUuZ2V0X3RleHQoKSBlbHNlIE5vbmUpCiAgICAgICAgZm9yIHdkZyBpbiAodGhpc19yYiwgYWxsX3JiLCBsYXN0X3JiLCBzb21lX3JiLCBzb21lX2UpOgogICAgICAgICAgICByYm94LmFwcGVuZCh3ZGcpCiAgICAgICAgZ3JpZC5hdHRhY2gocmJveCwgMSwgMCwgMSwgMSkKICAgICAgICBzcGVjMCA9IG8ucGlja19zcGVjLnN0cmlwKCkubG93ZXIoKQogICAgICAgIGlmIHNwZWMwID09ICJhbGwiOgogICAgICAgICAgICBhbGxfcmIuc2V0X2FjdGl2ZShUcnVlKQogICAgICAgIGVsaWYgc3BlYzAgPT0gImxhc3QiIG9yIG5vdCBzcGVjMDoKICAgICAgICAgICAgKGxhc3RfcmIgaWYgby5waWNrX3N0YXJ0ID09IG4gYW5kIG4gPiAxIGVsc2UgdGhpc19yYikuc2V0X2FjdGl2ZShUcnVlKQogICAgICAgIGVsc2U6CiAgICAgICAgICAgIHNvbWVfcmIuc2V0X2FjdGl2ZShUcnVlKQogICAgICAgICAgICBzb21lX2Uuc2V0X3RleHQoby5waWNrX3NwZWMpCgogICAgICAgIHJlYXNvbl9lID0gR3RrLkVudHJ5KHRleHQ9by5yZWFzb24sIGhleHBhbmQ9VHJ1ZSwgcGxhY2Vob2xkZXJfdGV4dD0ib3B0aW9uYWwiKQogICAgICAgIGxvY19lID0gR3RrLkVudHJ5KHRleHQ9by5sb2NhdGlvbiwgaGV4cGFuZD1UcnVlLCBwbGFjZWhvbGRlcl90ZXh0PSJvcHRpb25hbCIpCiAgICAgICAgZ3JpZC5hdHRhY2goR3RrLkxhYmVsKGxhYmVsPSJSZWFzb246IiwgeGFsaWduPTApLCAwLCAxLCAxLCAxKQogICAgICAgIGdyaWQuYXR0YWNoKHJlYXNvbl9lLCAxLCAxLCAxLCAxKQogICAgICAgIGdyaWQuYXR0YWNoKEd0ay5MYWJlbChsYWJlbD0iTG9jYXRpb246IiwgeGFsaWduPTApLCAwLCAyLCAxLCAxKQogICAgICAgIGdyaWQuYXR0YWNoKGxvY19lLCAxLCAyLCAxLCAxKQoKICAgICAgICBlcnIgPSBHdGsuTGFiZWwoeGFsaWduPTApCiAgICAgICAgZXJyLmFkZF9jc3NfY2xhc3MoImVycm9yIikKICAgICAgICBvdXRlci5hcHBlbmQoZXJyKQoKICAgICAgICBidG5zID0gR3RrLkJveChzcGFjaW5nPTgsIGhhbGlnbj1HdGsuQWxpZ24uRU5EKQogICAgICAgIGNhbmNlbF9iID0gR3RrLkJ1dHRvbihsYWJlbD0iQ2FuY2VsIikKICAgICAgICBzaWduX2IgPSBHdGsuQnV0dG9uKGxhYmVsPSJTaWduIChhc2tzIGZvciBQSU4pIikKICAgICAgICBzaWduX2IuYWRkX2Nzc19jbGFzcygic3VnZ2VzdGVkLWFjdGlvbiIpCiAgICAgICAgYnRucy5hcHBlbmQoY2FuY2VsX2IpCiAgICAgICAgYnRucy5hcHBlbmQoc2lnbl9iKQogICAgICAgIG91dGVyLmFwcGVuZChidG5zKQoKICAgICAgICBkZWYgZG9fc2lnbihfYik6CiAgICAgICAgICAgIGlmIGFsbF9yYi5nZXRfYWN0aXZlKCk6CiAgICAgICAgICAgICAgICBzcGVjID0gImFsbCIKICAgICAgICAgICAgZWxpZiBsYXN0X3JiLmdldF9hY3RpdmUoKToKICAgICAgICAgICAgICAgIHNwZWMgPSAibGFzdCIKICAgICAgICAgICAgZWxpZiBzb21lX3JiLmdldF9hY3RpdmUoKToKICAgICAgICAgICAgICAgIHNwZWMgPSBzb21lX2UuZ2V0X3RleHQoKQogICAgICAgICAgICBlbHNlOgogICAgICAgICAgICAgICAgc3BlYyA9IHN0cihzdFsicGFnZSJdKQogICAgICAgICAgICB0cnk6CiAgICAgICAgICAgICAgICBwYXJzZV9wYWdlcyhzcGVjLCBuKQogICAgICAgICAgICBleGNlcHQgVmFsdWVFcnJvciBhcyBlOgogICAgICAgICAgICAgICAgZXJyLnNldF9sYWJlbChzdHIoZSkpCiAgICAgICAgICAgICAgICByZXR1cm4KICAgICAgICAgICAgYiA9IHN0WyJib3giXQogICAgICAgICAgICBpZiBub3QgYiBvciAoYlsyXSAtIGJbMF0pIDwgMC4wMiBvciAoYlszXSAtIGJbMV0pIDwgMC4wMToKICAgICAgICAgICAgICAgIGVyci5zZXRfbGFiZWwoImRyYXcgYSBiaWdnZXIgc2lnbmF0dXJlIGJveCIpCiAgICAgICAgICAgICAgICByZXR1cm4KICAgICAgICAgICAgc3RbInJlc3VsdCJdID0geyJib3giOiBbcm91bmQoeCwgNSkgZm9yIHggaW4gYl0sICJwYWdlcyI6IHNwZWMsCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAicmVhc29uIjogcmVhc29uX2UuZ2V0X3RleHQoKS5zdHJpcCgpLCAibG9jYXRpb24iOiBsb2NfZS5nZXRfdGV4dCgpLnN0cmlwKCl9CiAgICAgICAgICAgIHdpbi5jbG9zZSgpCgogICAgICAgIHNpZ25fYi5jb25uZWN0KCJjbGlja2VkIiwgZG9fc2lnbikKICAgICAgICBjYW5jZWxfYi5jb25uZWN0KCJjbGlja2VkIiwgbGFtYmRhIGI6IHdpbi5jbG9zZSgpKQogICAgICAgIGtleXMgPSBHdGsuRXZlbnRDb250cm9sbGVyS2V5KCkKICAgICAgICBrZXlzLmNvbm5lY3QoImtleS1wcmVzc2VkIiwgbGFtYmRhIGMsIGt2LCBrYywgbTogKHdpbi5jbG9zZSgpLCBUcnVlKVsxXSBpZiBrdiA9PSAweGZmMWIgZWxzZSBGYWxzZSkKICAgICAgICB3aW4uYWRkX2NvbnRyb2xsZXIoa2V5cykKICAgICAgICBzaG93X3BhZ2Uoc3RbInBhZ2UiXSkKICAgICAgICB3aW4uc2V0X2RlZmF1bHRfd2lkZ2V0KHNpZ25fYikKICAgICAgICB3aW4ucHJlc2VudCgpCgogICAgYXBwLmNvbm5lY3QoImFjdGl2YXRlIiwgb25fYWN0aXZhdGUpCiAgICBhcHAucnVuKFtzeXMuYXJndlswXV0pCiAgICBzaHV0aWwucm10cmVlKHRtcGRpciwgaWdub3JlX2Vycm9ycz1UcnVlKQogICAgaWYgc3RbInJlc3VsdCJdIGlzIE5vbmU6CiAgICAgICAgc3lzLmV4aXQoMikKICAgIHByaW50KGpzb24uZHVtcHMoc3RbInJlc3VsdCJdKSkKCgojIC0tLS0gbWFpbiAtLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0KCmRlZiBtYWluKCk6CiAgICBpZiBhbnkoeC5zdGFydHN3aXRoKCItLXBpY2stdWkiKSBmb3IgeCBpbiBzeXMuYXJndlsxOjJdKToKICAgICAgICByZXR1cm4gcGlja2VyX21haW4oc3lzLmFyZ3ZbMTpdKQogICAgYXAgPSBhcmdwYXJzZS5Bcmd1bWVudFBhcnNlcihwcm9nPSJzaWduLXBkZiIsIGRlc2NyaXB0aW9uPSJTaWduIGEgUERGIHdpdGggdGhlIERTQyBVU0IgdG9rZW4uIikKICAgIGFwLmFkZF9hcmd1bWVudCgicGRmIiwgbmFyZ3M9Ij8iLCBoZWxwPSJ0aGUgUERGIChhc2tlZCBmb3IgaW4gYSBmaWxlIGNob29zZXIgd2hlbiBzdGFydGVkIGZyb20gdGhlIGFwcCBtZW51KSIpCiAgICBhcC5hZGRfYXJndW1lbnQoIi1vIiwgIi0tb3V0cHV0IiwgaGVscD0ib3V0cHV0IGZpbGUgKGRlZmF1bHQ6IDxuYW1lPl9zaWduZWQucGRmKSIpCiAgICBhcC5hZGRfYXJndW1lbnQoIi0tcmVhc29uIiwgZGVmYXVsdD1Ob25lKQogICAgYXAuYWRkX2FyZ3VtZW50KCItLWxvY2F0aW9uIiwgZGVmYXVsdD1Ob25lKQogICAgYXAuYWRkX2FyZ3VtZW50KCItLXBhZ2UiLCB0eXBlPWludCwgZGVmYXVsdD0wLCBoZWxwPSJwYWdlIGZvciB0aGUgYm94LCAxID0gZmlyc3QgKGRlZmF1bHQ6IGxhc3QgcGFnZSkiKQogICAgYXAuYWRkX2FyZ3VtZW50KCItLXBhZ2VzIiwgZGVmYXVsdD1Ob25lLCBoZWxwPSJwYWdlcyB0byBzaWduOiBhbGwsIGZpcnN0LCBsYXN0LCBvciBlLmcuIDEsMyw1LTcgKFBJTiBhc2tlZCBvbmNlKSIpCiAgICBhcC5hZGRfYXJndW1lbnQoIi0tcG9zIiwgY2hvaWNlcz1bImJyIiwgImJsIiwgInRyIiwgInRsIl0sIGRlZmF1bHQ9ImJyIiwgaGVscD0iY29ybmVyIGZvciB0aGUgYm94IChkZWZhdWx0IGJyKSIpCiAgICBhcC5hZGRfYXJndW1lbnQoIi0tYm94IiwgZGVmYXVsdD1Ob25lLCBoZWxwPSJib3ggYXMgZnJhY3Rpb25zIG9mIHRoZSBwYWdlOiBsZWZ0LHRvcCxyaWdodCxib3R0b20gKDAuLjEpIikKICAgIGFwLmFkZF9hcmd1bWVudCgiLS1kcmF3IiwgYWN0aW9uPSJzdG9yZV90cnVlIiwgaGVscD0ib3BlbiBhIHdpbmRvdyB0byBkcmF3IHRoZSBib3ggYW5kIGNob29zZSB0aGUgcGFnZXMiKQogICAgYXAuYWRkX2FyZ3VtZW50KCItLW5vLWRyYXciLCBhY3Rpb249InN0b3JlX3RydWUiLCBoZWxwPSJuZXZlciBvcGVuIHRoZSBkcmF3IHdpbmRvdyIpCiAgICBhcC5hZGRfYXJndW1lbnQoIi0taW52aXNpYmxlIiwgYWN0aW9uPSJzdG9yZV90cnVlIiwgaGVscD0ibm8gdmlzaWJsZSBib3giKQogICAgYXAuYWRkX2FyZ3VtZW50KCItLWxpYiIsIGhlbHA9IlBLQ1MjMTEgZHJpdmVyIHRvIHVzZSBpbnN0ZWFkIG9mIHRoZSBhdXRvbWF0aWMgY2hvaWNlIikKICAgIGEgPSBhcC5wYXJzZV9hcmdzKCkKICAgIGlmIGEuYm94OgogICAgICAgIHRyeToKICAgICAgICAgICAgYS5ib3ggPSBwYXJzZV9ib3goYS5ib3gpCiAgICAgICAgZXhjZXB0IFZhbHVlRXJyb3IgYXMgZToKICAgICAgICAgICAgYXAuZXJyb3Ioc3RyKGUpKQogICAgaWYgbm90IGEucGRmOgogICAgICAgIGlmIG5vdCAoR1VJIGFuZCBzaHV0aWwud2hpY2goInplbml0eSIpKToKICAgICAgICAgICAgYXAuZXJyb3IoImdpdmUgdGhlIFBERiB0byBzaWduIikKICAgICAgICByID0gc3VicHJvY2Vzcy5ydW4oWyJ6ZW5pdHkiLCAiLS1maWxlLXNlbGVjdGlvbiIsICItLXRpdGxlPUNob29zZSB0aGUgUERGIHRvIHNpZ24iLCAiLS1maWxlLWZpbHRlcj1QREYgfCAqLnBkZiAqLlBERiJdLAogICAgICAgICAgICAgICAgICAgICAgICAgICBjYXB0dXJlX291dHB1dD1UcnVlLCB0ZXh0PVRydWUpCiAgICAgICAgaWYgci5yZXR1cm5jb2RlICE9IDAgb3Igbm90IHIuc3Rkb3V0LnN0cmlwKCk6CiAgICAgICAgICAgIHN5cy5leGl0KDApCiAgICAgICAgYS5wZGYgPSByLnN0ZG91dC5zdHJpcCgpCgogICAgc3JjID0gb3MucGF0aC5hYnNwYXRoKGEucGRmKQogICAgaWYgbm90IG9zLnBhdGguaXNmaWxlKHNyYyk6CiAgICAgICAgZmFpbCgibm8gc3VjaCBmaWxlOiAiICsgYS5wZGYpCiAgICByb290LCBfID0gb3MucGF0aC5zcGxpdGV4dChzcmMpCiAgICBvdXQgPSBvcy5wYXRoLmFic3BhdGgoYS5vdXRwdXQpIGlmIGEub3V0cHV0IGVsc2Ugcm9vdCArICJfc2lnbmVkLnBkZiIKICAgIGlmIG91dCA9PSBzcmM6CiAgICAgICAgZmFpbCgidGhlIG91dHB1dCBtdXN0IGJlIGEgbmV3IGZpbGUsIG5vdCB0aGUgb3JpZ2luYWwiKQogICAgdHJ5OgogICAgICAgIG5fcGFnZXMgPSBjb3VudF9wYWdlcyhzcmMpCiAgICBleGNlcHQgRXhjZXB0aW9uIGFzIGU6CiAgICAgICAgZmFpbCgiY2Fubm90IHJlYWQgdGhlIFBERjogIiArIChzdHIoZSkgb3IgZS5fX2NsYXNzX18uX19uYW1lX18pKQoKICAgICMgdGhlIGJveCBhbmQgdGhlIHBhZ2VzOiBkcmF3biBpbiB0aGUgd2luZG93IChmaWxlIG1hbmFnZXIgLyBhcHAgbWVudSwgb3IgLS1kcmF3KSwgZWxzZSBmcm9tIHRoZSBvcHRpb25zCiAgICBpZiBub3QgYS5pbnZpc2libGUgYW5kIG5vdCBhLm5vX2RyYXcgYW5kIChhLmRyYXcgb3IgKEdVSSBhbmQgbm90IGEuYm94IGFuZCBub3QgYS5wYWdlcykpOgogICAgICAgIGEuYm94LCBhLnBhZ2VzLCByZWFzb24sIGxvY2F0aW9uID0gcnVuX3BpY2tlcihzcmMsIG5fcGFnZXMsIGEpCiAgICAgICAgYS5yZWFzb24sIGEubG9jYXRpb24gPSByZWFzb24gb3IgYS5yZWFzb24sIGxvY2F0aW9uIG9yIGEubG9jYXRpb24KICAgIHNwZWMgPSBhLnBhZ2VzIG9yIChzdHIoYS5wYWdlKSBpZiBhLnBhZ2UgZWxzZSAibGFzdCIpCiAgICB0cnk6CiAgICAgICAgcGFnZXMgPSBwYXJzZV9wYWdlcyhzcGVjLCBuX3BhZ2VzKQogICAgZXhjZXB0IFZhbHVlRXJyb3IgYXMgZToKICAgICAgICBmYWlsKHN0cihlKSkKCiAgICBmcm9tIHB5aGFua28uc2lnbiBpbXBvcnQgc2lnbmVycwogICAgdGVzdF9wMTIgPSBvcy5lbnZpcm9uLmdldCgiU0lHTl9QREZfVEVTVF9QMTIiKSAgICMgc2VsZi10ZXN0IG9ubHk6IGEgdGhyb3dhd2F5IGtleSBmaWxlIGluc3RlYWQgb2YgdGhlIHRva2VuCiAgICBpZiB0ZXN0X3AxMjoKICAgICAgICBzaWduX2ZpbGUoYSwgc3JjLCBvdXQsIHNpZ25lcnMuU2ltcGxlU2lnbmVyLmxvYWRfcGtjczEyKHRlc3RfcDEyLCBwYXNzcGhyYXNlPU5vbmUpLCBwYWdlcykKICAgICAgICByZXR1cm4gcmVwb3J0KG91dCkKCiAgICBmcm9tIHB5aGFua28uc2lnbi5wa2NzMTEgaW1wb3J0IFBLQ1MxMVNpZ25lciwgb3Blbl9wa2NzMTFfc2Vzc2lvbgogICAgbGliID0gZmluZF9kcml2ZXIoYS5saWIpCiAgICBwaW4gPSBhc2tfcGluKCkKICAgIGlmIG5vdCBwaW46CiAgICAgICAgZmFpbCgibm8gUElOIGdpdmVuIikKICAgIHRyeToKICAgICAgICBzZXNzaW9uID0gb3Blbl9wa2NzMTFfc2Vzc2lvbihsaWIsIHVzZXJfcGluPXBpbikKICAgIGV4Y2VwdCBFeGNlcHRpb24gYXMgZTogICMgd3JvbmcgUElOLCBsb2NrZWQgdG9rZW4sIHRva2VuIGJ1c3kKICAgICAgICBmYWlsKCJjb3VsZCBub3Qgb3BlbiB0aGUgdG9rZW46ICIgKyAoc3RyKGUpIG9yIGUuX19jbGFzc19fLl9fbmFtZV9fKSArCiAgICAgICAgICAgICAiXG4oYSB3cm9uZyBQSU4gY291bnRzIHRvd2FyZHMgbG9ja2luZyB0aGUgdG9rZW4gLSBjaGVjayBpdCBiZWZvcmUgdHJ5aW5nIGFnYWluKSIpCiAgICBmaW5hbGx5OgogICAgICAgIHBpbiA9IE5vbmUKCiAgICB0cnk6CiAgICAgICAgaW1wb3J0IHBrY3MxMQogICAgICAgIGZyb20gYXNuMWNyeXB0byBpbXBvcnQgeDUwOQogICAgICAgIGtleV9pZHMgPSB7a1twa2NzMTEuQXR0cmlidXRlLklEXSBmb3IgayBpbiBzZXNzaW9uLmdldF9vYmplY3RzKHtwa2NzMTEuQXR0cmlidXRlLkNMQVNTOiBwa2NzMTEuT2JqZWN0Q2xhc3MuUFJJVkFURV9LRVl9KX0KICAgICAgICBtaW5lID0gW10KICAgICAgICBmb3IgYyBpbiBzZXNzaW9uLmdldF9vYmplY3RzKHtwa2NzMTEuQXR0cmlidXRlLkNMQVNTOiBwa2NzMTEuT2JqZWN0Q2xhc3MuQ0VSVElGSUNBVEV9KToKICAgICAgICAgICAgY2VydCA9IHg1MDkuQ2VydGlmaWNhdGUubG9hZChjW3BrY3MxMS5BdHRyaWJ1dGUuVkFMVUVdKQogICAgICAgICAgICBjaWQgPSBjW3BrY3MxMS5BdHRyaWJ1dGUuSURdICAgICAgICAgICMgQ2VydGlmaWNhdGUgb2JqZWN0cyBoYXZlIG5vIC5pZCBwcm9wZXJ0eSAob25seSBrZXlzIGRvKQogICAgICAgICAgICBpZiBjaWQgaW4ga2V5X2lkcyBhbmQgbm90IGlzX2NhKGNlcnQpOgogICAgICAgICAgICAgICAgbWluZS5hcHBlbmQoKGNpZCwgY2VydCkpCiAgICAgICAgaWYgbm90IG1pbmU6CiAgICAgICAgICAgIGZhaWwoIm5vIHNpZ25pbmcgY2VydGlmaWNhdGUgd2l0aCBhIHByaXZhdGUga2V5IG9uIHRoaXMgdG9rZW4iKQogICAgICAgIG1pbmUuc29ydChrZXk9bGFtYmRhIHQ6IHRbMV0ubm90X3ZhbGlkX2FmdGVyLCByZXZlcnNlPVRydWUpICAgICAgIyBzZXZlcmFsOiB0aGUgb25lIHZhbGlkIGxvbmdlc3QKICAgICAgICBjaWQsIGNlcnQgPSBtaW5lWzBdCiAgICAgICAgbmFtZSA9IGNlcnQuc3ViamVjdC5uYXRpdmUuZ2V0KCJjb21tb25fbmFtZSIsICJEU0MgaG9sZGVyIikKICAgICAgICBzYXkoZiJzaWduZXIgIDoge25hbWV9ICAodmFsaWQgdW50aWwge2NlcnQubm90X3ZhbGlkX2FmdGVyOiVkLSVtLSVZfSkiKQogICAgICAgIHNpZ25lciA9IFBLQ1MxMVNpZ25lcihzZXNzaW9uLCBjZXJ0X2lkPWNpZCwga2V5X2lkPWNpZCwgb3RoZXJfY2VydHNfdG9fcHVsbD1Ob25lKQogICAgICAgIHNpZ25fZmlsZShhLCBzcmMsIG91dCwgc2lnbmVyLCBwYWdlcykKICAgIGZpbmFsbHk6CiAgICAgICAgc2Vzc2lvbi5jbG9zZSgpCiAgICByZXBvcnQob3V0KQoKCmlmIF9fbmFtZV9fID09ICJfX21haW5fXyI6CiAgICBtYWluKCkK"
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
    OPT_MSI=""; OPT_ZIP7=""; OPT_DOWNLOAD=1; OPT_CRIS_MSI=""; OPT_IREPS_MSI=""; OPT_KIT=""; OPT_EPASS_ZIP=""; OPT_DRIVERS=()
    for a in "$@"; do case "$a" in
        --no-root) no_root=1;; --ui-scale=*) ui_scale="${a#*=}";; --pin-scale=*) pin_scale="${a#*=}";;
        --msi=*) OPT_MSI="${a#*=}";; --zip7=*) OPT_ZIP7="${a#*=}";; --no-download) OPT_DOWNLOAD=0;;
        --cris-msi=*) OPT_CRIS_MSI="${a#*=}";; --ireps-msi=*) OPT_IREPS_MSI="${a#*=}";; --kit=*) OPT_KIT="${a#*=}";;
        --epass-zip=*) OPT_EPASS_ZIP="${a#*=}"; OPT_DRIVERS+=("${a#*=}");;
        --driver=*) OPT_DRIVERS+=("${a#*=}");;
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
    [ -d /etc/udev/rules.d ] && { [ -f "$UDEV_RULE" ] || ! udev_rule_present; } && ! udev_rule_current && reasons+=("udev rule for DSC tokens")
    hosts_ok || reasons+=("/etc/hosts entry")
    hook_active && reasons+=("disable the vendor autostart hook")
    smartcard_stack_ok || reasons+=("smart-card service + OpenSC (ePass2003 and smart cards)")
    local epass="" f                   # token vendors' drivers: from the bundle, --driver=FILE, or downloads in ~/Downloads
    for f in "${OPT_DRIVERS[@]}"; do [ -f "$f" ] || die "--driver/--epass-zip: file not found: $f"; done
    if [ "$(uname -m)" = x86_64 ]; then
        stage_vendor_drivers "${OPT_DRIVERS[@]}"
        [ -n "$DRV_PENDING" ] && { epass="$DRV_CACHE"; reasons+=("token drivers ($DRV_PENDING)"); }
        [ -f "$PROXKEY_LIB" ] && ! proxkey_compat_ok && { epass="$DRV_CACHE"; reasons+=("ProxKey driver libraries"); }
    fi
    [ -n "$(ccid_missing)" ] && reasons+=("smart-card reader ids ($(ccid_missing | cut -d: -f1,2 | paste -sd' ' -))")
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
# Token driver (PKCS#11 library). Leave empty to auto-detect. A driver set here is skipped while
# a different token is plugged in; P11_FORCE=1 uses it regardless.
P11_LIB=""
P11_FORCE=""
# Force a particular Java (leave empty to auto-detect).
JAVA8=""
JAVA17=""
# PDF signing with the token (sign-pdf, Document Viewer): yes or no
DSC_PDF=$DSC_PDF
# Fill in the DSC's CA certificates for the eOffice 4.1.8 signer when the token lacks them
# (fixes DSCSN05 on Linux). CA files you add go in ~/.local/share/railway-dsc/ca. yes or no
DSC_CHAIN_FILL=yes
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
    write_probe; write_laf_jar; write_scale_jar; write_chain_jar; write_launcher; install_self
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
            elif probe "$s"; then
                rm -f "$STATE_DIR/fail.$s"
                # answering, but can it still open its PIN window? Restart only when a working
                # desktop display exists now - otherwise a restart cannot help (e.g. logged out).
                why=$(svc_gui_problem "$s") && [ -n "$(session_display)" ] || continue
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

# DSCSN05 on Linux: NIC drops a DSC whose chain (from the token) has two certificates or fewer.
doctor_chain() {
    if [ "${DSC_CHAIN_FILL:-yes}" = no ]; then
        d_warn "certificate-chain agent turned off (DSC_CHAIN_FILL=no) - a token without its CA certificates gives DSCSN05"
        d_fix "set DSC_CHAIN_FILL=yes in $CONF_FILE, then: railway-dsc install"
    elif [ "$(sha "$CHAIN_JAR")" = "$CHAIN_JAR_SHA" ] && [ "$(sha "$CA_DIR/suite-bundle.pem")" = "$CA_BUNDLE_SHA" ]; then
        d_ok "certificate-chain agent ready ($(find "$CA_DIR" -type f \( -name '*.pem' -o -name '*.cer' -o -name '*.crt' \) | wc -l) CA files in $CA_DIR)"
    else
        d_fail "certificate-chain agent or CA bundle missing/changed - a token without its CA certificates gives DSCSN05"; d_fix "railway-dsc install"
    fi
    local l
    l=$(grep -a 'railway-dsc chain-fill\] \(completed\|could not complete\)' "$EOFFICE_LOGS/error.log" 2>/dev/null | tail -1)
    case "$l" in
        *completed*) d_ok "last DSC chain completed by the agent: ${l#*completed the chain of }" ;;
        *"could not complete"*)
            d_warn "the agent could not complete a DSC chain: ${l#*could not complete the chain of }"
            d_fix "download that CA's certificates (its repository, or cca.gov.in > Licensed CAs) into $CA_DIR, then restart: systemctl --user restart eofficesigner418" ;;
    esac
    # What the token itself holds (public objects only - no PIN, no login).
    local p11 out n ids id der
    have pkcs11-tool && p11=$(find_p11_lib 2>/dev/null) || return 0
    out=$(timeout 15 pkcs11-tool --module "$p11" --list-objects --type cert 2>/dev/null) || return 0
    n=$(grep -c '^Certificate Object' <<<"$out")
    [ "$n" -gt 0 ] || return 0
    if [ "$n" -le 2 ]; then
        d_ok "token holds $n certificate(s) - NIC needs the CA certificates too; the agent adds them (Windows takes them from its store)"
    else
        d_ok "token holds $n certificates"
    fi
    ids=$(sed -n 's/^ *ID: *//p' <<<"$out" | sort -u)
    for id in $ids; do
        der=$(timeout 15 pkcs11-tool --module "$p11" --read-object --type cert --id "$id" 2>/dev/null | openssl x509 -inform DER -noout -subject -serial -ext keyUsage 2>/dev/null) || continue
        grep -q 'Digital Signature' <<<"$der" || continue
        printf '         DSC on token: %s, serial %s\n' "$(sed -n 's/^subject=.*CN *= *\([^,]*\).*/\1/p' <<<"$der")" "$(sed -n 's/^serial=//p' <<<"$der")"
    done
    printf '         %s\n' "If eOffice still says DSCSN05, this serial must match the DSC registered in eOffice (re-register it there)."
}

cmd_doctor() {
    echo "${B}Railway DSC Signer Suite $SUITE_VERSION - doctor${N}  ($(date '+%F %T'))"
    [ -f "$CONF_FILE" ] && . "$CONF_FILE"
    local s j f u o e why

    d_head "System"
    if [ -f /etc/os-release ]; then . /etc/os-release; d_ok "${PRETTY_NAME:-unknown Linux}, kernel $(uname -r), $(uname -m)"; fi
    case "$(uname -m)" in x86_64) ;; *) d_warn "CPU $(uname -m): the mToken driver and bundled runtimes are x86_64 only";; esac
    if have_systemd_user; then d_ok "systemd user session available"; else d_warn "no systemd user session - the desktop-autostart supervisor is used instead"; fi
    if [ -n "${WAYLAND_DISPLAY:-}" ]; then d_ok "Wayland session (signers use XWayland - fine)"; fi
    if ls /tmp/.X11-unix/X* >/dev/null 2>&1; then d_ok "X display socket present ($(ls /tmp/.X11-unix | tr '\n' ' '))"
    else d_fail "no X display socket - the signers' PIN window cannot open"; d_fix "log in to a graphical desktop session"; fi
    if o=$(session_display) && [ -n "$o" ]; then d_ok "desktop display $o accepts windows from the signers"
    else d_warn "the desktop display does not accept connections right now (no graphical login?)"; fi
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
        doctor_chain
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
                case "$v" in 2ccf|338c)
                    for o in $(plugged_ids | grep "^$v:"); do
                        case " $CCID_ADD " in *" ${o}:"*) ccid_has "$v" "${o#*:}" || { d_fail "  the smart-card service does not know this $nm model ($o)"; d_fix "railway-dsc install   (adds it to the CCID reader list; again after a libccid update)"; };; esac
                    done;; esac
                [ "$v" = 163c ] && [ "$drv" = "$PROXKEY_LIB" ] && ! proxkey_compat_ok && { d_fail "  ProxKey driver misses libraries"; d_fix "railway-dsc install"; }
                [ "$v" = 163c ] && plugged_ids | grep -qE '^163c:(0402|0412|0620|5471)$' && [ ! -e "$PROXKEY_COMPAT/pcscd_wd" ] && { d_warn "  this ProxKey model needs WatchData's own smart-card service, which the suite does not install"; }
                case " $OPENSC_LIBS " in *" $drv "*)
                    if have systemctl && systemctl is-active --quiet pcscd.socket 2>/dev/null || pgrep -x pcscd >/dev/null 2>&1; then d_ok "  (via OpenSC; smart-card service running)"
                    else d_fail "  OpenSC needs the smart-card service"; d_fix "sudo systemctl enable --now pcscd.socket"; fi;; esac
            else d_fail "$nm token plugged in, but its Linux driver is not installed"
                case "$v" in
                    096e) d_fix "railway-dsc install   (adds OpenSC, which supports the ePass2003)"
                          d_fix "or Feitian's own driver: ePass2003_Linux.zip (e-mudhra.com/Repository) in ~/Downloads, then railway-dsc install";;
                    163c) d_fix "download ProxKey_Linux.zip (e-mudhra.com/Repository -> Token Drivers) to ~/Downloads, then: railway-dsc install";;
                    2ccf) d_fix "download HYP2003-Linux-x86_64-FIPS140-3.zip from https://www.hypersecu.com/india-support into ~/Downloads, then: railway-dsc install";;
                    338c) d_fix "download InnaITDSC_Setup.zip (e-mudhra.com/Repository -> Token Drivers -> Precision InnaIT, Linux), then: railway-dsc install";;
                    0529) d_fix "install SafeNet Authentication Client for Linux (from your token supplier)";;
                    08e6) d_fix "install Thales/Gemalto IDPrime middleware, or: sudo apt install opensc-pkcs11 pcscd";;
                    *)    d_fix "install the token vendor's Linux PKCS#11 driver, then set P11_LIB in $CONF_FILE";;
                esac
            fi
        done
        if [ -n "${P11_LIB:-}" ]; then
            o=""; for l in $P11_LIB; do [ -f "$l" ] && p11_override_fits "$l" && o="$l"; done
            if [ -n "$o" ]; then d_ok "P11_LIB is set in suite.conf: $o (overrides automatic choice)"
            else d_warn "P11_LIB in suite.conf ($P11_LIB) is not for the plugged token - ignored, automatic choice used"
                 d_fix "clear it: set P11_LIB=\"\" in $CONF_FILE   (or P11_FORCE=1 to insist on it)"; fi
        fi
    else d_warn "no known DSC token on USB"; d_fix "plug the token in (try another port); 'lsusb' should list it"; fi
    if j=$(find_p11_lib); then
        d_ok "PKCS#11 driver: $j"
        if have ldd; then o=$(ldd "$j" 2>/dev/null | awk '/not found/{print $1}' | paste -sd' ' -); [ -n "$o" ] && { d_fail "driver needs missing libraries: $o"; d_fix "install those packages (Ubuntu: apt-file search <name>)"; }; fi
    else d_fail "no PKCS#11 driver found for any common token"; d_fix "install the token vendor's Linux driver (mToken: libcryptoid_pkcs11.so in /usr/lib)"; fi
    if udev_rule_current; then d_ok "udev rule for tokens present"
    elif [ -f "$UDEV_RULE" ]; then d_warn "udev rule is from an older version (misses newer tokens)"; d_fix "railway-dsc install"
    elif udev_rule_present; then d_ok "udev rule for tokens present (vendor's)"
    else d_warn "no udev rule - token may need root access"; d_fix "railway-dsc install"; fi
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
        elif ! probe "$s"; then d_warn "$(svc_label "$s") running but not answering"; d_fix "railway-dsc heal"
        elif why=$(svc_gui_problem "$s"); then
            d_fail "$(svc_label "$s") answers on port $(svc_port "$s") but cannot open its PIN window: $why"
            d_fix "railway-dsc restart   (the watchdog also does this within 3 minutes)"
        else d_ok "$(svc_label "$s") answers on port $(svc_port "$s") and can open its PIN window"; fi
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
        ok "Services and program files removed. Left in place (need root): $MTOKEN_LIB, $VDRV_DIR (token drivers), the reader ids in libccid's Info.plist (backup: .bak-railway-dsc), $UDEV_RULE, the /etc/hosts line, the AppArmor lines in /etc/apparmor.d/local/ and Document Viewer."
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
                       --driver=FILE  a token vendor's Linux driver download (zip/deb/rar): ePass2003,
                                      Hypersecu HYP2003, InnaIT, ProxKey. Known builds are also found
                                      in ~/Downloads by themselves; only the PKCS#11 library is used.
                       --epass-zip=FILE  same as --driver (kept for older instructions)
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
