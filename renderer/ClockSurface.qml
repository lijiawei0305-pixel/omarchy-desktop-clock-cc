import QtQuick
import Quickshell
import Quickshell.Wayland
import "Position.js" as Position

PanelWindow {
    id: panel

    required property var controller
    required property date timestamp
    readonly property real edgeMargin: 24
    readonly property real screenWidth: screen ? screen.width : 1920
    readonly property real screenHeight: screen ? screen.height : 1080
    readonly property real displayScale: Math.min(controller.clockScale,
        Math.max(0.1, (screenWidth - 2 * edgeMargin) / 444),
        Math.max(0.1, (screenHeight - 2 * edgeMargin) / 186))
    readonly property real clockWidth: 444 * displayScale
    readonly property real clockHeight: 186 * displayScale
    readonly property int clockX: Position.pixel(controller.position.x, screenWidth, clockWidth, edgeMargin)
    readonly property int clockY: Position.pixel(controller.position.y, screenHeight, clockHeight, edgeMargin)
    readonly property int inputX: controller.dragging
        ? Position.pixel(controller.dragOrigin.x, screenWidth, clockWidth, edgeMargin) : clockX
    readonly property int inputY: controller.dragging
        ? Position.pixel(controller.dragOrigin.y, screenHeight, clockHeight, edgeMargin) : clockY
    readonly property var displayWindow: display
    readonly property var minimizedWindow: tab
    // Native remapping can re-announce the same screen; compare its stable
    // name to avoid coupling minimized state to backing-window creation.
    readonly property string screenName: screen ? screen.name : ""
    readonly property bool minimized: controller.isMinimized(screenName)

    anchors { top: true; left: true }
    margins { top: panel.inputY; left: panel.inputX }
    implicitWidth: clockWidth
    implicitHeight: clockHeight
    color: "transparent"
    exclusionMode: ExclusionMode.Ignore
    visible: !minimized && !remapping
    WlrLayershell.namespace: "omarchy-desktop-clock-input"
    WlrLayershell.layer: WlrLayer.Bottom
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

    // The transparent input window retains a stationary pointer grab. The
    // visible window stays mapped throughout every gesture, including release.
    property bool remapping: false
    Timer { id: settle; interval: 200; onTriggered: panel.remapping = true }
    Timer { interval: 50; running: panel.remapping; onTriggered: panel.remapping = false }
    Connections {
        target: panel.screen
        function onXChanged() { settle.restart() }
        function onYChanged() { settle.restart() }
    }
    PanelWindow {
        id: display
        screen: panel.screen
        anchors { top: true; left: true }
        margins { top: panel.clockY; left: panel.clockX }
        implicitWidth: panel.clockWidth
        implicitHeight: panel.clockHeight
        color: "transparent"
        exclusionMode: ExclusionMode.Ignore
        visible: panel.visible
        WlrLayershell.namespace: "omarchy-desktop-clock"
        WlrLayershell.layer: WlrLayer.Bottom
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
        mask: Region {}

        ClockFace {
            width: 444
            height: 186
            scale: panel.displayScale
            transformOrigin: Item.TopLeft
            timestamp: panel.timestamp
            palette: panel.controller.palette
            opacity: panel.controller.clockOpacity
            minimizeHovered: minimize.containsMouse
            // Keep card appearance stable across pointer grabs and release.
            // Only the cursor indicates dragging; no hover alpha transitions.
        }
    }

    MinimizedTab {
        id: tab
        screen: panel.screen
        slot: 0
        controller: panel.controller
        namespace: "omarchy-desktop-clock-minimized"
        accent: panel.controller.palette.accent
        visible: panel.minimized && !panel.remapping
        onRestoreRequested: Qt.callLater(function() { panel.controller.setMinimized(panel.screen.name, false); })
    }

    // Use a stationary coordinate system for the entire gesture, avoiding
    // pointer feedback when the clock itself moves under the cursor.
    MouseArea {
        id: pointer
        anchors.fill: parent
        acceptedButtons: Qt.LeftButton
        hoverEnabled: true
        cursorShape: pressed ? Qt.ClosedHandCursor : Qt.OpenHandCursor
        property point pressPoint: Qt.point(0, 0)
        property point startPosition: Qt.point(0, 0)

        onPressed: mouse => {
            pressPoint = Qt.point(mouse.x, mouse.y);
            startPosition = Qt.point(panel.clockX, panel.clockY);
            panel.controller.beginDrag();
        }
        onPositionChanged: mouse => {
            if (!pressed) return;
            panel.controller.queuePosition(
                Position.fraction(startPosition.x + mouse.x - pressPoint.x,
                                  panel.screenWidth, panel.clockWidth, panel.edgeMargin),
                Position.fraction(startPosition.y + mouse.y - pressPoint.y,
                                  panel.screenHeight, panel.clockHeight, panel.edgeMargin));
        }
        onReleased: panel.controller.savePosition()
        onCanceled: panel.controller.cancelDrag()
    }

    MouseArea {
        id: minimize
        objectName: "minimizeHitArea"
        x: panel.clockWidth - 50 * panel.displayScale
        y: 14 * panel.displayScale
        width: 24 * panel.displayScale
        height: 24 * panel.displayScale
        z: 1
        hoverEnabled: true
        acceptedButtons: Qt.LeftButton
        cursorShape: Qt.PointingHandCursor
        onClicked: Qt.callLater(function() { panel.controller.setMinimized(panel.screen.name, true); })
    }

    Component.onDestruction: if (pointer.pressed) panel.controller.cancelDrag()
}
