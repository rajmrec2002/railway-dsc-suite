"""Sign a PDF with the DSC USB token (PAdES, visible signature box by default).

    sign-pdf letter.pdf                         -> letter_signed.pdf, box at bottom-right of the last page
    sign-pdf letter.pdf -o out.pdf --reason "Approved" --location "Ratlam"
    sign-pdf letter.pdf --page 1 --pos bl       first page, bottom-left
    sign-pdf letter.pdf --invisible             no box (the signature is still in the file)

The token PIN is asked for every time (terminal, or a password box when started from the file manager) and is
never stored. The token's driver is chosen by the token plugged in (same table as railway-dsc).
"""
import argparse
import getpass
import os
import shutil
import subprocess
import sys
import tempfile

from pyhanko.pdf_utils.incremental_writer import IncrementalPdfFileWriter
from pyhanko.sign import fields, signers
from pyhanko.sign.pkcs11 import PKCS11Signer, open_pkcs11_session
from pyhanko.stamp import TextStampStyle

OPENSC = ["/usr/lib/x86_64-linux-gnu/opensc-pkcs11.so", "/usr/lib/x86_64-linux-gnu/pkcs11/opensc-pkcs11.so"]
DRIVERS = {  # USB vendor id -> PKCS#11 drivers, best first (mirrors railway-dsc's p11_for_vid)
    "055c": ["/usr/lib/libcryptoid_pkcs11.so", "/usr/lib/libmTokenPKCS11.so"],
    "096e": ["/usr/lib/libcastle.so.1.0.0", "/usr/lib/railway-dsc/feitian/libcastle_v2.so.1.0.0", "/usr/lib/libcastle.so",
             "/usr/lib/x86_64-linux-gnu/libcastle.so"] + OPENSC,
    "2ccf": ["/usr/lib/railway-dsc/hypersecu/libcastle_v2.so.1.0.0", "/usr/lib/libcastle_v2.so.1.0.0"],
    "338c": ["/usr/lib/railway-dsc/innait/libInnaITPKCS11Driver.so",
             "/opt/Precision_Biometric/InnaITDSC/libraries/libInnaITPKCS11Driver.so"],
    "163c": ["/usr/lib/WatchData/ProxKey/lib/libwdpkcs_SignatureP11.so", "/usr/lib/WatchData/TRUSTKEY/lib/libwdpkcs_TRUSTKEY.so",
             "/usr/lib/WatchData/eMudhra_3.4.3/lib/libwdpkcs_eMudhra_343.so", "/usr/lib/WatchData/PROXKey/lib/libwdpkcs.so",
             "/usr/lib/libwdpkcs.so"],
    "0529": ["/usr/lib/libeTPkcs11.so", "/usr/lib/libeToken.so"],
    "08e6": ["/usr/lib/pkcs11/libgtop11dotnet.so", "/usr/lib/libgtop11dotnet.so"] + OPENSC,
    "24dc": ["/usr/lib/libjcPKCS11-2.so", "/usr/lib/x86_64-linux-gnu/libjcPKCS11-2.so"],
    "04e6": OPENSC, "072f": OPENSC,
}
GUI = not sys.stdin.isatty()


def say(msg, error=False):
    print(msg, file=sys.stderr if error else sys.stdout, flush=True)


def fail(msg):
    say("sign-pdf: " + msg, error=True)
    if GUI and shutil.which("zenity"):
        subprocess.run(["zenity", "--error", "--title=Sign PDF", "--no-wrap", "--text=" + msg])
    sys.exit(1)


def plugged_vids():
    out = []
    for d in os.listdir("/sys/bus/usb/devices"):
        try:
            with open(f"/sys/bus/usb/devices/{d}/idVendor") as f:
                out.append(f.read().strip().lower())
        except OSError:
            pass
    return out


