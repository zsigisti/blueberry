/* show.qml — Blueberry Desktop install slideshow.
 * A polished, branded sequence shown while Calamares copies the system. */
import QtQuick 2.0
import calamares.slideshow 1.0

Presentation {
    id: presentation

    property color berryDeep:  "#2a1a4a"
    property color berryMid:   "#3d2a6b"
    property color berryGlow:  "#5b8def"
    property color ink:        "#f4f1fb"
    property color sub:        "#c9bfe6"

    Timer {
        interval: 8000
        running: true
        repeat: true
        onTriggered: presentation.goToNextSlide()
    }

    // ---- reusable slide chrome: brand gradient + heading + body -------------
    function slideBg(parent) {}

    Slide {
        Rectangle {
            anchors.fill: parent
            gradient: Gradient {
                GradientStop { position: 0.0; color: presentation.berryDeep }
                GradientStop { position: 1.0; color: presentation.berryMid }
            }
            Column {
                anchors.centerIn: parent
                spacing: 18
                width: parent.width * 0.8
                Text {
                    width: parent.width
                    horizontalAlignment: Text.AlignHCenter
                    color: presentation.ink
                    font.pixelSize: 40; font.bold: true
                    text: "🫐  Welcome to Blueberry Desktop"
                }
                Text {
                    width: parent.width
                    horizontalAlignment: Text.AlignHCenter
                    wrapMode: Text.WordWrap
                    color: presentation.sub
                    font.pixelSize: 20
                    text: "A self-hosted Linux, built entirely from source.\n" +
                          "Sit back — we're installing your new desktop."
                }
            }
        }
    }

    Slide {
        Rectangle {
            anchors.fill: parent
            gradient: Gradient {
                GradientStop { position: 0.0; color: presentation.berryDeep }
                GradientStop { position: 1.0; color: presentation.berryMid }
            }
            Column {
                anchors.centerIn: parent
                spacing: 14
                width: parent.width * 0.82
                Text {
                    width: parent.width; horizontalAlignment: Text.AlignHCenter
                    color: presentation.ink; font.pixelSize: 32; font.bold: true
                    text: "Everything you need, out of the box"
                }
                Text {
                    width: parent.width; horizontalAlignment: Text.AlignHCenter
                    wrapMode: Text.WordWrap; color: presentation.sub; font.pixelSize: 20
                    text: "Firefox · Brave · Dolphin · Konsole · Kate · Okular\n" +
                          "GIMP · Blender · Steam · Spotify\n\n" +
                          "A full KDE Plasma 6 desktop, ready to go."
                }
            }
        }
    }

    Slide {
        Rectangle {
            anchors.fill: parent
            gradient: Gradient {
                GradientStop { position: 0.0; color: presentation.berryDeep }
                GradientStop { position: 1.0; color: presentation.berryMid }
            }
            Column {
                anchors.centerIn: parent
                spacing: 14
                width: parent.width * 0.82
                Text {
                    width: parent.width; horizontalAlignment: Text.AlignHCenter
                    color: presentation.ink; font.pixelSize: 32; font.bold: true
                    text: "Software you can trust"
                }
                Text {
                    width: parent.width; horizontalAlignment: Text.AlignHCenter
                    wrapMode: Text.WordWrap; color: presentation.sub; font.pixelSize: 20
                    text: "Every package is built from source and served from one\n" +
                          "signed mirror. Installs are ed25519-signed and\n" +
                          "SHA-256 verified — no third-party mirrors, ever.\n\n" +
                          "Install anything:   bpm install <name>"
                }
            }
        }
    }

    Slide {
        Rectangle {
            anchors.fill: parent
            gradient: Gradient {
                GradientStop { position: 0.0; color: presentation.berryDeep }
                GradientStop { position: 1.0; color: presentation.berryMid }
            }
            Column {
                anchors.centerIn: parent
                spacing: 14
                width: parent.width * 0.82
                Text {
                    width: parent.width; horizontalAlignment: Text.AlignHCenter
                    color: presentation.ink; font.pixelSize: 32; font.bold: true
                    text: "Stable, the way you want it"
                }
                Text {
                    width: parent.width; horizontalAlignment: Text.AlignHCenter
                    wrapMode: Text.WordWrap; color: presentation.sub; font.pixelSize: 20
                    text: "Two releases a year, with a 2-year LTS each April.\n" +
                          "Your kernel stays pinned and tested for the whole\n" +
                          "release — daily updates never break your machine."
                }
            }
        }
    }

    Slide {
        Rectangle {
            anchors.fill: parent
            gradient: Gradient {
                GradientStop { position: 0.0; color: presentation.berryDeep }
                GradientStop { position: 1.0; color: presentation.berryGlow }
            }
            Column {
                anchors.centerIn: parent
                spacing: 16
                width: parent.width * 0.8
                Text {
                    width: parent.width; horizontalAlignment: Text.AlignHCenter
                    color: presentation.ink; font.pixelSize: 34; font.bold: true
                    text: "Almost there…"
                }
                Text {
                    width: parent.width; horizontalAlignment: Text.AlignHCenter
                    wrapMode: Text.WordWrap; color: presentation.ink; font.pixelSize: 20
                    text: "When the install finishes, reboot and sign in.\n" +
                          "Welcome to the family. 🫐"
                }
            }
        }
    }

    function onActivate() { presentation.currentSlide = 0; }
    function onLeave() {}
}
