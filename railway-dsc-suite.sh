#!/usr/bin/env bash
# ==============================================================================
#  Railway DSC Signer Suite - portable installer + self-healing supervisor
#
#  Installs and keeps alive the three Indian Railways signer services:
#    eOffice  NIC Digital Signer Service 7.0.6  https://127.0.0.1:55103
#             + v4.1 compatibility bridge       https://127.0.0.1:55101
#    CRIS     CrisSigner                        wss://127.0.0.1:2039
#    IREPS    IREPSSigner                       wss://127.0.0.1:2175
#
#  Workflow
#    1. On a machine where everything already works:   ./railway-dsc-suite.sh pack
#       -> produces ONE file, railway-dsc-suite-<date>.run (script + payload).
#    2. Copy that file to any Linux PC and run:        bash railway-dsc-suite-<date>.run install
#       Run it as the normal desktop user. It asks for sudo only for the few
#       system-level steps (packages, /usr/local, token driver, udev, /etc/hosts).
#
#  Self-healing (installed automatically)
#    - every service restarts itself if it exits or is killed (Restart=always)
#    - a watchdog runs every 3 minutes: probes each port for a real answer,
#      restarts hung services, restores damaged or missing program files from a
#      kept copy, removes duplicate signer instances, rewrites missing units,
#      rotates oversized logs
#    - without systemd, a small supervisor started from desktop autostart does
#      the same job
#
#  Commands: install | pack | status | heal | restart | stop | start | logs |
#            trust | uninstall | help
# ==============================================================================
set -u
set -o pipefail

SUITE_VERSION="3.0.0"
MARKER="__PAYLOAD_BELOW__"
SELF="$(readlink -f "${BASH_SOURCE[0]}")"

# ------------------------------------------------------------------ layout ---
EOFFICE_DIR="/usr/local/DigitalSignerService-7.0.6"
EOFFICE_JAR="$EOFFICE_DIR/DigitalSignerService-7.0.6.jar"
JRE_JAVA="$EOFFICE_DIR/jre/bin/java"
HOSTS_NAME="eoffsigner.eoffice.gov.in"
HOSTS_ADDR="127.0.5.1"
VENDOR_HOOK="/etc/profile.d/DSC706-start.sh"
MTOKEN_LIB="/usr/lib/libcryptoid_pkcs11.so"
UDEV_RULE="/etc/udev/rules.d/90-mtoken.rules"

set_user_paths() {            # $1 = home directory
    U_HOME="$1"
    EOFFICE_WORK="$U_HOME/DigitalSignerService-7.0.6"
    EOFFICE_LOGS="$U_HOME/DigitalSignerService-7.0.6-Logs"
    CRIS_DIR="$U_HOME/CrisSigner_Linux"
    IREPS_DIR="$U_HOME/IREPSSigner_Linux"
    PROXY_DIR="$U_HOME/.config/eoffice-proxy"
    CONF_DIR="$U_HOME/.config/railway-dsc"
    CONF_FILE="$CONF_DIR/suite.conf"
    SHARE_DIR="$U_HOME/.local/share/railway-dsc"
    KEEP_DIR="$SHARE_DIR/keep"
    STATE_DIR="$SHARE_DIR/state"
    MANIFEST="$SHARE_DIR/manifest.sha256"
    LAUNCH="$SHARE_DIR/launch.sh"
    PROBE="$SHARE_DIR/probe.py"
    HEAL_LOG="$SHARE_DIR/heal.log"
    BIN="$U_HOME/.local/bin/railway-dsc"
    UNIT_DIR="$U_HOME/.config/systemd/user"
    AUTOSTART="$U_HOME/.config/autostart/railway-dsc-supervisor.desktop"
}
set_user_paths "$HOME"

# service table: name | systemd unit | probe kind | port
SVCS="eoffice proxy cris ireps"
svc_unit()  { case "$1" in eoffice) echo eofficesigner;; proxy) echo eofficesigner-proxy;; cris) echo crissigner;; ireps) echo irepssigner;; esac; }
svc_kind()  { case "$1" in eoffice|proxy) echo http;; *) echo ws;; esac; }
svc_port()  { case "$1" in eoffice) echo 55103;; proxy) echo 55101;; cris) echo 2039;; ireps) echo 2175;; esac; }
svc_label() { case "$1" in eoffice) echo "eOffice signer (NIC 7.0.6)";; proxy) echo "eOffice v4.1 bridge";; cris) echo "CrisSigner";; ireps) echo "IREPSSigner";; esac; }

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

have_systemd_user() { have systemctl && systemctl --user show-environment >/dev/null 2>&1; }
sha() { sha256sum "$1" 2>/dev/null | cut -d' ' -f1; }

