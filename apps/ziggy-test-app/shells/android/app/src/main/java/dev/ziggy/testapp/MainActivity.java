package dev.ziggy.testapp;

import android.app.Activity;
import android.content.Intent;
import android.os.Bundle;
import android.webkit.WebView;
import dev.ziggy.nativeapp.ZiggyShell;

// The Ziggy test app's one screen: a web view run by Ziggy's shell. What is the test app's own is the name of its backend library
// and the mobile limits on the backend's threads.
public final class MainActivity extends Activity {
    private ZiggyShell shell;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        WebView webView = new WebView(this);
        setContentView(webView);
        shell = new ZiggyShell(this, webView, "ziggy_test_app", 5, 2);
        shell.start();
    }

    @Override
    protected void onResume() {
        super.onResume();
        shell.onResume();
    }

    @Override
    protected void onActivityResult(int requestCode, int resultCode, Intent data) {
        if (!shell.onActivityResult(requestCode, resultCode, data)) {
            super.onActivityResult(requestCode, resultCode, data);
        }
    }

    @Override
    protected void onDestroy() {
        shell.destroy();
        super.onDestroy();
    }
}
