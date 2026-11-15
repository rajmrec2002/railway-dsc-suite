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
# ==============================================================================
set -u
set -o pipefail

SUITE_VERSION="4.3.0"
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
    KIT_COPY="$SHARE_DIR/kit"
    PROBE="$SHARE_DIR/probe.py"
    HEAL_LOG="$SHARE_DIR/heal.log"
    BIN="$U_HOME/.local/bin/railway-dsc"
    UNIT_DIR="$U_HOME/.config/systemd/user"
    AUTOSTART="$U_HOME/.config/autostart/railway-dsc-supervisor.desktop"
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
find_p11_lib() {
    local l
    for l in ${P11_LIB:-} $P11_CANDIDATES; do [ -f "$l" ] && { echo "$l"; return 0; }; done
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
LAF_JAR_B64="UEsDBAoAAAAAAKeEb10AAAAAAAAAAAAAAAAEABwAY29tL1VUCQADYZL5amGS+Wp1eAsAAQToAwAABOgDAABQSwMECgAAAAAAp4RvXQAAAAAAAAAAAAAAAAgAHABjb20vc3VuL1VUCQADYZL5amGS+Wp1eAsAAQToAwAABOgDAABQSwMECgAAAAAAp4RvXQAAAAAAAAAAAAAAAA0AHABjb20vc3VuL2phdmEvVVQJAANhkvlqYZL5anV4CwABBOgDAAAE6AMAAFBLAwQKAAAAAACnhG9dAAAAAAAAAAAAAAAAEwAcAGNvbS9zdW4vamF2YS9zd2luZy9VVAkAA2GS+WphkvlqdXgLAAEE6AMAAAToAwAAUEsDBAoAAAAAAKeEb10AAAAAAAAAAAAAAAAYABwAY29tL3N1bi9qYXZhL3N3aW5nL3BsYWYvVVQJAANhkvlqYZL5anV4CwABBOgDAAAE6AMAAFBLAwQKAAAAAACnhG9dAAAAAAAAAAAAAAAAIAAcAGNvbS9zdW4vamF2YS9zd2luZy9wbGFmL3dpbmRvd3MvVVQJAANhkvlqYZL5anV4CwABBOgDAAAE6AMAAFBLAwQUAAAACACnhG9dxKBN6BwEAACgBwAAOAAcAGNvbS9zdW4vamF2YS9zd2luZy9wbGFmL3dpbmRvd3MvV2luZG93c0xvb2tBbmRGZWVsLmNsYXNzVVQJAANhkvlqYZL5anV4CwABBOgDAAAE6AMAAH1Uz1cbVRT+hoRMmE5BAuFHKTWoxQkoo1itbbEtJYWmhB81CAXqj2HykgyZvJczMwHqP6A7l55uuu3WbiLHc/SoS/8L/wM3Llzo8c4kkAChs7gzc+/33Xffd+97f/z30y8ArkMouILJKN6J4t0ophT0Qo/iPf/9voJpfOCba775UMFHuK7gY9xQcBO3ZMxE7vyl/f37d0+SMj6J4raMOzLuyphV0Id7CuaQUtCN+wrmseB/PfB9aRkPZSzKyEiIzFjc8m5LCGnJdQnhOZFjEnoyFmfL1fIOc9aMHZs8coF5y0aZvvq1ZGbX2DN02+AFPes5Fi/cktBJgHRKQje9U8w1HaviWYJLiM6YdmONi1nPMEtLRqWRVMmKqmOyecv/GdyweE7suxkhSrM8N8+YPeWvo+J1JCQMNMIJbWFtMSF4gkqsHiSpskZAwrQfsYmecD2D56iuhMUTeeEkvCJLHPEDwBFfxRKWqbACF2U29Tjv6anVtIoVrMp4pOJTZFWs4TMV69iQ8VjFJrZkbKt4gs9lfKHiS3wlobepR5p7rMAcCa8FPmPf09eEsEuWJyHmBtKUPFFZdUSFOd5TkrrJnbMN1z1itqh7wrWys8tMT4WBHRmmihyYijwKMooqLOyqKMFWUQZJ39ekrRUdsV9XfdoUZd2tcj2Iuvu0gl6xjby+X1dIP9sICRPnkQpeSSfdT4B7gxnIG1XbO9788di0SEJjEyu00WRcOzthrUNX14DYl48zLjhGpWiZ7n2+ZzmClxmnNRXLfcCMnM18WWnAtySM0HoZYRp2W0Kitcg2CFpyoLm3rOkwxlNszzJJ1pF23HqQaIPnhCjSTDgneN4qVB2jfnLeaJfxBIYSX3k1goagpRmOwV06D2UJY625C4yaO5vP06E/hlDq0VcCJHRR5ixJyTYDdVNHjTdtw2G5JeYVRU7C3TbN3M6cmvoT7XVY3qb+6vUMVMjQeTE6uXSmZk2TOmwFwx3Wtvx7LGpxb92wqyyoLE3XUjPFkuEV6b5yRJXnfEIq+ZBukT0fvZKnBmvp1mIaB5qqiFh8T5Qo4w3t7Cxun3W1mViMYZRue//phORfbGTH6G+U3pLvnfgR0kv6oO6TjQTOPrJv4q0GdKQBDcU6fjgF9CFX2wBDp4FXyY63AYZPA8cRxdvHVf6JLqob+PoQnYsTsUgNcuYQ0WeQe14gdoiuGpQaLtSg1nAxPfkbup8ho/Wj5/vnSMV6Y7HOn9G3GYr1ZzfDsXi2hoGb4eFwuIbB4fAExeIUi1Bs8ld01zD0jSYOMfztIS4RdGTjBcKLL4OqqjjAZXQEdU5DJTuAMAZxAUOIY5g2dIm2OIJrhFokbR+R5lVCH9BOnpKUGjHi6PwXcRm9MuLLoX+wek8mNKVPUrADE/8DUEsBAh4DCgAAAAAAp4RvXQAAAAAAAAAAAAAAAAQAGAAAAAAAAAAQAP1BAAAAAGNvbS9VVAUAA2GS+Wp1eAsAAQToAwAABOgDAABQSwECHgMKAAAAAACnhG9dAAAAAAAAAAAAAAAACAAYAAAAAAAAABAA/UE+AAAAY29tL3N1bi9VVAUAA2GS+Wp1eAsAAQToAwAABOgDAABQSwECHgMKAAAAAACnhG9dAAAAAAAAAAAAAAAADQAYAAAAAAAAABAA/UGAAAAAY29tL3N1bi9qYXZhL1VUBQADYZL5anV4CwABBOgDAAAE6AMAAFBLAQIeAwoAAAAAAKeEb10AAAAAAAAAAAAAAAATABgAAAAAAAAAEAD9QccAAABjb20vc3VuL2phdmEvc3dpbmcvVVQFAANhkvlqdXgLAAEE6AMAAAToAwAAUEsBAh4DCgAAAAAAp4RvXQAAAAAAAAAAAAAAABgAGAAAAAAAAAAQAP1BFAEAAGNvbS9zdW4vamF2YS9zd2luZy9wbGFmL1VUBQADYZL5anV4CwABBOgDAAAE6AMAAFBLAQIeAwoAAAAAAKeEb10AAAAAAAAAAAAAAAAgABgAAAAAAAAAEAD9QWYBAABjb20vc3VuL2phdmEvc3dpbmcvcGxhZi93aW5kb3dzL1VUBQADYZL5anV4CwABBOgDAAAE6AMAAFBLAQIeAxQAAAAIAKeEb13EoE3oHAQAAKAHAAA4ABgAAAAAAAAAAAC0gcABAABjb20vc3VuL2phdmEvc3dpbmcvcGxhZi93aW5kb3dzL1dpbmRvd3NMb29rQW5kRmVlbC5jbGFzc1VUBQADYZL5anV4CwABBOgDAAAE6AMAAFBLBQYAAAAABwAHAIYCAABOBgAAAAA="
write_laf_jar() {
    mkdir -p "$SHARE_DIR"
    printf '%s' "$LAF_JAR_B64" | base64 -d > "$LAF_JAR.tmp" && [ "$(sha "$LAF_JAR.tmp")" = "$LAF_JAR_SHA" ] &&
        mv -f "$LAF_JAR.tmp" "$LAF_JAR" || { rm -f "$LAF_JAR.tmp"; warn "could not write the GTK look jar"; }
}

write_launcher() {
    mkdir -p "$SHARE_DIR"
    {
        echo '#!/usr/bin/env bash'
        echo "# Generated by railway-dsc-suite $SUITE_VERSION - do not edit; re-run \"railway-dsc install\"."
        echo '# usage: launch.sh eoffice|cris|ireps'
        local v
        for v in U_HOME LAF_JAR E7_DIR E7_JAR E7_LOGS EOFFICE_DIR EOFFICE_JAR EOFFICE_JKS EOFFICE_LOGS CRIS_DIR IREPS_DIR CONF_FILE \
                 JRE8_DIR JRE17_DIR LEGACY_706_DIR HOSTS_NAME P11_CANDIDATES; do
            printf '%s=%q\n' "$v" "${!v}"
        done
        declare -f java_major java_has_gui find_java8 find_java_modern find_p11_lib
    } > "$LAUNCH"
    cat >> "$LAUNCH" <<'LAUNCH_EOF'
SVC="${1:-}"
DSC_UI_SCALE=auto; DSC_LOOK=native; P11_LIB=""; JAVA8=""; JAVA17=""
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
    exec >>"$E7_LOGS/output.log" 2>>"$E7_LOGS/errorOutput.log"
    # java.awt.headless=true is what NIC's own launcher passes; the app switches it back itself.
    exec "$J" "$NOATK" "${UI[@]}" -Djava.awt.headless=true -jar "$E7_JAR" --server.address="$BIND"
fi

if [ "$SVC" = eoffice ]; then
    J8=$(find_java8) || { echo "No Java 8 runtime with GUI libraries found - run: railway-dsc install"; exit 1; }
    mkdir -p "$EOFFICE_LOGS"
    cd "$EOFFICE_DIR" || exit 1                              # pkcs11cfg is read from here
    exec >>"$EOFFICE_LOGS/output.log" 2>>"$EOFFICE_LOGS/error.log"
    # Java 8 cannot scale Swing on Linux; NIC's PIN window keeps its fixed pixel size.
    exec "$J8" "$NOATK" -jar "$EOFFICE_JAR" \
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
    for f in "$EOFFICE_JAR" "$EOFFICE_JKS" "$EOFFICE_P11CFG" "$EOFFICE_CA" "$E7_JAR"; do echo "$f"; done
    find "$CRIS_DIR" "$IREPS_DIR" -maxdepth 2 -type f \( -name '*.jar' -o -name 'certificate.crt' \) 2>/dev/null
    echo "$LAUNCH"; echo "$PROBE"; echo "$LAF_JAR"
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

cmd_root() {                  # internal: runs under sudo.  args: user payload_dir need_java8 need_java17 need_cab
    local user="$1" payload="$2" nj8="$3" nj17="$4" ncab="$5" home
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
    if ! have pcscd && [ ! -x /usr/sbin/pcscd ]; then pkg_install $(pkgs_for smartcard); fi

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
    local no_root=0 ui_scale="" a opt_eoffice=""
    OPT_MSI=""; OPT_ZIP7=""; OPT_DOWNLOAD=1; OPT_CRIS_MSI=""; OPT_IREPS_MSI=""; OPT_KIT=""
    for a in "$@"; do case "$a" in
        --no-root) no_root=1;; --ui-scale=*) ui_scale="${a#*=}";;
        --msi=*) OPT_MSI="${a#*=}";; --zip7=*) OPT_ZIP7="${a#*=}";; --no-download) OPT_DOWNLOAD=0;;
        --cris-msi=*) OPT_CRIS_MSI="${a#*=}";; --ireps-msi=*) OPT_IREPS_MSI="${a#*=}";; --kit=*) OPT_KIT="${a#*=}";;
        --eoffice=*) opt_eoffice="${a#*=}"
            case "$opt_eoffice" in 4|4.1*|7|7.0*|both|all) ;; *) die "--eoffice must be 4, 7 or both";; esac;;
        *) die "unknown option $a";; esac; done
    if [ -n "$opt_eoffice" ]; then
        case "$opt_eoffice" in 4*) DSC_EOFFICE=4;; 7*) DSC_EOFFICE=7;; *) DSC_EOFFICE=both;; esac
    elif ! grep -qs '^DSC_EOFFICE=' "$CONF_FILE"; then
        if [ -t 0 ] && [ -t 1 ] && [ "${RDSC_TEST_NOSTART:-}" != 1 ]; then DSC_EOFFICE=$(ask_eoffice); else DSC_EOFFICE=4; fi
    fi
    DSC_EOFFICE="${DSC_EOFFICE:-4}"
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

    if [ ${#reasons[@]} -gt 0 ] && [ $no_root = 0 ] && [ "${RDSC_TEST_NOROOT:-}" != 1 ]; then
        step "Administrator rights needed for: $(IFS=,; echo "${reasons[*]}" | sed 's/,/, /g')"
        if have sudo; then
            sudo bash "$SELF" __root "$(id -un)" "${PAYLOAD:-/nonexistent}" "$nj8" "$nj17" "$ncab" || warn "system-level setup reported a problem - continuing"
        else
            warn "sudo is not installed. Run this as root, then run install again:"
            info "su -c 'bash $SELF __root $(id -un) ${PAYLOAD:-/nonexistent} $nj8 $nj17 $ncab'"
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
# (The eOffice PIN window runs on Java 8, which cannot scale on Linux.)
DSC_UI_SCALE=${ui_scale:-auto}
# Look of the CRIS/IREPS windows: native = desktop GTK theme, metal = Java default.
DSC_LOOK=native
# eOffice signer version(s): 4 (= 4.1.8, port 55101), 7 (= 7.0.6, port 55103) or both
DSC_EOFFICE=$DSC_EOFFICE
# Token driver (PKCS#11 library). Leave empty to auto-detect.
P11_LIB=""
# Force a particular Java (leave empty to auto-detect).
JAVA8=""
JAVA17=""
EOF
    elif [ -n "$ui_scale" ]; then sed -i "s/^DSC_UI_SCALE=.*/DSC_UI_SCALE=$ui_scale/" "$CONF_FILE"; fi
    conf_set DSC_EOFFICE "$DSC_EOFFICE"
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
    write_probe; write_laf_jar; write_launcher; install_self
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
    local tk; tk=$(tokens_plugged)
    if [ -n "$tk" ]; then d_ok "USB token(s): $(echo "$tk" | cut -d: -f2 | paste -sd, -)"
    else d_warn "no known DSC token on USB"; d_fix "plug the token in (try another port); 'lsusb' should list it"; fi
    if j=$(find_p11_lib); then
        d_ok "PKCS#11 driver: $j"
        if have ldd; then o=$(ldd "$j" 2>/dev/null | awk '/not found/{print $1}' | paste -sd' ' -); [ -n "$o" ] && { d_fail "driver needs missing libraries: $o"; d_fix "install those packages (Ubuntu: apt-file search <name>)"; }; fi
    else d_fail "no PKCS#11 driver found for any common token"; d_fix "install the token vendor's Linux driver (mToken: libcryptoid_pkcs11.so in /usr/lib)"; fi
    udev_rule_present && d_ok "udev rule for tokens present" || { d_warn "no udev rule - token may need root access"; d_fix "railway-dsc install"; }
    if have systemctl && systemctl is-active --quiet pcscd.socket 2>/dev/null || pgrep -x pcscd >/dev/null 2>&1; then d_ok "pcscd available (smart-card readers)"; fi

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
    rm -f "$AUTOSTART" "$BIN"
    if [ $purge = 1 ]; then
        rm -rf "$SHARE_DIR" "$EOFFICE_DIR" "$CRIS_DIR" "$IREPS_DIR" "$CONF_DIR"
        ok "Services and program files removed. Left in place (need root): $MTOKEN_LIB, $UDEV_RULE, the /etc/hosts line."
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
                       --cris-msi=FILE, --ireps-msi=FILE   the vendors' Windows installers
                                      (default: searched in ~/Downloads); CRIS/IREPS are
                                      built from them with the Linux patch kit (kit/)
                       --ui-scale=N   CRIS/IREPS window scale (default auto = like the desktop)
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