hook_active() { [ -f "$VENDOR_HOOK" ] && grep -q 'DigitalSignerService-7.0.6.jar' "$VENDOR_HOOK" 2>/dev/null; }
token_present() { grep -qsi '^055c$' /sys/bus/usb/devices/*/idVendor 2>/dev/null; }
bundled_java_ok() { [ -x "$1" ] && "$1" -version >/dev/null 2>&1; }

find_p11_lib() {
    local l
    for l in "${P11_LIB:-}" "$MTOKEN_LIB" /usr/lib/libcastle.so.1.0.0 /usr/lib/libcastle.so \
             /usr/lib/x86_64-linux-gnu/libcastle.so /usr/lib64/libcastle.so \
             /usr/lib/WatchData/eMudhra_3.4.3/lib/libwdpkcs_eMudhra_343.so \
             /usr/lib/WatchData/TRUSTKEY/lib/libwdpkcs_TRUSTKEY.so \
             /usr/lib/WatchData/ProxKey/lib/libwdpkcs_SignatureP11.so \
             /usr/lib/WatchData/PROXKey/lib/libwdpkcs.so /usr/lib/libwdpkcs.so \
             /usr/lib/libmTokenPKCS11.so /usr/lib/libaetpkss.so.2.3.1 /usr/lib/libeTPkcs11.so \
             /usr/lib/x86_64-linux-gnu/opensc-pkcs11.so /usr/lib64/opensc-pkcs11.so \
             /usr/lib64/pkcs11/opensc-pkcs11.so /usr/lib/opensc-pkcs11.so /usr/lib/pkcs11/opensc-pkcs11.so; do
        [ -n "$l" ] && [ -f "$l" ] && { echo "$l"; return 0; }
    done
    return 1
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
probe()   { python3 "$PROBE" "$(svc_kind "$1")" "$(svc_port "$1")" >/dev/null 2>&1; }

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
    cat > "$PROBE" <<'PY'
#!/usr/bin/env python3
"""Functional health probe: exit 0 only if the signer really answers.
usage: probe.py http|ws PORT"""
import base64, os, socket, ssl, sys

def tls(port):
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    raw = socket.create_connection(("127.0.0.1", port), timeout=8)
    raw.settimeout(8)
    return ctx.wrap_socket(raw, server_hostname="127.0.0.1")

def read_until(sock, token, limit=65536):
    data = b""
    while token not in data and len(data) < limit:
        chunk = sock.recv(4096)
        if not chunk:
            break
        data += chunk
    return data

def http(port):
    s = tls(port)
    try:
        s.sendall(b"GET /check/isLive HTTP/1.0\r\nHost: 127.0.0.1\r\n"
                  b"Origin: https://localhost\r\nConnection: close\r\n\r\n")
        data = read_until(s, b"version")
        return b" 200" in data.split(b"\r\n", 1)[0] and b"success" in data
    finally:
        s.close()

def ws(port):
    s = tls(port)
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
        sys.exit(0 if (http(port) if kind == "http" else ws(port)) else 1)
    except Exception as exc:
        sys.stderr.write("probe failed: %s\n" % exc)
        sys.exit(1)
PY
    chmod 755 "$PROBE"
}

write_launcher() {
    cat > "$LAUNCH" <<LAUNCH_EOF
#!/usr/bin/env bash
# Generated by railway-dsc-suite $SUITE_VERSION - do not edit; re-run "railway-dsc install".
# usage: launch.sh eoffice|proxy|cris|ireps
EOFFICE_DIR="$EOFFICE_DIR"
EOFFICE_JAR="$EOFFICE_JAR"
EOFFICE_WORK="$EOFFICE_WORK"
EOFFICE_LOGS="$EOFFICE_LOGS"
CRIS_DIR="$CRIS_DIR"
IREPS_DIR="$IREPS_DIR"
PROXY_DIR="$PROXY_DIR"
CONF_FILE="$CONF_FILE"
LAUNCH_EOF
    cat >> "$LAUNCH" <<'LAUNCH_EOF'
SVC="${1:-}"
DSC_UI_SCALE=1; P11_LIB=""; DSC_PROXY_BIND="127.0.0.1,127.0.5.1"
[ -f "$CONF_FILE" ] && . "$CONF_FILE"
export DSC_PROXY_BIND

if [ "$SVC" = proxy ]; then
    exec python3 "$PROXY_DIR/eoffice_proxy.py"
fi

# --- Java: bundled JRE 17 if it runs here, otherwise a system Java -------------
JAVA_BIN=""
if [ -x "$EOFFICE_DIR/jre/bin/java" ] && "$EOFFICE_DIR/jre/bin/java" -version >/dev/null 2>&1; then
    JAVA_BIN="$EOFFICE_DIR/jre/bin/java"
elif command -v java >/dev/null 2>&1; then
    JAVA_BIN="$(command -v java)"
fi
[ -n "$JAVA_BIN" ] || { echo "No usable Java runtime found."; exit 1; }
JAVA_MAJOR=$("$JAVA_BIN" -version 2>&1 | awk -F'"' '/version/{split($2,v,"."); print (v[1]=="1")?v[2]:v[1]; exit}')

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

UI=("-Dsun.java2d.uiScale.enabled=true" "-Dsun.java2d.uiScale=${DSC_UI_SCALE}")

if [ "$SVC" = eoffice ]; then
    mkdir -p "$EOFFICE_WORK" "$EOFFICE_LOGS" 2>/dev/null
    cd "$EOFFICE_WORK" || exit 1
    if [ -w "$EOFFICE_LOGS" ] || [ -w "$EOFFICE_LOGS/output.log" ]; then
        exec >>"$EOFFICE_LOGS/output.log" 2>>"$EOFFICE_LOGS/errorOutput.log"
    fi
    # java.awt.headless=true is harmless here: the application resets it to false itself.
    exec "$JAVA_BIN" "${UI[@]}" -Djava.awt.headless=true \
        -Dorg.jcp.xml.dsig.secureValidation=false -jar "$EOFFICE_JAR"
fi

case "$SVC" in
    cris)  APP_DIR="$CRIS_DIR";  APP_JAR="crissigner_app.jar" ;;
    ireps) APP_DIR="$IREPS_DIR"; APP_JAR="irepssigner_app.jar" ;;
    *) echo "usage: launch.sh eoffice|proxy|cris|ireps"; exit 2 ;;
esac
cd "$APP_DIR" || exit 1
OPTS=("-Djavax.accessibility.assistive_technologies= " "-Djava.util.Arrays.useLegacyMergeSort=true" "${UI[@]}")
if [ "${JAVA_MAJOR:-17}" -gt 8 ] 2>/dev/null; then
    OPTS+=("--add-exports=jdk.crypto.cryptoki/sun.security.pkcs11=ALL-UNNAMED"
           "--add-opens=jdk.crypto.cryptoki/sun.security.pkcs11=ALL-UNNAMED"
           "--add-opens=java.base/java.lang=ALL-UNNAMED"
           "--add-opens=java.desktop/javax.swing=ALL-UNNAMED"
           "--add-opens=java.desktop/java.awt=ALL-UNNAMED"
           "--add-opens=java.desktop/sun.awt=ALL-UNNAMED")
fi
if [ -z "$P11_LIB" ] || [ ! -f "$P11_LIB" ]; then
    P11_LIB=""
    for l in /usr/lib/libcryptoid_pkcs11.so /usr/lib/libcastle.so.1.0.0 /usr/lib/libcastle.so \
             /usr/lib/x86_64-linux-gnu/libcastle.so /usr/lib64/libcastle.so \
             /usr/lib/WatchData/eMudhra_3.4.3/lib/libwdpkcs_eMudhra_343.so \
             /usr/lib/WatchData/TRUSTKEY/lib/libwdpkcs_TRUSTKEY.so \
             /usr/lib/WatchData/ProxKey/lib/libwdpkcs_SignatureP11.so \
             /usr/lib/WatchData/PROXKey/lib/libwdpkcs.so /usr/lib/libwdpkcs.so \
             /usr/lib/libmTokenPKCS11.so /usr/lib/libaetpkss.so.2.3.1 /usr/lib/libeTPkcs11.so \
             /usr/lib/x86_64-linux-gnu/opensc-pkcs11.so /usr/lib64/opensc-pkcs11.so \
             /usr/lib64/pkcs11/opensc-pkcs11.so /usr/lib/opensc-pkcs11.so /usr/lib/pkcs11/opensc-pkcs11.so; do
        [ -f "$l" ] && { P11_LIB="$l"; break; }
    done
fi
[ -n "$P11_LIB" ] && OPTS+=("-Dwebsigner.pkcs11.library=$P11_LIB")
CP="$APP_DIR/lib/windows-laf-stub.jar:$APP_DIR/lib/windowslookandfell-stub.jar:$APP_DIR/$APP_JAR:$APP_DIR/lib/*"
exec "$JAVA_BIN" "${OPTS[@]}" -cp "$CP" server.ServerUI
LAUNCH_EOF
    chmod 755 "$LAUNCH"
}

write_units() {
    mkdir -p "$UNIT_DIR"
    local s u extra
    for s in $SVCS; do
        u=$(svc_unit "$s"); extra=""
        [ "$s" = proxy ] && extra=$'After=eofficesigner.service\nWants=eofficesigner.service'
        [ "$s" = eoffice ] && extra=$'After=network.target'
        cat > "$UNIT_DIR/$u.service" <<UNIT_EOF
# Generated by railway-dsc-suite $SUITE_VERSION
[Unit]
Description=$(svc_label "$s")
$extra
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

install_self() {              # copy this script WITHOUT the payload to ~/.local/bin
    mkdir -p "$(dirname "$BIN")"
    local n; n=$(grep -a -n -m1 "^${MARKER}\$" "$SELF" | cut -d: -f1)
    if [ -n "$n" ]; then head -n "$((n-1))" "$SELF" > "$BIN.tmp"; else cat "$SELF" > "$BIN.tmp"; fi
    chmod 755 "$BIN.tmp"; mv -f "$BIN.tmp" "$BIN"
}

# The files the watchdog can restore by itself: everything except the 300 MB JRE.
keep_list() {
    echo "$EOFFICE_JAR"
    find "$CRIS_DIR" "$IREPS_DIR" -maxdepth 2 -type f \( -name '*.jar' -o -name 'certificate.crt' \) 2>/dev/null
    for f in eoffice_proxy.py fullchain.pem key.pem ca.pem; do echo "$PROXY_DIR/$f"; done
    echo "$LAUNCH"; echo "$PROBE"
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
PAYLOAD=""; PAYLOAD_TMP=""
cleanup() { [ -n "$PAYLOAD_TMP" ] && rm -rf "$PAYLOAD_TMP"; }
locate_payload() {
    local n; n=$(grep -a -n -m1 "^${MARKER}\$" "$SELF" | cut -d: -f1)
    if [ -n "$n" ]; then
        mkdir -p "$HOME/.cache"
        PAYLOAD_TMP=$(mktemp -d "$HOME/.cache/railway-dsc-payload.XXXXXX") || die "cannot create a temporary directory"
        trap cleanup EXIT
        info "Unpacking embedded payload (about 450 MB) ..."
        tail -n "+$((n+1))" "$SELF" | tar -xzf - -C "$PAYLOAD_TMP" || die "payload is damaged - copy the .run file again"
        PAYLOAD="$PAYLOAD_TMP"
    elif [ -d "$(dirname "$SELF")/payload" ]; then
        PAYLOAD="$(dirname "$SELF")/payload"
    fi
    if [ -n "$PAYLOAD" ] && [ -f "$PAYLOAD/MANIFEST.sha256" ]; then
        ( cd "$PAYLOAD" && sha256sum --quiet -c MANIFEST.sha256 >/dev/null 2>&1 ) || die "payload failed its checksum - copy the .run file again"
    fi
}

cmd_pack() {
    step "Packing this machine's working installation"
    local out="${1:-$PWD/railway-dsc-suite-$(date +%Y%m%d).run}" st s bad=0
    [ -f "$EOFFICE_JAR" ] && [ -d "$EOFFICE_DIR/jre" ] || die "eOffice signer not found in $EOFFICE_DIR"
    [ -f "$CRIS_DIR/crissigner_app.jar" ]  || die "CrisSigner not found in $CRIS_DIR"
    [ -f "$IREPS_DIR/irepssigner_app.jar" ] || die "IREPSSigner not found in $IREPS_DIR"
    [ -f "$PROXY_DIR/eoffice_proxy.py" ] && [ -f "$PROXY_DIR/key.pem" ] || die "eOffice bridge not found in $PROXY_DIR"
    if [ -x "$PROBE" ]; then
        for s in $SVCS; do probe "$s" || { warn "$(svc_label "$s") is not answering right now - packing it anyway"; bad=1; }; done
        [ $bad = 0 ] && ok "All four endpoints answer; packing a known-good state"
    fi
    mkdir -p "$HOME/.cache"; st=$(mktemp -d "$HOME/.cache/railway-dsc-pack.XXXXXX") || die "no temp dir"
    # shellcheck disable=SC2064
    trap "rm -rf '$st'" EXIT
    mkdir -p "$st/eoffice" "$st/cris" "$st/ireps" "$st/proxy" "$st/drivers"
    cp -a "$EOFFICE_DIR/jre" "$st/eoffice/"
    cp -p "$EOFFICE_JAR" "$st/eoffice/"
    [ -f "$EOFFICE_DIR/DSC48x48.png" ] && cp -p "$EOFFICE_DIR/DSC48x48.png" "$st/eoffice/"
    local d
    for d in cris ireps; do
        local src="$CRIS_DIR"; [ $d = ireps ] && src="$IREPS_DIR"
        cp -p "$src"/*.jar "$st/$d/"
        cp -a "$src/lib" "$st/$d/"
        for f in certificate.crt icon.png; do [ -f "$src/$f" ] && cp -p "$src/$f" "$st/$d/"; done
    done
    for f in fullchain.pem key.pem ca.pem cert.pem; do [ -f "$PROXY_DIR/$f" ] && cp -p "$PROXY_DIR/$f" "$st/proxy/"; done
    # Make the bridge location-independent and loopback-only (it used to listen on all interfaces).
    python3 - "$PROXY_DIR/eoffice_proxy.py" "$st/proxy/eoffice_proxy.py" <<'PY' || die "could not prepare the bridge script"
import re, sys
src = open(sys.argv[1], encoding="utf-8").read()
if "DSC_PROXY_BIND" not in src:
    src, n1 = re.subn(r'^CONFIG_DIR = .*$', 'CONFIG_DIR = os.path.dirname(os.path.abspath(__file__))', src, count=1, flags=re.M)
    new_tail = '''    import threading
    binds = [b.strip() for b in os.environ.get("DSC_PROXY_BIND", "127.0.0.1,127.0.5.1").split(",") if b.strip()]
    servers = []
    for addr in binds:
        try:
            httpd = ThreadedHTTPServer((addr, port), DSCProxyHandler)
        except OSError as exc:
            sys.stderr.write(f"[eOffice-Bridge] cannot bind {addr}:{port}: {exc}\\n")
            continue
        httpd.socket = ssl_ctx.wrap_socket(httpd.socket, server_side=True)
        servers.append(httpd)
        print(f"eOffice DSC Bridge listening on https://{addr}:{port} -> {BACKEND_URL}", flush=True)
    if not servers:
        sys.exit(1)
    for extra in servers[1:]:
        threading.Thread(target=extra.serve_forever, daemon=True).start()
    servers[0].serve_forever()
'''
    src, n2 = re.subn(r'^    server_address = \("0\.0\.0\.0", port\)\n.*?httpd\.serve_forever\(\)\n', lambda m: new_tail, src, count=1, flags=re.M | re.S)
    if n1 != 1 or n2 != 1:
        sys.exit("bridge script has an unexpected layout")
compile(src, "eoffice_proxy.py", "exec")
open(sys.argv[2], "w", encoding="utf-8").write(src)
PY
    [ -f "$MTOKEN_LIB" ] && cp -p "$MTOKEN_LIB" "$st/drivers/"
    ( cd "$st" && find . -type f ! -name MANIFEST.sha256 -print0 | sort -z | xargs -0 sha256sum > MANIFEST.sha256 )
    info "Compressing ..."
    local n; n=$(grep -a -n -m1 "^${MARKER}\$" "$SELF" | cut -d: -f1)
    { if [ -n "$n" ]; then head -n "$((n-1))" "$SELF"; else cat "$SELF"; fi
      echo "$MARKER"
      tar -czf - -C "$st" . ; } > "$out.tmp" || die "packing failed"
    chmod 700 "$out.tmp"; mv -f "$out.tmp" "$out"     # contains the bridge's TLS key: owner only
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
        else return 1; fi && info "installed $p" || warn "could not install package '$p' - install it by hand if a later step complains"
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
        xlibs:apt) echo "libxtst6 libxi6 libxrender1 libfreetype6 fontconfig";;
        xlibs:zypper) echo "libXtst6 libXi6 libXrender1 libfreetype6 fontconfig";;
        xlibs:pacman) echo "libxtst libxi libxrender freetype2 fontconfig";;
        xlibs:apk) echo "libxtst libxi libxrender freetype fontconfig ttf-dejavu";;
        xlibs:*) echo "libXtst libXi libXrender freetype fontconfig";;
        java:apt) echo openjdk-17-jre;;                  java:dnf|java:zypper) echo java-17-openjdk;;
        java:pacman) echo jre17-openjdk;;                java:apk|java:xbps) echo openjdk17-jre;;
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

cmd_root() {                  # internal: runs under sudo.  args: user payload_dir need_java(0|1)
    local user="$1" payload="$2" need_java="$3" home grp
    [ "$(id -u)" -eq 0 ] || die "root phase must run as root"
    home=$(getent passwd "$user" | cut -d: -f6); [ -n "$home" ] || die "unknown user $user"
    grp=$(id -gn "$user")
    set_user_paths "$home"
    step "System-level setup (as root)"

    have apt-get && apt-get update -qq >/dev/null 2>&1
    have python3 || pkg_install $(pkgs_for python)
    have certutil || pkg_install $(pkgs_for certutil)
    xlibs_missing && pkg_install $(pkgs_for xlibs)
    [ "$need_java" = 1 ] && pkg_install $(pkgs_for java)
    if ! have pcscd && [ ! -x /usr/sbin/pcscd ]; then pkg_install $(pkgs_for smartcard); fi

    mkdir -p "$EOFFICE_DIR" && chown "$user:$grp" "$EOFFICE_DIR" && ok "$EOFFICE_DIR ready"
    [ -d "$EOFFICE_LOGS" ] && chown -R "$user:$grp" "$EOFFICE_LOGS"

    if [ ! -f "$MTOKEN_LIB" ] && [ -f "$payload/drivers/libcryptoid_pkcs11.so" ] && [ "$(uname -m)" = x86_64 ]; then
        install -o root -g root -m 0644 "$payload/drivers/libcryptoid_pkcs11.so" "$MTOKEN_LIB" && ok "mToken PKCS#11 driver installed"
    fi
    if ! grep -rqsi '055c' /etc/udev/rules.d/ 2>/dev/null && [ -d /etc/udev/rules.d ]; then
        cat > "$UDEV_RULE" <<'EOF'
# Longmai mToken CryptoID - grant the active desktop user raw USB access.
SUBSYSTEM=="usb", ATTRS{idVendor}=="055c", ATTRS{idProduct}=="0223", TAG+="uaccess"
SUBSYSTEM=="usb", ATTRS{idVendor}=="055c", ATTRS{idProduct}=="0229", TAG+="uaccess"
EOF
        udevadm control --reload-rules 2>/dev/null; udevadm trigger --subsystem-match=usb 2>/dev/null
        ok "udev rule for the token installed (re-plug the token once)"
    fi
    if ! grep -qs "$HOSTS_NAME" /etc/hosts; then
        printf '%s\t%s\n' "$HOSTS_ADDR" "$HOSTS_NAME" >> /etc/hosts && ok "/etc/hosts: $HOSTS_NAME -> $HOSTS_ADDR"
    fi
    if hook_active; then
        [ -e "$EOFFICE_DIR/DSC706-start.sh.vendor" ] || cp -p "$VENDOR_HOOK" "$EOFFICE_DIR/DSC706-start.sh.vendor"
        printf '%s\n' "# Disabled by railway-dsc-suite: the signer is started by the user service" \
                      "# eofficesigner.service; starting it here too made every login shell kill it." > "$VENDOR_HOOK"
        ok "Vendor login-shell autostart disabled (it kept killing the running signer)"
    fi
    return 0
}

# ================================================================== install ===
copy_if_changed() {           # src dst [mode]  -> sets CHANGED=1 when it wrote
    local src="$1" dst="$2" mode="${3:-}"
    if [ -f "$dst" ] && cmp -s "$src" "$dst"; then return 0; fi
    mkdir -p "$(dirname "$dst")"
    [ -f "$dst" ] && cp -p "$dst" "$dst.bak-$(date +%Y%m%d-%H%M%S)"
    cp -p "$src" "$dst.new" && mv -f "$dst.new" "$dst" || die "cannot write $dst"
    [ -n "$mode" ] && chmod "$mode" "$dst"
    CHANGED=1
}

trust_certs() {
    step "Trusting the local signer certificates in browsers"
    have certutil || { warn "certutil not available - browsers will show a certificate warning for the local signers"; return 0; }
    mkdir -p "$U_HOME/.pki/nssdb"
    [ -f "$U_HOME/.pki/nssdb/cert9.db" ] || certutil -d "sql:$U_HOME/.pki/nssdb" -N --empty-password 2>/dev/null
    local dbs=("$U_HOME/.pki/nssdb") d n item name file flags
    for d in "$U_HOME"/.mozilla/firefox/* "$U_HOME"/.config/mozilla/firefox/* \
             "$U_HOME"/snap/firefox/common/.mozilla/firefox/* \
             "$U_HOME"/.var/app/org.mozilla.firefox/.mozilla/firefox/* \
             "$U_HOME"/.librewolf/* "$U_HOME"/.waterfox/*; do
        [ -f "$d/cert9.db" ] && dbs+=("$d")
    done
    # Minimum trust only: the two vendor CAs may vouch for web servers (C) and nothing else
    # (no client-auth, e-mail or code-signing trust); the CrisSigner certificate is a
    # self-signed leaf whose key ships with the app, so it is trusted as that one peer (P) only.
    local certs=("eOfficeCA2022|$PROXY_DIR/ca.pem|C,,"
                 "IREPSSigner eMudhra Local CA|$IREPS_DIR/certificate.crt|C,,"
                 "CrisSigner 127.0.0.1|$CRIS_DIR/certificate.crt|P,,")
    n=0
    for d in "${dbs[@]}"; do
        for item in "${certs[@]}"; do
            name="${item%%|*}"; file="${item#*|}"; file="${file%%|*}"; flags="${item##*|}"
            [ -f "$file" ] || continue
            if certutil -d "sql:$d" -L -n "$name" >/dev/null 2>&1; then
                certutil -d "sql:$d" -M -n "$name" -t "$flags" 2>/dev/null
            else
                certutil -d "sql:$d" -A -n "$name" -t "$flags" -i "$file" 2>/dev/null || warn "could not add '$name' to $d"
            fi
        done
        n=$((n+1))
    done
    ok "Certificates trusted in $n browser store(s) - restart the browser to pick them up"
    if [ -d "$U_HOME/snap/firefox" ]; then
        info "Note: Firefox here is a snap. That is fine for these signers (the browser only talks to localhost)."
    fi
}

cmd_install() {
    local no_root=0 ui_scale="" a
    for a in "$@"; do case "$a" in
        --no-root) no_root=1;; --ui-scale=*) ui_scale="${a#*=}";;
        *) die "unknown option $a";; esac; done
    [ "$(id -u)" -ne 0 ] || die "Run this as your normal desktop user, not root. It will ask for sudo when needed."
    echo "${B}Railway DSC Signer Suite $SUITE_VERSION - install${N}"
    case "$(uname -m)" in x86_64) ;; *) warn "Architecture $(uname -m): the bundled Java and the mToken driver are x86_64 only; a system Java will be used and you need your token vendor's driver for this CPU.";; esac

    locate_payload
    local upgrade_only=0
    if [ -z "$PAYLOAD" ]; then
        [ -f "$EOFFICE_JAR" ] && [ -f "$CRIS_DIR/crissigner_app.jar" ] && [ -f "$IREPS_DIR/irepssigner_app.jar" ] && [ -f "$PROXY_DIR/eoffice_proxy.py" ] \
            || die "No payload attached and no existing installation found. Build the .run file with 'pack' on a working machine first."
        upgrade_only=1
        info "No payload attached: keeping the program files already on this machine and (re)installing the self-healing layer."
    fi

    # ---- does anything need root? ---------------------------------------
    local need_java=0 reasons=()
    if ! bundled_java_ok "$JRE_JAVA"; then
        if [ -n "$PAYLOAD" ] && bundled_java_ok "$PAYLOAD/eoffice/jre/bin/java"; then :;
        elif have java; then :; else need_java=1; reasons+=("a Java 17 runtime"); fi
    fi
    have python3 || reasons+=("python3")
    have certutil || reasons+=("certutil (NSS tools)")
    xlibs_missing && reasons+=("X11/font libraries for Java")
    [ -d "$EOFFICE_DIR" ] && [ -w "$EOFFICE_DIR" ] || reasons+=("$EOFFICE_DIR")
    [ -d "$EOFFICE_LOGS" ] && [ ! -w "$EOFFICE_LOGS" ] && reasons+=("ownership of the log folder")
    [ ! -f "$MTOKEN_LIB" ] && [ -n "$PAYLOAD" ] && [ -f "$PAYLOAD/drivers/libcryptoid_pkcs11.so" ] && [ "$(uname -m)" = x86_64 ] && reasons+=("mToken driver")
    [ -d /etc/udev/rules.d ] && ! grep -rqsi '055c' /etc/udev/rules.d/ && reasons+=("udev rule for the token")
    grep -qs "$HOSTS_NAME" /etc/hosts || reasons+=("/etc/hosts entry")
    hook_active && reasons+=("disable the vendor autostart hook")

    if [ ${#reasons[@]} -gt 0 ] && [ $no_root = 0 ]; then
        step "Administrator rights needed for: $(IFS=,; echo "${reasons[*]}" | sed 's/,/, /g')"
        if have sudo; then
            sudo bash "$SELF" __root "$(id -un)" "${PAYLOAD:-/nonexistent}" "$need_java" || die "system-level setup failed"
        else
            warn "sudo is not installed. Run this as root, then run install again:"
            info "su -c 'bash $SELF __root $(id -un) ${PAYLOAD:-/nonexistent} $need_java'"
            [ -z "$PAYLOAD_TMP" ] || { trap - EXIT; info "(payload kept in $PAYLOAD_TMP for that command)"; }
            exit 1
        fi
    elif [ ${#reasons[@]} -gt 0 ]; then
        warn "Skipped (--no-root): ${reasons[*]}"
    else
        ok "Nothing needs administrator rights"
    fi
    have python3 || die "python3 is required and could not be installed"

    # ---- program files ----------------------------------------------------
    step "Installing program files"
    CHANGED=0
    mkdir -p "$CONF_DIR" "$SHARE_DIR" "$STATE_DIR" "$EOFFICE_WORK/conf" "$PROXY_DIR"
    chmod 700 "$PROXY_DIR"
    if [ $upgrade_only = 0 ]; then
        [ -w "$EOFFICE_DIR" ] || die "$EOFFICE_DIR is not writable - run install again without --no-root"
        if ! bundled_java_ok "$JRE_JAVA" && [ -d "$PAYLOAD/eoffice/jre" ] && bundled_java_ok "$PAYLOAD/eoffice/jre/bin/java"; then
            rm -rf "$EOFFICE_DIR/jre"; cp -a "$PAYLOAD/eoffice/jre" "$EOFFICE_DIR/" || die "cannot copy the Java runtime"
            CHANGED=1; ok "Bundled Java 17 runtime installed"
        fi
        copy_if_changed "$PAYLOAD/eoffice/DigitalSignerService-7.0.6.jar" "$EOFFICE_JAR" 644
        [ -f "$PAYLOAD/eoffice/DSC48x48.png" ] && copy_if_changed "$PAYLOAD/eoffice/DSC48x48.png" "$EOFFICE_DIR/DSC48x48.png" 644
        local d dst f rel
        for d in cris ireps; do
            dst="$CRIS_DIR"; [ $d = ireps ] && dst="$IREPS_DIR"
            mkdir -p "$dst/lib"
            while IFS= read -r f; do
                rel="${f#"$PAYLOAD/$d/"}"
                if [ -L "$f" ]; then [ -e "$dst/$rel" ] || cp -a "$f" "$dst/$rel"
                elif ! { [ -f "$dst/$rel" ] && cmp -s "$f" "$dst/$rel"; }; then
                    mkdir -p "$(dirname "$dst/$rel")"; cp -p "$f" "$dst/$rel" || die "cannot write $dst/$rel"; CHANGED=1
                fi
            done < <(find "$PAYLOAD/$d" \( -type f -o -type l \))
        done
        copy_if_changed "$PAYLOAD/proxy/eoffice_proxy.py" "$PROXY_DIR/eoffice_proxy.py" 755
        for f in fullchain.pem ca.pem cert.pem; do [ -f "$PAYLOAD/proxy/$f" ] && copy_if_changed "$PAYLOAD/proxy/$f" "$PROXY_DIR/$f" 644; done
        copy_if_changed "$PAYLOAD/proxy/key.pem" "$PROXY_DIR/key.pem" 600
        ok "eOffice signer, bridge, CrisSigner and IREPSSigner files in place"
    else
        ok "Existing program files kept"
    fi
    if ! bundled_java_ok "$JRE_JAVA" && ! have java; then die "No working Java runtime. Install a Java 17 JRE with your package manager and run install again."; fi

    # ---- settings -----------------------------------------------------------
    if [ ! -f "$CONF_FILE" ]; then
        if [ -z "$ui_scale" ]; then
            ui_scale=$(sed -n 's/.*uiScale=\([0-9.]*\).*/\1/p' "$UNIT_DIR/eofficesigner.service" 2>/dev/null | head -1)
            [ -n "$ui_scale" ] || ui_scale=1
        fi
        cat > "$CONF_FILE" <<EOF
# Railway DSC Signer Suite settings.  After editing:  railway-dsc restart
# Size of the signer windows and PIN prompt: 1 = normal, 2 = HiDPI / 4K screens.
DSC_UI_SCALE=$ui_scale
# Token driver (PKCS#11 library). Leave empty to auto-detect.
P11_LIB=""
# Addresses the eOffice bridge listens on (loopback only).
DSC_PROXY_BIND="127.0.0.1,$HOSTS_ADDR"
EOF
    elif [ -n "$ui_scale" ]; then
        sed -i "s/^DSC_UI_SCALE=.*/DSC_UI_SCALE=$ui_scale/" "$CONF_FILE"
    fi
    # shellcheck disable=SC1090
    . "$CONF_FILE"

    local p11; p11=$(find_p11_lib || true)
    if [ ! -s "$EOFFICE_WORK/conf/all_tokens.properties" ] && [ -n "$p11" ]; then
        local tname="Token"; [ "$p11" = "$MTOKEN_LIB" ] && tname="mToken"
        printf '1.name=%s\n1.path=%s\n1.status=1\n' "$tname" "$p11" > "$EOFFICE_WORK/conf/all_tokens.properties"
        printf 'service.start=false\nservice.locale=en_in\nprocess.type=custom\nselected.token.name=%s\nselected.token.path=%s\nused.token.name=%s\nused.token.path=%s\n' \
            "$tname" "$p11" "$tname" "$p11" > "$EOFFICE_WORK/conf/default_token.properties"
        ok "eOffice signer pointed at token driver $p11"
    fi
    [ -n "$p11" ] && ok "Token driver: $p11" || warn "No PKCS#11 token driver found. Install your token vendor's Linux driver, then run: railway-dsc restart"

    # ---- self-healing layer ---------------------------------------------------
    step "Installing launchers, services and the watchdog"
    local before after
    before=$(cat "$LAUNCH" "$UNIT_DIR"/eofficesigner*.service "$UNIT_DIR"/crissigner.service "$UNIT_DIR"/irepssigner.service 2>/dev/null | sha256sum)
    if ls "$UNIT_DIR"/eofficesigner*.service "$UNIT_DIR"/crissigner.service "$UNIT_DIR"/irepssigner.service >/dev/null 2>&1 \
       && ! grep -qs 'railway-dsc-suite' "$UNIT_DIR/eofficesigner.service"; then
        local prev; prev="$CONF_DIR/previous-units-$(date +%Y%m%d-%H%M%S)"; mkdir -p "$prev"
        cp -p "$UNIT_DIR"/eofficesigner*.service "$UNIT_DIR"/crissigner.service "$UNIT_DIR"/irepssigner.service "$prev/" 2>/dev/null
        info "Previous service definitions saved in $prev"
    fi
    write_probe; write_launcher; install_self
    if have_systemd_user; then
        write_units
        systemctl --user daemon-reload
        systemctl --user enable eofficesigner.service eofficesigner-proxy.service crissigner.service irepssigner.service railway-dsc-heal.timer >/dev/null 2>&1
        rm -f "$AUTOSTART"
        ok "systemd user services + watchdog timer enabled"
    else
        mkdir -p "$(dirname "$AUTOSTART")"
        printf '[Desktop Entry]\nType=Application\nName=Railway DSC signer supervisor\nExec=%s supervise\nX-GNOME-Autostart-enabled=true\nNoDisplay=true\n' "$BIN" > "$AUTOSTART"
        ok "No systemd user session here: supervisor registered in desktop autostart"
    fi
    after=$(cat "$LAUNCH" "$UNIT_DIR"/eofficesigner*.service "$UNIT_DIR"/crissigner.service "$UNIT_DIR"/irepssigner.service 2>/dev/null | sha256sum)
    [ "$before" = "$after" ] || CHANGED=1
    refresh_keep
    ok "Repair copies stored ($(wc -l < "$MANIFEST") files, $(du -sh "$KEEP_DIR" | cut -f1))"

    trust_certs

    # ---- start and verify -----------------------------------------------------
    step "Starting services"
    local s
    rm -f "$STATE_DIR/stopped"
    if have_systemd_user; then
        for s in $SVCS; do
            # restart only what changed or is down; an untouched healthy service keeps running
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
    if [ $rc = 0 ]; then ok "Installation complete. Everyday command: ${B}railway-dsc status${N}"
    else warn "Installed, but something is not healthy yet - see above. The watchdog will keep retrying; check: railway-dsc logs"; fi
    case ":$PATH:" in *":$U_HOME/.local/bin:"*) ;; *) info "($U_HOME/.local/bin is not in PATH yet - log out and in, or call $BIN directly)";; esac
    return $rc
}

