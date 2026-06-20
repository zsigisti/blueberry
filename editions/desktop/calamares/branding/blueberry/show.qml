/* show.qml — Calamares slideshow shown while Blueberry Desktop installs. */
import QtQuick 2.0
import calamares.slideshow 1.0

Presentation {
    id: presentation

    Timer {
        interval: 7000
        running: true
        repeat: true
        onTriggered: presentation.goToNextSlide()
    }

    Slide {
        Text {
            anchors.centerIn: parent
            horizontalAlignment: Text.AlignHCenter
            color: "#2a1a4a"
            font.pixelSize: 22
            text: "Welcome to Blueberry Desktop\n\n" +
                  "A self-hosted Linux, built from source — no upstream mirrors."
        }
    }

    Slide {
        Text {
            anchors.centerIn: parent
            horizontalAlignment: Text.AlignHCenter
            color: "#2a1a4a"
            font.pixelSize: 22
            text: "Powered by systemd and bpm\n\n" +
                  "Install software with 'bpm install <name>' from the\n" +
                  "signed Blueberry package index."
        }
    }

    Slide {
        Text {
            anchors.centerIn: parent
            horizontalAlignment: Text.AlignHCenter
            color: "#2a1a4a"
            font.pixelSize: 22
            text: "KDE Plasma by default, GNOME if you prefer\n\n" +
                  "Your desktop, your choice — both ship from the same base."
        }
    }

    function onActivate() { presentation.currentSlide = 0; }
    function onLeave() {}
}