def find_driver(override):
    if override:
        return override if os.path.isfile(override) else fail("no such PKCS#11 driver: " + override)
    known = False
    for v in plugged_vids():
        if v in DRIVERS:
            known = True
            for lib in DRIVERS[v]:
                if os.path.isfile(lib):
                    return lib
    if known:
        fail("the plugged token's driver is not installed (run: railway-dsc doctor)")
    fail("no DSC token found - plug in the USB token and try again")


def ask_pin():
    if GUI and shutil.which("zenity"):
        r = subprocess.run(["zenity", "--password", "--title=DSC token PIN"], capture_output=True, text=True)
        if r.returncode != 0:
            sys.exit(1)
        return r.stdout.rstrip("\n")
    return getpass.getpass("Token PIN: ")


def current_umask():
    m = os.umask(0)
    os.umask(m)
    return m


def is_ca(cert):
    bc = cert.basic_constraints_value
    return bool(bc and bc["ca"].native)


def media_box(w, page_ix):
    """The page's size, a MediaBox inherited from its parents included (A4 when none can be read)."""
    try:
        node = w.find_page_for_modification(page_ix)[0].get_object()
        while node is not None:
            if "/MediaBox" in node:
                return [float(x) for x in node["/MediaBox"]]
            parent = node.get("/Parent")
            node = parent.get_object() if parent is not None else None
    except Exception:
        pass
    return [0.0, 0.0, 595.0, 842.0]


def sign_file(a, src, out, signer):
    with open(src, "rb") as f:
        w = IncrementalPdfFileWriter(f, strict=False)
        n_pages = int(w.root["/Pages"]["/Count"])
        used = set()
        try:
            for x in w.root["/AcroForm"]["/Fields"]:
                used.add(str(x.get_object().get("/T")))
        except Exception:
            pass
        field = next(f"Signature{i}" for i in range(1, 999) if f"Signature{i}" not in used)

        style = None
        if a.invisible:
            spec = fields.SigFieldSpec(field)
        else:
            page_ix = (a.page - 1) if a.page else n_pages - 1
            if not 0 <= page_ix < n_pages:
                fail(f"page {a.page} is not in the document (it has {n_pages})")
            llx, lly, urx, ury = media_box(w, page_ix)
            box_w, box_h, m = 210, 64, 30
            x = (urx - box_w - m) if a.pos in ("br", "tr") else (llx + m)
            y = (lly + m) if a.pos in ("br", "bl") else (ury - box_h - m)
            spec = fields.SigFieldSpec(field, on_page=page_ix, box=(int(x), int(y), int(x + box_w), int(y + box_h)))
            lines = "Digitally signed by %(signer)s\nDate: %(ts)s"
            if a.reason:
                lines += "\nReason: " + a.reason.replace("%", "%%")
            if a.location:
                lines += "\nLocation: " + a.location.replace("%", "%%")
            style = TextStampStyle(stamp_text=lines, timestamp_format="%d-%m-%Y %H:%M:%S %z", border_width=1)

        meta = signers.PdfSignatureMetadata(field_name=field, reason=a.reason, location=a.location,
                                            md_algorithm="sha256", subfilter=fields.SigSeedSubFilter.PADES)
        # a new, unpredictable temp file beside the output (O_EXCL: never follows a planted link), then renamed
        fd, tmp = tempfile.mkstemp(prefix=".sign-pdf-", suffix=".part", dir=os.path.dirname(out) or ".")
        try:
            with os.fdopen(fd, "wb") as o:
                signers.PdfSigner(meta, signer, stamp_style=style, new_field_spec=spec).sign_pdf(w, output=o)
            os.chmod(tmp, 0o644 & ~current_umask())
        except BaseException:
            if os.path.exists(tmp):
                os.remove(tmp)
            raise
    os.replace(tmp, out)


