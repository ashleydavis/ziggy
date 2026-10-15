// Ziggy's dev mode script, which the dev host serves at /__ziggy/dev.js and puts in every page it passes on from the app's dev
// server, before the inject script and before any script of the UI. Nothing of dev mode is in the inject script or the core, so this
// script gives the browser what the inject script looks for in a web view: the handle WebKitGTK and WKWebView give a page,
// window.webkit.messageHandlers.ziggy, whose postMessage here sends the message over a WebSocket to the dev host.
//
// A message from the core arrives as the JSON text the native apps hand window.__ziggyReceive, and is handed to it the same way.
//
// When the connection closes, the dev host has stopped, most often to be rebuilt. The page waits until it responds again and then
// reloads, because the core it was talking to is gone and a new one has started.
//
// A browser gives a page no dropped file's path. The inject script hands a drop's files to WebView2's
// window.chrome.webview.postMessageWithAdditionalObjects, so this script gives the page that too. Each file handed over is sent to
// the dev host, which saves a copy and records the copies' paths with the core as the drop, as a native app records the paths it
// read. Messages to the core wait until the drop is recorded, so the inject script's request for the drop's paths, which it posts
// straight after handing the files over, gets the copies'.
(function () {
    if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.ziggy) {
        throw new Error("Ziggy dev: this page already has a web view's message handler, so it is not running in an ordinary browser.");
    }
    if (window.chrome && window.chrome.webview) {
        throw new Error("Ziggy dev: this page already has WebView2's handle, so it is not running in an ordinary browser.");
    }

    var socket = new window.WebSocket("ws://" + window.location.host + "/__ziggy/socket");
    var open = false;
    var waiting = [];
    var dropsBeingRecorded = 0;

    // Sends the messages that have waited, in order, unless the socket is not open yet or a drop is still being recorded.
    function sendWaiting() {
        if (!open || dropsBeingRecorded > 0) {
            return;
        }
        waiting.forEach(function (text) {
            socket.send(text);
        });
        waiting = [];
    }

    socket.addEventListener("open", function () {
        open = true;
        sendWaiting();
    });

    socket.addEventListener("message", function (event) {
        var message = JSON.parse(event.data);
        window.__ziggyReceive(message);
    });

    socket.addEventListener("close", function () {
        open = false;
        console.warn("Ziggy dev: the dev host has gone. The page reloads when it is back.");
        reloadWhenDevHostAnswers();
    });

    function reloadWhenDevHostAnswers() {
        window.fetch("/__ziggy/alive", { cache: "no-store" }).then(function (response) {
            if (!response.ok) {
                throw new Error("the dev host answered " + response.status);
            }
            window.location.reload();
        }).catch(function () {
            window.setTimeout(reloadWhenDevHostAnswers, 250);
        });
    }

    function postMessage(text) {
        waiting.push(text);
        sendWaiting();
    }

    // Sends each file to the dev host and then records the drop. Rejects, naming the file and the dev host's response, when any
    // step fails.
    function recordDrop(files) {
        var paths = [];
        var uploads = files.reduce(function (previous, file) {
            return previous.then(function () {
                return window.fetch("/__ziggy/dropped-file?name=" + encodeURIComponent(file.name), { method: "POST", body: file }).then(function (response) {
                    return response.text().then(function (text) {
                        if (!response.ok) {
                            throw new Error("Ziggy dev: the dev host could not save the dropped file " + file.name + ": " + text);
                        }
                        paths.push(text);
                    });
                });
            });
        }, Promise.resolve());
        return uploads.then(function () {
            return window.fetch("/__ziggy/drop", { method: "POST", body: JSON.stringify(paths) });
        }).then(function (response) {
            if (!response.ok) {
                return response.text().then(function (text) {
                    throw new Error("Ziggy dev: the dev host could not record the drop: " + text);
                });
            }
        });
    }

    // Takes the files of a drop from the inject script, as WebView2 does, and records them as the drop. When that fails, an empty
    // drop is recorded instead, so the inject script's request for the drop's paths never gets the paths of an earlier drop.
    function postMessageWithAdditionalObjects(message, files) {
        if (message !== "ziggy-file") {
            throw new Error("Ziggy dev: the page handed over objects with the message " + JSON.stringify(message) + ", and only a drop's files, with the message \"ziggy-file\", are taken.");
        }
        dropsBeingRecorded += 1;
        recordDrop(Array.prototype.slice.call(files)).catch(function (error) {
            console.error(error);
            return window.fetch("/__ziggy/drop", { method: "POST", body: "[]" }).then(function (response) {
                if (!response.ok) {
                    throw new Error("Ziggy dev: the dev host could not record an empty drop in place of the one that failed, so the page may be given the paths of an earlier drop.");
                }
            });
        }).catch(function (error) {
            console.error(error);
        }).then(function () {
            dropsBeingRecorded -= 1;
            sendWaiting();
        });
    }

    window.chrome = window.chrome || {};
    window.chrome.webview = {
        postMessageWithAdditionalObjects: postMessageWithAdditionalObjects,
    };

    window.webkit = {
        messageHandlers: {
            ziggy: {
                postMessage: postMessage,
            },
        },
    };
})();
