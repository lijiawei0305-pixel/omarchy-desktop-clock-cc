import QtQuick
import QtQuick.Window
import QtTest
import Quickshell
import qs.Commons as Commons
import "Wave" as Wave
import "Plugin" as Plugin

// Uses Wave's actual service/Canvas with deterministic synthetic audio.
// Everything runs in temporary directories; user plugin/config files are untouched.
ShellRoot {
    id: bench
    property double started: 0
    property double previous: 0
    property var gaps: []
    property var swaps: ({})
    property var surface: null
    property int events: 0
    property int writes: 0
    readonly property string mode: Quickshell.env("CLOCK_BENCH_MODE")
    readonly property int duration: Number(Quickshell.env("CLOCK_BENCH_DURATION") || 5000)
    readonly property bool drag: Quickshell.env("CLOCK_BENCH_DRAG") === "1"
    property var host: QtObject {
        function updateEntryInline(id, settings) { bench.writes++; return true; }
    }
    Wave.Service { id: wave }
    Loader {
        id: clock
        active: bench.mode === "shared"
        sourceComponent: Component { Plugin.Service { shell: bench.host } }
    }
    TestEvent { id: pointer }
    Connections {
        target: wave
        function onFrameChanged() {
            if (!bench.started) return;
            var now = Date.now();
            bench.gaps.push(now - bench.previous);
            bench.previous = now;
        }
    }
    Variants {
        model: Quickshell.screens
        QtObject {
            id: probe
            required property var modelData
            property var panel: null
            property var connections: Connections {
                target: probe.panel ? probe.panel.contentItem.Window.window : null
                function onFrameSwapped() {
                    if (!bench.started) return;
                    var name = probe.modelData.name;
                    var now = Date.now();
                    var entry = bench.swaps[name];
                    if (!entry) entry = bench.swaps[name] = {count: 0, previous: now, gaps: []};
                    if (entry.count) entry.gaps.push(now - entry.previous);
                    entry.previous = now;
                    entry.count++;
                }
            }
            property var startup: Timer {
                interval: 900; running: true
                onTriggered: {
                    var variants = wave.resources.find(function(r) { return "instances" in r; });
                    probe.panel = variants.instances.find(function(p) { return p.screen.name === probe.modelData.name; });
                }
            }
        }
    }
    function stats(values) {
        values.sort(function(a, b) { return a - b; });
        return { count: values.length, medianMs: values[Math.floor(values.length * 0.5)],
                 p95Ms: values[Math.floor(values.length * 0.95)], maxMs: values[values.length - 1] };
    }
    Timer {
        interval: 1500; running: true
        onTriggered: {
            if (clock.item && bench.drag) {
                var variants = clock.item.resources.find(function(r) { return "instances" in r; });
                bench.surface = variants.instances[0];
                pointer.mousePress(bench.surface.contentItem, 200, 90, Qt.LeftButton, Qt.NoModifier, 0);
                motion.start();
            }
            bench.started = bench.previous = Date.now();
            finish.start();
            console.log("COEXIST_START");
        }
    }
    Timer {
        id: motion
        interval: 16; repeat: true
        onTriggered: {
            var elapsed = Date.now() - bench.started;
            for (var sample = 0; sample < 8; sample++) {
                pointer.mouseMove(bench.surface.contentItem, 200 + Math.sin((elapsed + sample) / 300) * 180,
                    90 + Math.cos((elapsed + sample) / 300) * 70, 0, Qt.LeftButton, Qt.NoModifier);
                bench.events++;
            }
        }
    }
    Timer {
        id: finish
        interval: bench.duration
        onTriggered: {
            motion.stop();
            if (bench.surface) pointer.mouseRelease(bench.surface.contentItem, 200, 90, Qt.LeftButton, Qt.NoModifier, 0);
            var result = { durationMs: Date.now() - bench.started, frames: bench.gaps.length,
                fps: bench.gaps.length * 1000 / (Date.now() - bench.started),
                waveFrameGaps: bench.stats(bench.gaps), renders: {}, inputEvents: bench.events, writes: bench.writes };
            for (var name in bench.swaps) {
                var entry = bench.swaps[name];
                result.renders[name] = {fps: entry.count * 1000 / result.durationMs, gaps: bench.stats(entry.gaps)};
            }
            console.log("COEXIST_RESULT " + JSON.stringify(result));
            Qt.quit();
        }
    }
}
