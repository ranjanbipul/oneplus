package com.antigravity.tetherctl;

import android.os.IBinder;
import java.lang.reflect.Constructor;
import java.lang.reflect.Field;
import java.lang.reflect.Method;

public class Main {
    private static Object getConnector() throws Exception {
        Class<?> smClass = Class.forName("android.os.ServiceManager");
        Method getService = smClass.getMethod("getService", String.class);
        IBinder binder = (IBinder) getService.invoke(null, "tethering");
        if (binder == null) {
            throw new IllegalStateException("ServiceManager returned null for 'tethering'");
        }
        Class<?> stubClass = Class.forName("android.net.ITetheringConnector$Stub");
        Method asInterface = stubClass.getMethod("asInterface", IBinder.class);
        return asInterface.invoke(null, binder);
    }

    public static void startTethering(int type) throws Exception {
        Object connector = getConnector();

        // Use official TetheringRequest.Builder to ensure all defaults
        // (including connectivityScope = CONNECTIVITY_SCOPE_GLOBAL) are properly initialized.
        Class<?> builderClass = Class.forName("android.net.TetheringManager$TetheringRequest$Builder");
        Constructor<?> ctor = builderClass.getDeclaredConstructor(int.class);
        Object builder = ctor.newInstance(type);

        Method setExempt = builderClass.getMethod("setExemptFromEntitlementCheck", boolean.class);
        setExempt.invoke(builder, true);

        Method setShouldShowEntitlementUi = builderClass.getMethod("setShouldShowEntitlementUi", boolean.class);
        setShouldShowEntitlementUi.invoke(builder, false);

        Method build = builderClass.getMethod("build");
        Object request = build.invoke(builder);

        // Extract the underlying Parcelable request object
        Field fParcel = request.getClass().getDeclaredField("mRequestParcel");
        fParcel.setAccessible(true);
        Object parcel = fParcel.get(request);

        // Ensure packageName is set to a privileged caller
        Field fPkg = parcel.getClass().getDeclaredField("packageName");
        fPkg.setAccessible(true);
        fPkg.set(parcel, "com.android.shell");

        // Double check connectivityScope is GLOBAL (1) for non-NCM
        Field fScope = parcel.getClass().getDeclaredField("connectivityScope");
        fScope.setAccessible(true);
        if (fScope.getInt(parcel) == 0) {
            fScope.setInt(parcel, 1);
        }

        Class<?> listenerClass = Class.forName("android.net.IIntResultListener");
        Method startTethering = connector.getClass().getMethod("startTethering", parcel.getClass(), String.class, String.class, listenerClass);
        startTethering.invoke(connector, parcel, "com.android.shell", null, null);
    }

    public static void stopTethering(int type) throws Exception {
        Object connector = getConnector();
        Class<?> listenerClass = Class.forName("android.net.IIntResultListener");
        Method stopTethering = connector.getClass().getMethod("stopTethering", int.class, String.class, String.class, listenerClass);
        stopTethering.invoke(connector, type, "com.android.shell", null, null);
    }

    public static void stopAll() throws Exception {
        Object connector = getConnector();
        Class<?> listenerClass = Class.forName("android.net.IIntResultListener");
        Method stopAll = connector.getClass().getMethod("stopAllTethering", String.class, String.class, listenerClass);
        stopAll.invoke(connector, "com.android.shell", null, null);
    }

    public static void main(String[] args) {
        if (args.length < 1) {
            System.err.println("Usage: tetherctl <start-wifi|stop-wifi|start-eth|stop-eth|stop-all>");
            System.exit(1);
        }
        String cmd = args[0].toLowerCase();
        try {
            switch (cmd) {
                case "start-wifi":
                case "wifi-on":
                    startTethering(0);
                    System.out.println("OK: Wi-Fi tethering started");
                    break;
                case "stop-wifi":
                case "wifi-off":
                    stopTethering(0);
                    System.out.println("OK: Wi-Fi tethering stopped");
                    break;
                case "start-eth":
                case "eth-on":
                    startTethering(5);
                    System.out.println("OK: Ethernet tethering started");
                    break;
                case "stop-eth":
                case "eth-off":
                    stopTethering(5);
                    System.out.println("OK: Ethernet tethering stopped");
                    break;
                case "stop-all":
                    stopAll();
                    System.out.println("OK: All tethering stopped");
                    break;
                default:
                    System.err.println("Unknown command: " + cmd);
                    System.exit(1);
            }
        } catch (Throwable t) {
            System.err.println("Error executing " + cmd + ": " + t.getMessage());
            t.printStackTrace(System.err);
            System.exit(2);
        }
    }
}