# ===================================================================== heal ===
restore_files() {             # returns list of services whose files were repaired
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
                    "$EOFFICE_JAR") echo eoffice;; "$CRIS_DIR"/*) echo cris;; "$IREPS_DIR"/*) echo ireps;;
                    "$PROXY_DIR"/*) echo proxy;; "$LAUNCH") echo "eoffice proxy cris ireps";;
                esac
            else hlog "ERROR could not restore $f"; fi
        else
            hlog "ERROR $f is damaged and no good repair copy exists - re-run the installer"
        fi
    done < "$MANIFEST"
}

heal_once() {
    local dry="${1:-0}" s acted=0 repaired
    mkdir -p "$STATE_DIR"
    [ -f "$STATE_DIR/stopped" ] && return 0      # user ran "railway-dsc stop"
    # 1. program files
    if [ "$dry" = 0 ]; then repaired=$(restore_files | tr '\n' ' '); else repaired=""; fi
    # 2. service definitions
    if have_systemd_user; then
        local missing=0
        for s in $SVCS; do [ -f "$UNIT_DIR/$(svc_unit "$s").service" ] || missing=1; done
        [ -f "$UNIT_DIR/railway-dsc-heal.timer" ] || missing=1
        if [ $missing = 1 ] && [ "$dry" = 0 ]; then
            write_units; systemctl --user daemon-reload
            systemctl --user enable eofficesigner.service eofficesigner-proxy.service crissigner.service irepssigner.service railway-dsc-heal.timer >/dev/null 2>&1
            hlog "REPAIRED missing service definitions"; acted=1
        fi
        # 3. duplicate eOffice signer instances (each new one kill -9s whoever holds the port)
        local main p
        main=$(svc_pid eoffice)
        for p in $(pgrep -u "$(id -u)" -f 'DigitalSignerService-7[.]0[.]6[.]jar' 2>/dev/null); do
            [ "$p" = "$main" ] && continue
            grep -qs 'eofficesigner.service' "/proc/$p/cgroup" && continue
            if [ "$dry" = 0 ]; then kill "$p" 2>/dev/null && hlog "REMOVED duplicate eOffice signer instance pid $p"; acted=1
            else echo "would remove duplicate eOffice signer pid $p"; fi
        done
    fi
    # 4. liveness
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
            svc_restart "$s"; hlog "RESTARTED $(svc_label "$s"): $why"; acted=1
        else echo "would restart $(svc_label "$s"): $why"; fi
    done
    # 5. log growth (the eOffice signer logs at DEBUG level and never rotates)
    local lf
    for lf in "$EOFFICE_LOGS/output.log" "$EOFFICE_LOGS/errorOutput.log" "$HEAL_LOG"; do
        if [ -f "$lf" ] && [ "$(stat -c %s "$lf" 2>/dev/null || echo 0)" -gt 20971520 ] && [ "$dry" = 0 ]; then
            tail -c 2097152 "$lf" > "$lf.1" 2>/dev/null && : > "$lf" && hlog "ROTATED $lf"
        fi
    done
    # 6. things only an administrator can fix: report, once a day
    local drift=""
    hook_active && drift="$drift vendor-autostart-hook-is-back"
    grep -qs "$HOSTS_NAME" /etc/hosts || drift="$drift hosts-entry-missing"
    if [ -n "$drift" ] && [ "$dry" = 0 ]; then
        local today; today=$(date +%F)
        if [ "$(cat "$STATE_DIR/drift.day" 2>/dev/null)" != "$today" ]; then
            echo "$today" > "$STATE_DIR/drift.day"
            hlog "NEEDS ADMIN:$drift - fix with: bash $BIN install"
            have notify-send && notify-send "Railway DSC signers" "A system setting needs repair. Run: railway-dsc install" 2>/dev/null
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
    echo; echo "${B}Railway DSC Signer Suite - status${N}"
    for s in $SVCS; do
        if ! svc_active "$s"; then state="${R}not running${N}"; rc=1
        elif probe "$s"; then state="${G}healthy${N}"
        else state="${Y}running, not answering yet${N}"; rc=1; fi
        printf '  %-28s port %-6s %s\n' "$(svc_label "$s")" "$(svc_port "$s")" "$state"
    done
    if have_systemd_user; then
        if systemctl --user is-active --quiet railway-dsc-heal.timer; then printf '  %-28s %s\n' "Watchdog" "${G}active${N} (every 3 minutes)"
        else printf '  %-28s %s\n' "Watchdog" "${R}not active${N}"; rc=1; fi
    else
        local p; p=$(cat "$STATE_DIR/supervisor.pid" 2>/dev/null)
        if [ -n "$p" ] && kill -0 "$p" 2>/dev/null; then printf '  %-28s %s\n' "Supervisor" "${G}active${N}"
        else printf '  %-28s %s\n' "Supervisor" "${R}not running${N}"; rc=1; fi
    fi
    local p11; [ -f "$CONF_FILE" ] && . "$CONF_FILE"; p11=$(find_p11_lib || true)
    printf '  %-28s %s\n' "Token driver" "${p11:-${Y}none found${N}}"
    if token_present; then printf '  %-28s %s\n' "mToken USB token" "${G}plugged in${N}"
    else printf '  %-28s %s\n' "mToken USB token" "${Y}not detected${N} (plug it in before signing)"; fi
    hook_active && { printf '  %-28s %s\n' "Vendor autostart hook" "${R}active - it will kill the signer; run: railway-dsc install${N}"; rc=1; }
    grep -qs "$HOSTS_NAME" /etc/hosts || { printf '  %-28s %s\n' "/etc/hosts entry" "${R}missing; run: railway-dsc install${N}"; rc=1; }
    if [ -f "$HEAL_LOG" ]; then
        echo "  Last watchdog actions:"; grep -E 'RESTARTED|REPAIRED|REMOVED|ERROR|NEEDS ADMIN' "$HEAL_LOG" | tail -n 4 | sed 's/^/    /'
    fi
    return $rc
}

cmd_ctl() {                   # start|stop|restart
    local s
    case "$1" in
        stop)    touch "$STATE_DIR/stopped" 2>/dev/null
                 have_systemd_user && systemctl --user stop railway-dsc-heal.timer 2>/dev/null
                 for s in proxy cris ireps eoffice; do svc_stop "$s"; done; ok "All signer services stopped (watchdog paused). Start again with: railway-dsc start";;
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
    echo "${B}--- eOffice signer errors${N}"; tail -n 15 "$EOFFICE_LOGS/errorOutput.log" 2>/dev/null | cut -c1-200
    if have_systemd_user && have journalctl; then
        local s; for s in proxy cris ireps; do echo "${B}--- $(svc_label "$s")${N}"; journalctl --user -u "$(svc_unit "$s").service" --no-pager -n 12 2>/dev/null | cut -c1-200; done
    else
        local s; for s in proxy cris ireps; do echo "${B}--- $(svc_label "$s")${N}"; tail -n 12 "$SHARE_DIR/$s.log" 2>/dev/null | cut -c1-200; done
    fi
}

cmd_uninstall() {
    local purge=0 s; [ "${1:-}" = "--purge" ] && purge=1
    if have_systemd_user; then
        systemctl --user disable --now railway-dsc-heal.timer eofficesigner-proxy.service crissigner.service irepssigner.service eofficesigner.service >/dev/null 2>&1
        for s in $SVCS; do rm -f "$UNIT_DIR/$(svc_unit "$s").service"; done
        rm -f "$UNIT_DIR/railway-dsc-heal.service" "$UNIT_DIR/railway-dsc-heal.timer"
        systemctl --user daemon-reload
    else
        local p; p=$(cat "$STATE_DIR/supervisor.pid" 2>/dev/null); [ -n "$p" ] && kill "$p" 2>/dev/null
        for s in $SVCS; do svc_stop "$s"; done
    fi
    rm -f "$AUTOSTART" "$BIN"; rm -rf "$SHARE_DIR"
    ok "Services, watchdog and launchers removed."
    if [ $purge = 1 ]; then
        rm -rf "$CRIS_DIR" "$IREPS_DIR" "$PROXY_DIR" "$CONF_DIR"
        rm -rf "$EOFFICE_DIR"/* 2>/dev/null
        ok "Program files removed. Left in place (need root): $EOFFICE_DIR, $MTOKEN_LIB, $UDEV_RULE, the /etc/hosts line."
    else
        info "Program files were kept. Remove them too with: uninstall --purge"
    fi
}

usage() {
    cat <<EOF
Railway DSC Signer Suite $SUITE_VERSION

  pack [FILE]        build the portable installer (.run) from this working machine
  install            install or repair everything; safe to run again at any time
                       --ui-scale=N   window scale (1 normal, 2 HiDPI)
                       --no-root      skip the steps that need sudo
  status             health of all services, token and watchdog
  heal [--dry-run]   run the watchdog once now
  start|stop|restart control all signer services
  logs               recent watchdog actions and service logs
  trust              re-add the local signer certificates to browser stores
  uninstall [--purge]
EOF
}

main() {
    local cmd="${1:-help}"; [ $# -gt 0 ] && shift
    case "$cmd" in
        install)   cmd_install "$@";;
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
