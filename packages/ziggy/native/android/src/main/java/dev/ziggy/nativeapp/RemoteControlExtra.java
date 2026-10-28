package dev.ziggy.nativeapp;

// The Intent extra that starts the app under remote control: ziggy.remoteControl, the remote control server's address,
// "host:port". It is the Android form of the --remote-control option of the desktop native apps, because an Android app is
// started with an Intent, not a command line. The core connects to the address, and test mode is on exactly when it is given.
final class RemoteControlExtra {
    // The extra's name.
    static final String NAME = "ziggy.remoteControl";

    private RemoteControlExtra() {
    }

    // The address the extra's value gives, or null when the extra is absent or empty, which leaves remote control and test mode
    // off. An empty value is treated as absent because no server can be at an empty address.
    static String address(String value) {
        if (value == null || value.isEmpty()) {
            return null;
        }
        return value;
    }
}
