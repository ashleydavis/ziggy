package dev.ziggy.testapp;

import android.app.Activity;
import android.content.Intent;
import android.os.Bundle;
import android.webkit.WebView;
import dev.ziggy.nativeapp.ZiggyNativeApp;

// The Ziggy test app's one screen: a web view run by Ziggy's native app. What is the test app's own is the name of its backend library
// and the mobile limits on the backend's threads.
public final class MainActivity extends Activity {
    private ZiggyNativeApp nativeApp;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        WebView webView = new WebView(this);
        setContentView(webView);
        nativeApp = new ZiggyNativeApp(this, webView, "ziggy_test_app", 5, 2);
        nativeApp.start();
    }

    @Override
    protected void onResume() {
        super.onResume();
        nativeApp.onResume();
    }

    @Override
    protected void onActivityResult(int requestCode, int resultCode, Intent data) {
        if (!nativeApp.onActivityResult(requestCode, resultCode, data)) {
            super.onActivityResult(requestCode, resultCode, data);
        }
    }

    @Override
    protected void onDestroy() {
        nativeApp.destroy();
        super.onDestroy();
    }
}
