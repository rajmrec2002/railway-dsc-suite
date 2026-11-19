package railwaydsc;

import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.lang.instrument.Instrumentation;
import java.net.HttpURLConnection;
import java.net.URL;
import java.security.Key;
import java.security.KeyStore;
import java.security.KeyStoreException;
import java.security.KeyStoreSpi;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.security.Provider;
import java.security.Security;
import java.security.UnrecoverableKeyException;
import java.security.cert.Certificate;
import java.security.cert.CertificateException;
import java.security.cert.CertificateFactory;
import java.security.cert.X509Certificate;
import java.util.ArrayList;
import java.util.Collection;
import java.util.Date;
import java.util.Enumeration;
import java.util.HashSet;
import java.util.List;
import java.util.Set;

/**
 * Completes the certificate chain of a DSC whose token holds only the signer's own
 * certificate (or the certificate and its Sub-CA).
 *
 * Why: on Linux the NIC signer reads the chain only from the token, through SunPKCS11,
 * and silently drops any certificate whose chain has two certificates or fewer; the
 * server then answers DSCSN05. On Windows the same chain comes from the certificate store.
 * This agent gives the PKCS11 key store the CA certificates the Windows store would have:
 * the CCA India roots shipped with the suite, CA certificates in the suite's folder, and
 * the issuer certificates named in each certificate's own "CA Issuers" address.
 *
 * Nothing is switched off: a CA certificate is added only when its signature over the
 * certificate below it verifies, and only if the chain ends at a pinned CCA India root.
 * A chain the token already completes is returned untouched. The token is only read.
 * The server still checks the chain, validity and revocation as before.
 *
 * Usage: java -javaagent:chain-fill.jar=/path/to/ca-folder[:/another] -jar app.jar
 */
public final class ChainFillAgent {
    /** SHA-256 of the CCA India roots a completed chain must end at. */
    static final String[] PINNED_ROOTS = {
        "9a3fd3176798e842ddcb12c262f11cfacca70a8b84c6ea6fda30842a95a94cd8", // CCA India 2022
        "b724689b79b2ef9421ef8f5cc733eb093851b170ee715177005a09f226d8c91a", // CCA India 2022 SPL
        "c34c5df53080078ffe45b21a7f600469917204f4f0293f1d7209393e5265c04f", // CCA India 2015 SPL
        "60109bc6c38328598a112c7a25e38b0f23e5a7511cb815fb64e0c4ff05db7df7", // CCA India 2014
    };

    static final List<File> DIRS = new ArrayList<File>();
    static File cacheDir;

    private ChainFillAgent() {}

    public static void premain(String args, Instrumentation inst) { install(args); }
    public static void agentmain(String args, Instrumentation inst) { install(args); }

    static void install(String args) {
        try {
            if (args != null) {
                for (String p : args.split(":")) {
                    if (p.length() > 0) DIRS.add(new File(p));
                }
            }
            if (!DIRS.isEmpty()) cacheDir = new File(DIRS.get(0), "fetched");
            Security.insertProviderAt(new FillProvider(), 1);
            log("ready (" + DIRS + ")");
        } catch (Throwable t) {
            log("not installed: " + t);
        }
    }

    static void log(String s) { System.err.println("[railway-dsc chain-fill] " + s); }

    /** Offers the "PKCS11" key store type ahead of SunPKCS11 and wraps the real one. */
    static final class FillProvider extends Provider {
        private static final long serialVersionUID = 1L;
        FillProvider() {
            super("RailwayDscChainFill", 1.0, "Completes DSC chains from CA certificates");
            put("KeyStore.PKCS11", FillKeyStore.class.getName());
        }
    }

    public static final class FillKeyStore extends KeyStoreSpi {
        private KeyStore real;

        private KeyStore real() throws KeyStoreException {
            if (real != null) return real;
            Provider p11 = null;
            for (Provider p : Security.getProviders()) {          // the configured SunPKCS11
                if (p instanceof FillProvider) continue;            // the last one added wins
                if (p.getService("KeyStore", "PKCS11") != null) p11 = p;
            }
            if (p11 == null) throw new KeyStoreException("PKCS11 not found");
            real = KeyStore.getInstance("PKCS11", p11);
            return real;
        }

