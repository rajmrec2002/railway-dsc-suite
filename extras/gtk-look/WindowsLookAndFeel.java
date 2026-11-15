package com.sun.java.swing.plaf.windows;

import java.awt.GraphicsEnvironment;
import java.awt.Toolkit;
import java.lang.reflect.Method;

/*
 * Railway DSC suite: CrisSigner/IREPSSigner call
 * UIManager.setLookAndFeel(new WindowsLookAndFeel()), which does not exist on Linux.
 * This stand-in answers to that name but is the desktop's own GTK look, so the
 * signer windows follow the system theme and fonts.
 *
 * HiDPI: Java's GTK look sizes fonts from the desktop DPI (gnome.Xft/DPI, e.g. 192
 * on a 2x screen) and Java then applies sun.java2d.uiScale on top, doubling the
 * text. Dividing the DPI it sees by the UI scale gives native-size text.
 * Needs: --add-exports=java.desktop/com.sun.java.swing.plaf.gtk=ALL-UNNAMED
 *        --add-opens=java.desktop/java.awt=ALL-UNNAMED   (for the DPI correction)
 */
public class WindowsLookAndFeel extends com.sun.java.swing.plaf.gtk.GTKLookAndFeel {
    static {
        try {
            Toolkit tk = Toolkit.getDefaultToolkit();
            Object dpi = tk.getDesktopProperty("gnome.Xft/DPI");          // 1024ths of a DPI
            double scale = GraphicsEnvironment.isHeadless() ? 1.0 :
                GraphicsEnvironment.getLocalGraphicsEnvironment().getDefaultScreenDevice()
                    .getDefaultConfiguration().getDefaultTransform().getScaleY();
            if (dpi instanceof Integer && scale > 1.01) {
                Method set = Toolkit.class.getDeclaredMethod("setDesktopProperty", String.class, Object.class);
                set.setAccessible(true);
                set.invoke(tk, "gnome.Xft/DPI", (int) Math.round(((Integer) dpi) / scale));
            }
        } catch (Throwable ignored) {
            // keep GTK's own sizing
        }
    }
    @Override public String getName() { return "Windows (GTK on Linux)"; }
    @Override public String getID() { return "Windows"; }
    @Override public String getDescription() { return "GTK look standing in for the Windows look on Linux"; }
}
