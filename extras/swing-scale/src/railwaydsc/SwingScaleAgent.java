package railwaydsc;

import java.awt.AWTEvent;
import java.awt.Component;
import java.awt.Container;
import java.awt.Dialog;
import java.awt.Dimension;
import java.awt.Font;
import java.awt.Frame;
import java.awt.Rectangle;
import java.awt.Toolkit;
import java.awt.Window;
import java.awt.event.AWTEventListener;
import java.awt.event.HierarchyEvent;
import java.awt.event.WindowEvent;
import java.lang.instrument.Instrumentation;
import java.util.Collections;
import java.util.Map;
import java.util.WeakHashMap;
import javax.swing.JComponent;
import javax.swing.RootPaneContainer;
import javax.swing.SwingUtilities;

/*
 * Railway DSC suite: enlarges Swing windows of programs that run on Java 8, which
 * cannot scale Swing on Linux (sun.java2d.uiScale is ignored there). NIC's eOffice
 * signer draws its PIN window with fixed pixel positions, so on a HiDPI screen it is
 * tiny. When a window opens, this agent multiplies its fonts, the positions/sizes of
 * components in fixed-layout panels, and the window size by the given factor.
 *
 * Usage: java -javaagent:swing-scale.jar=1.5 -jar app.jar
 * Nothing in the application's own jar is changed.
 */
public final class SwingScaleAgent {
    private static final Map<Window, Boolean> DONE = Collections.synchronizedMap(new WeakHashMap<Window, Boolean>());
    private static float factor = 1.0f;

    private SwingScaleAgent() {}

    public static void premain(String args, Instrumentation inst) { start(args); }
    public static void agentmain(String args, Instrumentation inst) { start(args); }

    private static void start(String args) {
        try {
            factor = Float.parseFloat(args == null || args.trim().isEmpty() ? "1.5" : args.trim());
        } catch (NumberFormatException e) {
            factor = 1.5f;
        }
        if (factor <= 1.01f || factor > 4f) return;
        if (java.awt.GraphicsEnvironment.isHeadless()) return;
        try {
            /* Before the window is mapped: its native peer has just been made (setVisible -> addNotify) but the
               window manager has not seen it yet, so the larger size counts even for a NOT RESIZABLE window
               (GNOME/mutter ignores a later resize of one: NIC's PIN window stayed 280x165 with 1.5x contents). */
            Toolkit.getDefaultToolkit().addAWTEventListener(new AWTEventListener() {
                @Override public void eventDispatched(AWTEvent e) {
                    if (!(e instanceof HierarchyEvent) || !(e.getSource() instanceof Window)) return;
                    HierarchyEvent h = (HierarchyEvent) e;
                    Window w = (Window) e.getSource();
                    if (h.getChanged() == w && (h.getChangeFlags() & HierarchyEvent.DISPLAYABILITY_CHANGED) != 0
                            && w.isDisplayable() && !w.isShowing()) scaleWindow(w);
                }
            }, AWTEvent.HIERARCHY_EVENT_MASK);
            /* Fallback, after it opened (a window shown in a way the event above missed) */
            Toolkit.getDefaultToolkit().addAWTEventListener(new AWTEventListener() {
                @Override public void eventDispatched(AWTEvent e) {
                    if (e.getID() == WindowEvent.WINDOW_OPENED && e.getSource() instanceof Window) {
                        final Window w = (Window) e.getSource();
                        SwingUtilities.invokeLater(new Runnable() { @Override public void run() { scaleWindow(w); } });
                    }
                }
            }, AWTEvent.WINDOW_EVENT_MASK);
        } catch (Throwable t) {
            // headless or toolkit not available yet: leave windows as they are
        }
    }

    static void scaleWindow(Window w) {
        if (DONE.put(w, Boolean.TRUE) != null) return;           // each window once
        try {
            Container content = (w instanceof RootPaneContainer) ? ((RootPaneContainer) w).getContentPane() : w;
            boolean fixedLayout = content.getLayout() == null;
            Dimension before = w.getSize();
            Rectangle where = w.getBounds();
            scaleTree(w);
            /* a fixed-size window: open it for the resize, then fixed again (the window manager takes the new
               fixed size from the size hints written while it is resizable) */
            boolean fixed = (w instanceof Frame && !((Frame) w).isResizable()) || (w instanceof Dialog && !((Dialog) w).isResizable());
            if (fixed) setResizable(w, true);
            if (fixedLayout) {
                w.setSize(Math.round(before.width * factor), Math.round(before.height * factor));
            } else {
                w.pack();
                Dimension p = w.getSize();
                w.setSize(Math.max(p.width, Math.round(before.width * factor)), Math.max(p.height, Math.round(before.height * factor)));
            }
            if (fixed) setResizable(w, false);
            Dimension after = w.getSize();               // keep the window centred where it was
            w.setLocation(where.x - (after.width - where.width) / 2, where.y - (after.height - where.height) / 2);
            w.validate();
            w.repaint();
        } catch (Throwable t) {
            // never break the application because of cosmetics
        }
    }

    private static void setResizable(Window w, boolean on) {
        if (w instanceof Frame) ((Frame) w).setResizable(on);
        else if (w instanceof Dialog) ((Dialog) w).setResizable(on);
    }

    private static void scaleTree(Component c) {
        Font f = c.getFont();
        if (f != null && c.getParent() != null && (c.getParent().getFont() != f || c instanceof JComponent)) {
            c.setFont(f.deriveFont(f.getSize2D() * factor));
        }
        Container parent = c.getParent();
        if (parent != null && parent.getLayout() == null && !(c instanceof Window)) {
            Rectangle r = c.getBounds();
            c.setBounds(Math.round(r.x * factor), Math.round(r.y * factor), Math.round(r.width * factor), Math.round(r.height * factor));
        }
        if (c instanceof JComponent) {
            JComponent j = (JComponent) c;
            if (j.isPreferredSizeSet()) {
                Dimension d = j.getPreferredSize();
                j.setPreferredSize(new Dimension(Math.round(d.width * factor), Math.round(d.height * factor)));
            }
        }
        if (c instanceof Container) {
            for (Component k : ((Container) c).getComponents()) scaleTree(k);
        }
    }
}
