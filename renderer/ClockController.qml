pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import "Position.js" as Position

Item {
    id: root
    property var settings: ({})
    property var palette: ({foreground: "#c0caf5", background: "#1a1b26", accent: "#7aa2f7", fontFamily: "monospace"})
    property var emptyScreens: ({})
    readonly property var minimizedScreens: {
        var names = settings.minimizedScreens;
        // QML method/property round-trips can turn a JS array into a Qt
        // sequence. It has indexed entries and length, but is not an Array.
        if (!names || typeof names !== "object" || typeof names.length !== "number") return [];
        return Array.from(names).filter(function(name) { return typeof name === "string"; });
    }
    readonly property var eligibleScreens: Quickshell.screens.filter(function(s) { return root.emptyScreens[s.name] === true; })
    readonly property bool anyVisible: eligibleScreens.length > 0
    property point position: Qt.point(0.5, 0.52)
    property point savedPosition: Qt.point(0.5, 0.52)
    property point dragOrigin: Qt.point(0.5, 0.52)
    property point pendingPosition: Qt.point(0.5, 0.52)
    property bool positionPending: false
    property bool dragging: false
    property real minimizedTabPosition: Position.unit(settings.minimizedTabX, 0.475)
    property bool tabDragging: false
    property string tabDragScreen: ""
    property real tabDragOriginX: 0
    readonly property real clockScale: Position.clamp(Position.number(settings.scale, 1), 0.5, 2)
    readonly property real clockOpacity: Position.clamp(Position.number(settings.opacity, 1), 0.2, 1)
    property alias surfaces: surfaces
    readonly property bool clockRunning: clock.enabled
    readonly property bool motionRunning: motion.running
    signal saveRequested(var nextSettings)
    signal statusChanged()

    function isMinimized(screenName) { return minimizedScreens.indexOf(screenName) !== -1; }
    function setMinimized(screenName, minimized) {
        if (!Quickshell.screens.some(function(s) { return s.name === screenName; })
            || isMinimized(screenName) === minimized) return;
        if (dragging) cancelDrag();
        var names = minimizedScreens.filter(function(name) { return name !== screenName; });
        if (minimized) names.push(screenName);
        var next = Object.assign({}, settings, {minimizedScreens: names});
        settings = next;
        saveRequested(next);
        statusChanged();
    }

    function configure(config) {
        settings = config.settings || ({});
        minimizedTabPosition = Position.unit(settings.minimizedTabX, 0.475);
        if (config.palette) palette = config.palette;
        savedPosition = Qt.point(Position.unit(settings.positionX, 0.5), Position.unit(settings.positionY, 0.52));
        if (!dragging) position = savedPosition;
        statusChanged();
    }
    function beginTabDrag(screen) {
        if (tabDragging || !screen) return false;
        tabDragging = true;
        tabDragScreen = screen.name;
        tabDragOriginX = minimizedTabPosition;
        return true;
    }
    function updateTabDrag(screen, dx) {
        if (!tabDragging || !screen) return;
        minimizedTabPosition = Position.clamp(tabDragOriginX + dx / Math.max(1, screen.width - 72), 0, 1);
    }
    function finishTabDrag() {
        if (!tabDragging) return;
        tabDragging = false;
        var next = Object.assign({}, settings, {minimizedTabX: minimizedTabPosition});
        settings = next;
        saveRequested(next);
    }
    function cancelTabDrag() {
        tabDragging = false;
        minimizedTabPosition = Position.unit(settings.minimizedTabX, 0.475);
    }
    function beginDrag() {
        dragOrigin = position;
        positionPending = false;
        dragging = true;
        statusChanged();
    }
    function movePosition(x, y) {
        positionPending = false;
        position = Qt.point(Position.unit(x, 0.5), Position.unit(y, 0.52));
    }
    function queuePosition(x, y) {
        pendingPosition = Qt.point(Position.unit(x, 0.5), Position.unit(y, 0.52));
        positionPending = true;
    }
    function flushPosition() {
        if (!positionPending) return;
        positionPending = false;
        if (position.x !== pendingPosition.x || position.y !== pendingPosition.y) position = pendingPosition;
    }
    function savePosition() {
        flushPosition();
        dragging = false;
        var next = Object.assign({}, settings, {positionX: position.x, positionY: position.y});
        settings = next;
        savedPosition = position;
        saveRequested(next);
        statusChanged();
    }
    function cancelDrag() {
        positionPending = false;
        dragging = false;
        position = savedPosition;
        statusChanged();
    }
    function status() {
        return {positionX: position.x, positionY: position.y, dragging: dragging, minimizedScreens: minimizedScreens,
            clockRunning: clockRunning, emptyScreens: emptyScreens, palette: palette,
            screens: Quickshell.screens.map(function(screen) {
                var surface = surfaces.instances.find(function(p) { return p.screen.name === screen.name; });
                return {name: screen.name, visible: !!surface && surface.visible,
                    minimized: root.isMinimized(screen.name), tabVisible: !!surface && surface.minimizedWindow.visible,
                    tabX: surface ? surface.minimizedWindow.tabX : 0,
                    tabWidth: surface ? surface.minimizedWindow.tabWidth : 72,
                    x: surface ? surface.clockX : Position.pixel(root.position.x, screen.width, 444 * root.clockScale, 24),
                    y: surface ? surface.clockY : Position.pixel(root.position.y, screen.height, 186 * root.clockScale, 24)};
            })};
    }
    onEligibleScreensChanged: {
        if (!anyVisible && dragging) cancelDrag();
        Qt.callLater(root.statusChanged);
    }
    // A drag-only timer coalesces motion without activating an animation driver.
    Timer {
        id: motion
        interval: 16
        repeat: true
        running: root.dragging
        onTriggered: root.flushPosition()
    }
    SystemClock {
        id: clock
        precision: SystemClock.Seconds
        enabled: root.anyVisible && !root.dragging
    }
    Variants {
        id: surfaces
        model: root.eligibleScreens
        ClockSurface {
            required property var modelData
            screen: modelData
            controller: root
            timestamp: clock.date
        }
    }
}
