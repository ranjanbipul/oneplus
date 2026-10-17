#!/system/bin/sh
# tetherctl - Android 13+ Tethering Control CLI
# Root-level control via Android Tethering AIDL service

DEX="/data/adb/tether/tetherctl.dex"
TETHER_JAR="/apex/com.android.tethering/javalib/framework-tethering.jar"

if [ ! -f "$DEX" ]; then
    echo "Error: $DEX not found." >&2
    exit 1
fi

export CLASSPATH="$DEX:$TETHER_JAR"
exec app_process /system/bin com.antigravity.tetherctl.Main "$@"