        @Override public void engineLoad(InputStream in, char[] pw)
                throws IOException, NoSuchAlgorithmException, CertificateException {
            try { real = null; real().load(in, pw); }
            catch (KeyStoreException e) { throw new IOException(e.getMessage(), e); }
        }
        @Override public void engineLoad(KeyStore.LoadStoreParameter param)
                throws IOException, NoSuchAlgorithmException, CertificateException {
            try { real = null; real().load(param); }
            catch (KeyStoreException e) { throw new IOException(e.getMessage(), e); }
        }

        @Override public Certificate[] engineGetCertificateChain(String alias) {
            Certificate[] ch;
            try { ch = real().getCertificateChain(alias); }
            catch (KeyStoreException e) { return null; }
            if (ch == null || ch.length > 2 || !(ch[0] instanceof X509Certificate)) return ch;
            try {
                List<X509Certificate> pool = new ArrayList<X509Certificate>();
                try {                                                // CA certificates on the token
                    for (Enumeration<String> en = real().aliases(); en.hasMoreElements();) {
                        Certificate c = real().getCertificate(en.nextElement());
                        if (c instanceof X509Certificate) pool.add((X509Certificate) c);
                    }
                } catch (KeyStoreException ignored) { }
                X509Certificate[] done = complete(ch, pool);
                if (done != null) {
                    log("completed the chain of \"" + alias + "\": " + ch.length + " -> " + done.length
                        + " certificates, ending at " + done[done.length - 1].getSubjectX500Principal().getName());
                    return done;
                }
                log("could not complete the chain of \"" + alias + "\" (issuer: "
                    + ((X509Certificate) ch[ch.length - 1]).getIssuerX500Principal().getName()
                    + "); add its CA certificates to " + (DIRS.isEmpty() ? "the CA folder" : DIRS.get(0).getPath()));
            } catch (Throwable t) {
                log("chain completion failed: " + t);
            }
            return ch;
        }

        @Override public Key engineGetKey(String a, char[] pw) throws NoSuchAlgorithmException, UnrecoverableKeyException {
            try { return real().getKey(a, pw); } catch (KeyStoreException e) { return null; }
        }
        @Override public Certificate engineGetCertificate(String a) {
            try { return real().getCertificate(a); } catch (KeyStoreException e) { return null; }
        }
        @Override public Date engineGetCreationDate(String a) {
            try { return real().getCreationDate(a); } catch (KeyStoreException e) { return null; }
        }
        @Override public void engineSetKeyEntry(String a, Key k, char[] pw, Certificate[] ch) throws KeyStoreException {
            real().setKeyEntry(a, k, pw, ch);
        }
        @Override public void engineSetKeyEntry(String a, byte[] k, Certificate[] ch) throws KeyStoreException {
            real().setKeyEntry(a, k, ch);
        }
        @Override public void engineSetCertificateEntry(String a, Certificate c) throws KeyStoreException {
            real().setCertificateEntry(a, c);
        }
        @Override public void engineDeleteEntry(String a) throws KeyStoreException { real().deleteEntry(a); }
        @Override public Enumeration<String> engineAliases() {
            try { return real().aliases(); } catch (KeyStoreException e) { return java.util.Collections.enumeration(new ArrayList<String>()); }
        }
        @Override public boolean engineContainsAlias(String a) {
            try { return real().containsAlias(a); } catch (KeyStoreException e) { return false; }
        }
        @Override public int engineSize() {
            try { return real().size(); } catch (KeyStoreException e) { return 0; }
        }
        @Override public boolean engineIsKeyEntry(String a) {
            try { return real().isKeyEntry(a); } catch (KeyStoreException e) { return false; }
        }
        @Override public boolean engineIsCertificateEntry(String a) {
            try { return real().isCertificateEntry(a); } catch (KeyStoreException e) { return false; }
        }
        @Override public String engineGetCertificateAlias(Certificate c) {
            try { return real().getCertificateAlias(c); } catch (KeyStoreException e) { return null; }
        }
        @Override public void engineStore(OutputStream out, char[] pw)
                throws IOException, NoSuchAlgorithmException, CertificateException {
            try { real().store(out, pw); } catch (KeyStoreException e) { throw new IOException(e.getMessage(), e); }
        }
    }

    // ---- chain building ------------------------------------------------------------------