def report(out):
    say(f"signed  : {out}")
    if shutil.which("pdfsig"):
        r = subprocess.run(["pdfsig", out], capture_output=True, text=True)
        ok = "Signature Validation: Signature is Valid" in r.stdout
        say("check   : " + ("the signature is valid" if ok else "pdfsig could not confirm it:\n" + r.stdout.strip()))
    if GUI and shutil.which("notify-send"):
        subprocess.run(["notify-send", "PDF signed", os.path.basename(out)])
    if GUI and os.environ.get("SIGN_PDF_OPEN", "1") == "1" and shutil.which("papers"):   # show the result
        subprocess.Popen(["papers", out], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)


def main():
    ap = argparse.ArgumentParser(prog="sign-pdf", description="Sign a PDF with the DSC USB token.")
    ap.add_argument("pdf", nargs="?", help="the PDF (asked for in a file chooser when started from the app menu)")
    ap.add_argument("-o", "--output", help="output file (default: <name>_signed.pdf)")
    ap.add_argument("--reason", default=None)
    ap.add_argument("--location", default=None)
    ap.add_argument("--page", type=int, default=0, help="page for the box, 1 = first (default: last page)")
    ap.add_argument("--pos", choices=["br", "bl", "tr", "tl"], default="br", help="corner for the box (default br)")
    ap.add_argument("--invisible", action="store_true", help="no visible box")
    ap.add_argument("--lib", help="PKCS#11 driver to use instead of the automatic choice")
    a = ap.parse_args()
    if not a.pdf:
        if not (GUI and shutil.which("zenity")):
            ap.error("give the PDF to sign")
        r = subprocess.run(["zenity", "--file-selection", "--title=Choose the PDF to sign", "--file-filter=PDF | *.pdf *.PDF"],
                           capture_output=True, text=True)
        if r.returncode != 0 or not r.stdout.strip():
            sys.exit(0)
        a.pdf = r.stdout.strip()

    src = os.path.abspath(a.pdf)
    if not os.path.isfile(src):
        fail("no such file: " + a.pdf)
    root, _ = os.path.splitext(src)
    out = os.path.abspath(a.output) if a.output else root + "_signed.pdf"
    if out == src:
        fail("the output must be a new file, not the original")

    test_p12 = os.environ.get("SIGN_PDF_TEST_P12")   # self-test only: a throwaway key file instead of the token
    if test_p12:
        sign_file(a, src, out, signers.SimpleSigner.load_pkcs12(test_p12, passphrase=None))
        return report(out)

    lib = find_driver(a.lib)
    pin = ask_pin()
    if not pin:
        fail("no PIN given")
    try:
        session = open_pkcs11_session(lib, user_pin=pin)
    except Exception as e:  # wrong PIN, locked token, token busy
        fail("could not open the token: " + (str(e) or e.__class__.__name__) +
             "\n(a wrong PIN counts towards locking the token - check it before trying again)")
    finally:
        pin = None

    try:
        import pkcs11
        from asn1crypto import x509
        key_ids = {k[pkcs11.Attribute.ID] for k in session.get_objects({pkcs11.Attribute.CLASS: pkcs11.ObjectClass.PRIVATE_KEY})}
        mine = []
        for c in session.get_objects({pkcs11.Attribute.CLASS: pkcs11.ObjectClass.CERTIFICATE}):
            cert = x509.Certificate.load(c[pkcs11.Attribute.VALUE])
            cid = c[pkcs11.Attribute.ID]          # Certificate objects have no .id property (only keys do)
            if cid in key_ids and not is_ca(cert):
                mine.append((cid, cert))
        if not mine:
            fail("no signing certificate with a private key on this token")
        mine.sort(key=lambda t: t[1].not_valid_after, reverse=True)      # several: the one valid longest
        cid, cert = mine[0]
        name = cert.subject.native.get("common_name", "DSC holder")
        say(f"signer  : {name}  (valid until {cert.not_valid_after:%d-%m-%Y})")
        signer = PKCS11Signer(session, cert_id=cid, key_id=cid, other_certs_to_pull=None)
        sign_file(a, src, out, signer)
    finally:
        session.close()
    report(out)


if __name__ == "__main__":
    main()
