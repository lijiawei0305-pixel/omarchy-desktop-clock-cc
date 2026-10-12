import QtQuick
import QtTest
import Quickshell
import qs.Commons as Commons
import "Plugin/renderer" as Plugin

// Isolated rendering benchmark: uses the real service, four real surfaces,
// and synthetic pointer events; the host never changes user configuration.
ShellRoot {
    id: profile
    property var host: QtObject {
        function updateEntryInline(id, settings) { profile.writes++; return true; }
    }
    property int writes: 0
    property var surface: null
    property real originX: 0
    property real originY: 0
    property double started: 0
    property int eventsSent: 0
    property int positionUpdates: 0
    property var gaps: []
    property double previous: 0
    readonly property int duration: Number(Quickshell.env("DESKTOP_CLOCK_PROFILE_DURATION") || 5000)

    Plugin.ClockController {
        id: service
        emptyScreens: {
            var result = {};
            for (var screen of Quickshell.screens) result[screen.name] = true;
            return result;
        }
        onSaveRequested: settings => profile.host.updateEntryInline("clock-profile", settings)
    }
    TestEvent { id: pointer }
    Connections {
        target: service
        function onPositionChanged() {
            if (profile.started > 0) profile.positionUpdates++;
        }
    }

    Timer {
        interval: 1000
        running: true
        onTriggered: {
            var variants = service.resources.find(function(item) { return "instances" in item; });
            profile.surface = variants.instances[0];
            service.movePosition(0.5, 0.52);
            profile.originX = profile.surface.clockX - (profile.surface.inputX || 0)
                              + profile.surface.clockWidth / 2;
            profile.originY = profile.surface.clockY - (profile.surface.inputY || 0)
                              + profile.surface.clockHeight / 2;
            pointer.mousePress(profile.surface.contentItem, profile.originX, profile.originY,
                               Qt.LeftButton, Qt.NoModifier, 0);
            profile.started = Date.now();
            profile.previous = profile.started;
            console.log("CLOCK_PROFILE_START");
            motion.start();
        }
    }

    Timer {
        id: motion
        interval: 16
        repeat: true
        onTriggered: {
            var now = Date.now();
            var elapsed = now - profile.started;
            profile.gaps.push(now - profile.previous);
            profile.previous = now;
            // Eight samples per tick model a high polling-rate pointer.
            for (var sample = 0; sample < 8; sample++) {
                var phase = (elapsed + sample) / 300;
                pointer.mouseMove(profile.surface.contentItem,
                    profile.originX + Math.sin(phase) * 180,
                    profile.originY + Math.cos(phase) * 80,
                    0, Qt.LeftButton, Qt.NoModifier);
                profile.eventsSent++;
            }
            if (elapsed >= profile.duration) {
                stop();
                pointer.mouseRelease(profile.surface.contentItem,
                    profile.originX, profile.originY, Qt.LeftButton, Qt.NoModifier, 0);
                profile.gaps.sort(function(a, b) { return a - b; });
                console.log("CLOCK_PROFILE_RESULT " + JSON.stringify({
                    durationMs: Date.now() - profile.started,
                    inputEvents: profile.eventsSent,
                    positionUpdates: profile.positionUpdates,
                    ticks: profile.gaps.length,
                    tickMedianMs: profile.gaps[Math.floor(profile.gaps.length * 0.5)],
                    tickP95Ms: profile.gaps[Math.floor(profile.gaps.length * 0.95)],
                    tickMaxMs: profile.gaps[profile.gaps.length - 1],
                    writes: profile.writes
                }));
                Qt.quit();
            }
        }
    }
}