    /** Returns the completed chain, or null when it cannot reach a pinned root. */
    static X509Certificate[] complete(Certificate[] start, List<X509Certificate> tokenCerts) throws Exception {
        List<X509Certificate> chain = new ArrayList<X509Certificate>();
        for (Certificate c : start) chain.add((X509Certificate) c);
        List<X509Certificate> pool = new ArrayList<X509Certificate>(tokenCerts);
        pool.addAll(loadDirs());
        Set<String> seen = new HashSet<String>();
        for (X509Certificate c : chain) seen.add(sha256(c));
        for (int depth = 0; depth < 8; depth++) {
            X509Certificate top = chain.get(chain.size() - 1);
            if (selfSigned(top)) break;
            X509Certificate issuer = findIssuer(top, pool);
            if (issuer == null) {
                issuer = fetchIssuer(top);
                if (issuer != null) pool.add(issuer);
            }
            if (issuer == null || !seen.add(sha256(issuer))) return null;
            chain.add(issuer);
        }
        X509Certificate root = chain.get(chain.size() - 1);
        if (!selfSigned(root) || !pinned(root) || chain.size() <= start.length) return null;
        return chain.toArray(new X509Certificate[0]);
    }

    static boolean selfSigned(X509Certificate c) {
        if (!c.getSubjectX500Principal().equals(c.getIssuerX500Principal())) return false;
        return signedBy(c, c);
    }

    static boolean signedBy(X509Certificate c, X509Certificate issuer) {
        try {
            if (issuer.getBasicConstraints() < 0) return false;      // must be a CA certificate
            c.verify(issuer.getPublicKey());
            return true;
        } catch (Exception e) {
            return false;
        }
    }

    static X509Certificate findIssuer(X509Certificate c, List<X509Certificate> pool) {
        for (X509Certificate i : pool) {
            if (i.getSubjectX500Principal().equals(c.getIssuerX500Principal()) && !i.equals(c) && signedBy(c, i)) return i;
        }
        return null;
    }

    static boolean pinned(X509Certificate root) throws Exception {
        String h = sha256(root);
        for (String p : PINNED_ROOTS) if (p.equals(h)) return true;
        return false;
    }

    static String sha256(X509Certificate c) throws Exception {
        byte[] d = MessageDigest.getInstance("SHA-256").digest(c.getEncoded());
        StringBuilder sb = new StringBuilder();
        for (byte b : d) sb.append(String.format("%02x", b & 0xff));
        return sb.toString();
    }

    static List<X509Certificate> loadDirs() {
        List<X509Certificate> out = new ArrayList<X509Certificate>();
        List<File> dirs = new ArrayList<File>(DIRS);
        if (cacheDir != null) dirs.add(cacheDir);
        for (File d : dirs) {
            File[] fs = d.listFiles();
            if (fs == null) continue;
            for (File f : fs) {
                String n = f.getName().toLowerCase();
                if (!f.isFile() || f.length() > 1 << 20) continue;
                if (!(n.endsWith(".cer") || n.endsWith(".crt") || n.endsWith(".pem") || n.endsWith(".der")
                      || n.endsWith(".p7b") || n.endsWith(".p7c"))) continue;
                try {
                    out.addAll(parse(readAll(new FileInputStream(f), 1 << 20)));
                } catch (Exception ignored) { }
            }
        }
        return out;
    }

    static List<X509Certificate> parse(byte[] data) throws Exception {
        CertificateFactory cf = CertificateFactory.getInstance("X.509");
        List<X509Certificate> out = new ArrayList<X509Certificate>();
        try {
            Collection<? extends Certificate> cs = cf.generateCertificates(new ByteArrayInputStream(data));
            for (Certificate c : cs) if (c instanceof X509Certificate) out.add((X509Certificate) c);
        } catch (CertificateException e) {
            // Some CA files are base64 without the BEGIN/END lines.
            String s = new String(data, "US-ASCII").replaceAll("[^A-Za-z0-9+/=]", "");
            byte[] der = java.util.Base64.getDecoder().decode(s);
            out.add((X509Certificate) cf.generateCertificate(new ByteArrayInputStream(der)));
        }
        return out;
    }

