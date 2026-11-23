"""Sign a PDF with the DSC USB token (PAdES, visible signature box by default).

    sign-pdf letter.pdf                         -> letter_signed.pdf, box at bottom-right of the last page
    sign-pdf letter.pdf -o out.pdf --reason "Approved" --location "Ratlam"
    sign-pdf letter.pdf --page 1 --pos bl       first page, bottom-left
    sign-pdf letter.pdf --pages all             a signature box on every page (PIN asked once)
    sign-pdf letter.pdf --pages 1,3,5-7         those pages only
    sign-pdf letter.pdf --draw                  a window shows the page: draw the box, choose the pages
    sign-pdf letter.pdf --box 0.6,0.85,0.95,0.95   box as fractions of the page (left,top,right,bottom)
    sign-pdf letter.pdf --invisible             no box (the signature is still in the file)

Started from the file manager or the app menu, the draw window opens by itself (--no-draw skips it).
Every page chosen gets its own signature, all made in one token session, so the PIN is asked once.
The token PIN is asked for every time (terminal, or a password box when started from the file manager) and is
never stored. The token's driver is chosen by the token plugged in (same table as railway-dsc).
"""
import argparse
import getpass
import io
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

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
BOX_W, BOX_H, MARGIN = 210, 64, 30          # the default box, in points (bottom-right of an A4 page)


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


# ---- pages and boxes -------------------------------------------------------------------------------------------

def parse_pages(spec, n):
    """'all', 'first', 'last', or '1,3,5-7' -> sorted 0-based page indexes; raises ValueError when invalid."""
    spec = (spec or "last").strip().lower().replace(" ", "")
    if spec == "all":
        return list(range(n))
    out = set()
    for part in spec.split(","):
        if part in ("first", "last"):
            out.add(0 if part == "first" else n - 1)
            continue
        m = re.fullmatch(r"(\d+)(?:-(\d+|last))?", part)
        if not m:
            raise ValueError(f"'{part}' is not a page number or range")
        lo = int(m.group(1))
        hi = lo if m.group(2) is None else (n if m.group(2) == "last" else int(m.group(2)))
        if lo > hi:
            lo, hi = hi, lo
        if lo < 1 or hi > n:
            raise ValueError(f"page {lo if lo < 1 else hi} is not in the document (it has {n})")
        out.update(range(lo - 1, hi))
    if not out:
        raise ValueError("no pages chosen")
    return sorted(out)


def parse_box(text):
    try:
        v = [float(x) for x in text.split(",")]
    except ValueError:
        v = []
    if len(v) != 4 or not all(0 <= x <= 1 for x in v) or v[0] == v[2] or v[1] == v[3]:
        raise ValueError("--box needs four fractions 0..1: left,top,right,bottom")
    return [min(v[0], v[2]), min(v[1], v[3]), max(v[0], v[2]), max(v[1], v[3])]


def page_geometry(w, page_ix):
    """The page's visible area (CropBox, else MediaBox, inherited ones included) and its /Rotate."""
    box, rot = None, None
    try:
        node = w.find_page_for_modification(page_ix)[0].get_object()
        while node is not None:
            for key in ("/CropBox", "/MediaBox"):
                if box is None and key in node:
                    box = [float(x) for x in node[key]]
            if rot is None and "/Rotate" in node:
                rot = int(node["/Rotate"]) % 360
            parent = node.get("/Parent")
            node = parent.get_object() if parent is not None else None
    except Exception:
        pass
    box = box or [0.0, 0.0, 595.0, 842.0]
    return [min(box[0], box[2]), min(box[1], box[3]), max(box[0], box[2]), max(box[1], box[3])], (rot or 0)


def frac_to_rect(frac, geom):
    """A box drawn on the page as it is shown (fractions, top-left origin) -> PDF user-space rectangle."""
    (llx, lly, urx, ury), rot = geom
    W, H = urx - llx, ury - lly

    def pt(fx, fy):
        if rot == 90:
            return llx + fy * W, lly + fx * H
        if rot == 180:
            return urx - fx * W, lly + fy * H
        if rot == 270:
            return urx - fy * W, ury - fx * H
        return llx + fx * W, ury - fy * H

    (x0, y0), (x1, y1) = pt(frac[0], frac[1]), pt(frac[2], frac[3])
    return (int(min(x0, x1)), int(min(y0, y1)), int(round(max(x0, x1))), int(round(max(y0, y1))))


