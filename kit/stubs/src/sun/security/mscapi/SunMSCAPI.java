package sun.security.mscapi;

/*
 * Railway DSC suite: stand-in for the Windows-only "SunMSCAPI" provider that the
 * vendor's signing libraries reference. On Linux they only touch it on code paths
 * guarded by os.name.startsWith("Windows"); this empty provider lets the classes load
 * without redistributing Oracle's sunmscapi.jar.
 */
public final class SunMSCAPI extends java.security.Provider {
    private static final long serialVersionUID = 1L;
    public SunMSCAPI() {
        super("SunMSCAPI", "1.0", "Windows CryptoAPI provider (not available on Linux)");
    }
}