    /** Downloads the issuer from the certificate's own AIA "CA Issuers" http address. */
    static X509Certificate fetchIssuer(X509Certificate c) {
        for (String u : caIssuerUrls(c)) {
            if (!u.startsWith("http://") && !u.startsWith("https://")) continue;
            try {
                HttpURLConnection con = (HttpURLConnection) new URL(u).openConnection();
                con.setConnectTimeout(5000);
                con.setReadTimeout(8000);
                con.setInstanceFollowRedirects(true);
                con.setRequestProperty("User-Agent", "railway-dsc-suite");
                if (con.getResponseCode() != 200) continue;
                byte[] data = readAll(con.getInputStream(), 1 << 20);
                for (X509Certificate i : parse(data)) {
                    if (i.getSubjectX500Principal().equals(c.getIssuerX500Principal()) && signedBy(c, i)) {
                        save(i);
                        log("fetched " + i.getSubjectX500Principal().getName() + " from " + u);
                        return i;
                    }
                }
            } catch (Exception e) {
                log("could not fetch " + u + ": " + e);
            }
        }
        return null;
    }

    static void save(X509Certificate c) {
        if (cacheDir == null) return;
        try {
            if (!cacheDir.isDirectory() && !cacheDir.mkdirs()) return;
            File f = new File(cacheDir, sha256(c).substring(0, 16) + ".cer");
            File tmp = new File(cacheDir, f.getName() + ".tmp");
            OutputStream o = new FileOutputStream(tmp);
            try { o.write(c.getEncoded()); } finally { o.close(); }
            if (!tmp.renameTo(f)) tmp.delete();
        } catch (Exception ignored) { }
    }

    /** Minimal DER walk of the AuthorityInfoAccess extension for id-ad-caIssuers URIs. */
    static List<String> caIssuerUrls(X509Certificate c) {
        List<String> out = new ArrayList<String>();
        byte[] ext = c.getExtensionValue("1.3.6.1.5.5.7.1.1");
        if (ext == null) return out;
        try {
            Der oct = new Der(ext, 0);                      // OCTET STRING
            Der seq = new Der(ext, oct.start);              // SEQUENCE OF AccessDescription
            int p = seq.start;
            while (p < seq.end) {
                Der ad = new Der(ext, p);                   // AccessDescription
                Der oid = new Der(ext, ad.start);
                Der name = new Der(ext, oid.end);
                byte[] caIssuers = {0x2b, 0x06, 0x01, 0x05, 0x05, 0x07, 0x30, 0x02};
                boolean match = oid.tag == 0x06 && oid.end - oid.start == caIssuers.length;
                for (int i = 0; match && i < caIssuers.length; i++) match = ext[oid.start + i] == caIssuers[i];
                if (match && name.tag == 0x86) out.add(new String(ext, name.start, name.end - name.start, "US-ASCII"));
                p = ad.end;
            }
        } catch (Exception ignored) { }
        return out;
    }

    static final class Der {
        final int tag, start, end;
        Der(byte[] b, int p) {
            tag = b[p] & 0xff;
            int len = b[p + 1] & 0xff, q = p + 2;
            if (len > 0x80) {
                int n = len & 0x7f;
                len = 0;
                for (int i = 0; i < n; i++) len = (len << 8) | (b[q++] & 0xff);
            }
            start = q;
            end = q + len;
            if (end > b.length) throw new IllegalArgumentException("bad DER");
        }
    }

    static byte[] readAll(InputStream in, int max) throws IOException {
        try {
            ByteArrayOutputStream bo = new ByteArrayOutputStream();
            byte[] buf = new byte[8192];
            int n;
            while ((n = in.read(buf)) > 0) {
                bo.write(buf, 0, n);
                if (bo.size() > max) throw new IOException("too large");
            }
            return bo.toByteArray();
        } finally {
            in.close();
        }
    }

    /** Offline check: java -cp chain-fill.jar railwaydsc.ChainFillAgent CA-DIR cert.cer */
    public static void main(String[] a) throws Exception {
        if (a.length < 2) { System.err.println("usage: CA-DIR[:DIR] CERT-FILE"); System.exit(2); }
        install(a[0]);
        List<X509Certificate> leaf = parse(readAll(new FileInputStream(a[1]), 1 << 20));
        X509Certificate[] done = complete(new Certificate[] {leaf.get(0)}, new ArrayList<X509Certificate>());
        if (done == null) { System.out.println("NOT COMPLETED"); System.exit(1); }
        for (X509Certificate c : done) System.out.println(c.getSubjectX500Principal().getName());
    }
}