def corner_frac(pos, geom):
    """The fixed-size default box in a corner of the page as it is shown, as fractions."""
    (llx, lly, urx, ury), rot = geom
    W, H = urx - llx, ury - lly
    if rot in (90, 270):
        W, H = H, W
    bw, bh, mx, my = BOX_W / W, BOX_H / H, MARGIN / W, MARGIN / H
    x0 = 1 - mx - bw if pos in ("br", "tr") else mx
    y0 = 1 - my - bh if pos in ("br", "bl") else my
    return [x0, y0, x0 + bw, y0 + bh]


# ---- signing ---------------------------------------------------------------------------------------------------

def stamp_style(a):
    from pyhanko.stamp import TextStampStyle
    lines = "Digitally signed by %(signer)s\nDate: %(ts)s"
    if a.reason:
        lines += "\nReason: " + a.reason.replace("%", "%%")
    if a.location:
        lines += "\nLocation: " + a.location.replace("%", "%%")
    return TextStampStyle(stamp_text=lines, timestamp_format="%d-%m-%Y %H:%M:%S %z", border_width=1)


def sign_once(a, data, page_ix, signer):
    """Add one signature (a box on page_ix, or invisible when page_ix is None) to the PDF bytes; return new bytes."""
    from pyhanko.pdf_utils.incremental_writer import IncrementalPdfFileWriter
    from pyhanko.sign import fields, signers
    w = IncrementalPdfFileWriter(io.BytesIO(data), strict=False)
    used = set()
    try:
        for x in w.root["/AcroForm"]["/Fields"]:
            used.add(str(x.get_object().get("/T")))
    except Exception:
        pass
    field = next(f"Signature{i}" for i in range(1, 9999) if f"Signature{i}" not in used)
    style = None
    if page_ix is None:
        spec = fields.SigFieldSpec(field)
    else:
        geom = page_geometry(w, page_ix)
        frac = a.box if a.box else corner_frac(a.pos, geom)
        spec = fields.SigFieldSpec(field, on_page=page_ix, box=frac_to_rect(frac, geom))
        style = stamp_style(a)
    meta = signers.PdfSignatureMetadata(field_name=field, reason=a.reason, location=a.location,
                                        md_algorithm="sha256", subfilter=fields.SigSeedSubFilter.PADES)
    out = io.BytesIO()
    signers.PdfSigner(meta, signer, stamp_style=style, new_field_spec=spec).sign_pdf(w, output=out)
    return out.getvalue()


def sign_file(a, src, out, signer, pages):
    with open(src, "rb") as f:
        data = f.read()
    targets = [None] if a.invisible else pages
    for k, ix in enumerate(targets, 1):
        if len(targets) > 1:
            say(f"signing : page {ix + 1}  ({k} of {len(targets)})")
        data = sign_once(a, data, ix, signer)
    # a new, unpredictable temp file beside the output (O_EXCL: never follows a planted link), then renamed
    fd, tmp = tempfile.mkstemp(prefix=".sign-pdf-", suffix=".part", dir=os.path.dirname(out) or ".")
    try:
        with os.fdopen(fd, "wb") as o:
            o.write(data)
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
        total = len(re.findall(r"^Signature #\d+", r.stdout, re.M))
        good = r.stdout.count("Signature Validation: Signature is Valid")
        ok = total > 0 and good == total
        say("check   : " + (f"{'the signature is' if total == 1 else f'all {total} signatures are'} valid" if ok
                            else "pdfsig could not confirm it:\n" + r.stdout.strip()))
    if GUI and shutil.which("notify-send"):
        subprocess.run(["notify-send", "PDF signed", os.path.basename(out)])
    if GUI and os.environ.get("SIGN_PDF_OPEN", "1") == "1" and shutil.which("papers"):   # show the result
        subprocess.Popen(["papers", out], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)


def count_pages(src):
    from pyhanko.pdf_utils.reader import PdfFileReader
    with open(src, "rb") as f:
        return int(PdfFileReader(f, strict=False).root["/Pages"]["/Count"])


# ---- the draw window (runs under the system Python, which has GTK; the venv does not) ---------------------------

def run_picker(src, n_pages, a):
    """Show the draw window; returns (box fractions, pages spec, reason, location), or exits when cancelled."""
    py = "/usr/bin/python3"
    if not (os.path.exists(py) and shutil.which("pdftoppm")):
        fail("the draw window needs the system Python with GTK 4 and poppler-utils (pdftoppm)")
    start = (a.page if a.page else n_pages)
    r = subprocess.run([py, "-I", os.path.abspath(__file__), "--pick-ui=" + src, f"--pick-pages={n_pages}",
                        f"--pick-start={start}", "--pick-spec=" + (a.pages or ""),
                        "--pick-box=" + (",".join(map(str, a.box)) if a.box else ""),
                        "--reason=" + (a.reason or ""), "--location=" + (a.location or "")],
                       stdout=subprocess.PIPE, text=True)
    if r.returncode == 2:
        sys.exit(0)                                   # cancelled
    try:
        res = json.loads(r.stdout)
    except ValueError:
        fail("the draw window did not open (GTK 4 for Python missing? Ubuntu: sudo apt install gir1.2-gtk-4.0)")
    return res["box"], res["pages"], res.get("reason") or None, res.get("location") or None


def picker_main(argv):
    import gi
    gi.require_version("Gtk", "4.0")
    gi.require_version("Gdk", "4.0")
    from gi.repository import Gdk, Gtk

    ap = argparse.ArgumentParser()
    ap.add_argument("--pick-ui")
    ap.add_argument("--pick-pages", type=int)
    ap.add_argument("--pick-start", type=int)
    ap.add_argument("--pick-spec", default="")
    ap.add_argument("--pick-box", default="")
    ap.add_argument("--reason", default="")
    ap.add_argument("--location", default="")
    o = ap.parse_args(argv)
    src, n = o.pick_ui, o.pick_pages
    tmpdir = tempfile.mkdtemp(prefix="sign-pdf-view-")
    st = {"page": max(1, min(o.pick_start, n)), "box": None, "drag": None, "result": None}
    st["box"] = parse_box(o.pick_box) if o.pick_box else None
    MAXPX = 780

    def render(p):
        base = os.path.join(tmpdir, f"p{p}")
        if not os.path.exists(base + ".png"):
            subprocess.run(["pdftoppm", "-png", "-scale-to", str(MAXPX), "-f", str(p), "-l", str(p), "-singlefile",
                            src, base], check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        try:
            return Gdk.Texture.new_from_filename(base + ".png")
        except Exception:
            return None

    def default_box(surf):
        W, H = surf.get_width(), surf.get_height()     # the box is kept as fractions; size it as on A4
        pw, ph = (595.0, 842.0) if H >= W else (842.0, 595.0)
        bw, bh, mx, my = BOX_W / pw, BOX_H / ph, MARGIN / pw, MARGIN / ph
        return [1 - mx - bw, 1 - my - bh, 1 - mx, 1 - my]

    app = Gtk.Application(application_id=None)

    def on_activate(app):
        win = Gtk.ApplicationWindow(application=app, title="Sign PDF - draw the signature box")
        outer = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8, margin_top=10, margin_bottom=10,
                        margin_start=10, margin_end=10)
        win.set_child(outer)
        hint = Gtk.Label(label="Drag on the page to draw the signature box. Drag inside the box to move it.", xalign=0)
        outer.append(hint)

        css = Gtk.CssProvider()
        css.load_from_string(".sigbox { border: 2px solid #1a66e6; background: rgba(26,102,230,0.18); }"
                             " .sigbox label { color: #1a66e6; font-size: 11px; }")
        Gtk.StyleContext.add_provider_for_display(win.get_display(), css, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)
        area = Gtk.Fixed(halign=Gtk.Align.CENTER, valign=Gtk.Align.CENTER)
        pic = Gtk.Picture(can_shrink=False)
        area.put(pic, 0, 0)
        boxw = Gtk.Box()
        boxw.add_css_class("sigbox")
        boxw.append(Gtk.Label(label="Signature", xalign=0, valign=Gtk.Align.START, margin_start=4,
                              ellipsize=3))      # Pango.EllipsizeMode.END
        area.put(boxw, 0, 0)
        frame = Gtk.Frame(child=area, halign=Gtk.Align.CENTER)
        outer.append(frame)
        size = {"w": 1, "h": 1}

        def place_box():
            b = st["box"]
            boxw.set_visible(bool(b))
            if b:
                w, h = size["w"], size["h"]
                area.move(boxw, b[0] * w, b[1] * h)
                boxw.set_size_request(max(4, int((b[2] - b[0]) * w)), max(4, int((b[3] - b[1]) * h)))

        def show_page(p):
            st["page"] = p
            s = render(p)
            if s:
                size["w"], size["h"] = s.get_width(), s.get_height()
                pic.set_paintable(s)
                pic.set_size_request(size["w"], size["h"])
                if st["box"] is None:
                    st["box"] = default_box(s)
            page_lbl.set_label(f"Page {p} of {n}")
            this_rb.set_label(f"This page ({p})")
            prev_b.set_sensitive(p > 1)
            next_b.set_sensitive(p < n)
            place_box()

        drag = Gtk.GestureDrag(propagation_phase=Gtk.PropagationPhase.CAPTURE)

        def clamp(v):
            return max(0.0, min(1.0, v))

        def d_begin(g, x, y):
            w, h = size["w"], size["h"]
            fx, fy = x / w, y / h
            b = st["box"]
            inside = b and b[0] <= fx <= b[2] and b[1] <= fy <= b[3]
            st["drag"] = ("move" if inside else "new", fx, fy, list(b) if b else None)

        def d_update(g, dx, dy):
            if not st["drag"]:
                return
            mode, fx, fy, b0 = st["drag"]
            w, h = size["w"], size["h"]
            ex, ey = clamp(fx + dx / w), clamp(fy + dy / h)
            if mode == "move":
                bw, bh = b0[2] - b0[0], b0[3] - b0[1]
                nx = max(0.0, min(1 - bw, b0[0] + dx / w))
                ny = max(0.0, min(1 - bh, b0[1] + dy / h))
                st["box"] = [nx, ny, nx + bw, ny + bh]
            elif abs(dx) > 6 and abs(dy) > 6:
                st["box"] = [min(fx, ex), min(fy, ey), max(fx, ex), max(fy, ey)]
            place_box()

        drag.connect("drag-begin", d_begin)
        drag.connect("drag-update", d_update)
        drag.connect("drag-end", lambda g, dx, dy: st.update(drag=None))
        area.add_controller(drag)

        nav = Gtk.Box(spacing=6, halign=Gtk.Align.CENTER)
        prev_b = Gtk.Button(label="< Previous")
        next_b = Gtk.Button(label="Next >")
        page_lbl = Gtk.Label()
        prev_b.connect("clicked", lambda b: show_page(st["page"] - 1))
        next_b.connect("clicked", lambda b: show_page(st["page"] + 1))
        for wdg in (prev_b, page_lbl, next_b):
            nav.append(wdg)
        outer.append(nav)

        grid = Gtk.Grid(column_spacing=10, row_spacing=6)
        outer.append(grid)
        grid.attach(Gtk.Label(label="Sign on:", xalign=0), 0, 0, 1, 1)
        rbox = Gtk.Box(spacing=12)
        this_rb = Gtk.CheckButton(label="This page")
        all_rb = Gtk.CheckButton(label=f"All pages ({n})", group=this_rb)
        last_rb = Gtk.CheckButton(label="Last page", group=this_rb)
        some_rb = Gtk.CheckButton(label="Pages:", group=this_rb)
        some_e = Gtk.Entry(placeholder_text="e.g. 1,3,5-7", width_chars=14)
        some_e.connect("changed", lambda e: some_rb.set_active(True) if e.get_text() else None)
        for wdg in (this_rb, all_rb, last_rb, some_rb, some_e):
            rbox.append(wdg)
        grid.attach(rbox, 1, 0, 1, 1)
        spec0 = o.pick_spec.strip().lower()
        if spec0 == "all":
            all_rb.set_active(True)
        elif spec0 == "last" or not spec0:
            (last_rb if o.pick_start == n and n > 1 else this_rb).set_active(True)
        else:
            some_rb.set_active(True)
            some_e.set_text(o.pick_spec)

        reason_e = Gtk.Entry(text=o.reason, hexpand=True, placeholder_text="optional")
        loc_e = Gtk.Entry(text=o.location, hexpand=True, placeholder_text="optional")
        grid.attach(Gtk.Label(label="Reason:", xalign=0), 0, 1, 1, 1)
        grid.attach(reason_e, 1, 1, 1, 1)
        grid.attach(Gtk.Label(label="Location:", xalign=0), 0, 2, 1, 1)
        grid.attach(loc_e, 1, 2, 1, 1)

        err = Gtk.Label(xalign=0)
        err.add_css_class("error")
        outer.append(err)

        btns = Gtk.Box(spacing=8, halign=Gtk.Align.END)
        cancel_b = Gtk.Button(label="Cancel")
        sign_b = Gtk.Button(label="Sign (asks for PIN)")
        sign_b.add_css_class("suggested-action")
        btns.append(cancel_b)
        btns.append(sign_b)
        outer.append(btns)

        def do_sign(_b):
            if all_rb.get_active():
                spec = "all"
            elif last_rb.get_active():
                spec = "last"
            elif some_rb.get_active():
                spec = some_e.get_text()
            else:
                spec = str(st["page"])
            try:
                parse_pages(spec, n)
            except ValueError as e:
                err.set_label(str(e))
                return
            b = st["box"]
            if not b or (b[2] - b[0]) < 0.02 or (b[3] - b[1]) < 0.01:
                err.set_label("draw a bigger signature box")
                return
            st["result"] = {"box": [round(x, 5) for x in b], "pages": spec,
                            "reason": reason_e.get_text().strip(), "location": loc_e.get_text().strip()}
            win.close()

        sign_b.connect("clicked", do_sign)
        cancel_b.connect("clicked", lambda b: win.close())
        keys = Gtk.EventControllerKey()
        keys.connect("key-pressed", lambda c, kv, kc, m: (win.close(), True)[1] if kv == 0xff1b else False)
        win.add_controller(keys)
        show_page(st["page"])
        win.set_default_widget(sign_b)
        win.present()

    app.connect("activate", on_activate)
    app.run([sys.argv[0]])
    shutil.rmtree(tmpdir, ignore_errors=True)
    if st["result"] is None:
        sys.exit(2)
    print(json.dumps(st["result"]))


# ---- main ------------------------------------------------------------------------------------------------------

def main():
    if any(x.startswith("--pick-ui") for x in sys.argv[1:2]):
        return picker_main(sys.argv[1:])
    ap = argparse.ArgumentParser(prog="sign-pdf", description="Sign a PDF with the DSC USB token.")
    ap.add_argument("pdf", nargs="?", help="the PDF (asked for in a file chooser when started from the app menu)")
    ap.add_argument("-o", "--output", help="output file (default: <name>_signed.pdf)")
    ap.add_argument("--reason", default=None)
    ap.add_argument("--location", default=None)
    ap.add_argument("--page", type=int, default=0, help="page for the box, 1 = first (default: last page)")
    ap.add_argument("--pages", default=None, help="pages to sign: all, first, last, or e.g. 1,3,5-7 (PIN asked once)")
    ap.add_argument("--pos", choices=["br", "bl", "tr", "tl"], default="br", help="corner for the box (default br)")
    ap.add_argument("--box", default=None, help="box as fractions of the page: left,top,right,bottom (0..1)")
    ap.add_argument("--draw", action="store_true", help="open a window to draw the box and choose the pages")
    ap.add_argument("--no-draw", action="store_true", help="never open the draw window")
    ap.add_argument("--invisible", action="store_true", help="no visible box")
    ap.add_argument("--lib", help="PKCS#11 driver to use instead of the automatic choice")
    a = ap.parse_args()
    if a.box:
        try:
            a.box = parse_box(a.box)
        except ValueError as e:
            ap.error(str(e))
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
    try:
        n_pages = count_pages(src)
    except Exception as e:
        fail("cannot read the PDF: " + (str(e) or e.__class__.__name__))

    # the box and the pages: drawn in the window (file manager / app menu, or --draw), else from the options
    if not a.invisible and not a.no_draw and (a.draw or (GUI and not a.box and not a.pages)):
        a.box, a.pages, reason, location = run_picker(src, n_pages, a)
        a.reason, a.location = reason or a.reason, location or a.location
    spec = a.pages or (str(a.page) if a.page else "last")
    try:
        pages = parse_pages(spec, n_pages)
    except ValueError as e:
        fail(str(e))

    from pyhanko.sign import signers
    test_p12 = os.environ.get("SIGN_PDF_TEST_P12")   # self-test only: a throwaway key file instead of the token
    if test_p12:
        sign_file(a, src, out, signers.SimpleSigner.load_pkcs12(test_p12, passphrase=None), pages)
        return report(out)

    from pyhanko.sign.pkcs11 import PKCS11Signer, open_pkcs11_session
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
        sign_file(a, src, out, signer, pages)
    finally:
        session.close()
    report(out)


if __name__ == "__main__":
    main()
