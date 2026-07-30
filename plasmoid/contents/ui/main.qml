import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC
import org.kde.plasma.plasmoid
import org.kde.plasma.components as PlasmaComponents
import org.kde.plasma.extras as PlasmaExtras
import org.kde.kirigami as Kirigami
import org.kde.plasma.plasma5support as Plasma5Support

PlasmoidItem {
    id: root

    readonly property string bin: "$HOME/.local/bin/gmediarender-output"

    property string peripheriqueActuel: "…"
    property string descriptionActive: "…"
    property bool occupe: false
    property string dernierEtat: ""

    Plasma5Support.DataSource {
        id: shell
        engine: "executable"
        connectedSources: []
        property var rappels: ({})

        function lancer(commande, rappel) {
            const cle = "sh -c " + "'" + bin + " " + commande + "'";
            rappels[cle] = rappel;
            connectSource(cle);
        }

        onNewData: (source, data) => {
            const rappel = rappels[source];
            delete rappels[source];
            disconnectSource(source);
            if (rappel) {
                rappel(("" + data["stdout"]).trim(), data["exit code"]);
            }
        }
    }

    ListModel { id: modeleServices }
    ListModel { id: modelePeripheriques }
    ListModel { id: modeleNoms }  // protocol <TAB> name

    function rafraichir() {
        // Services (DLNA, AirPlay, Spotify)
        shell.lancer("--services", function (sortie) {
            modeleServices.clear();
            for (const ligne of sortie.split("\n")) {
                if (!ligne) continue;
                const c = ligne.split("\t");
                if (c.length < 3) continue;
                modeleServices.append({
                    nom: c[0],
                    service: c[1],
                    actif: c[2] === "1"
                });
            }
        });
        // Receiver names
        shell.lancer("--names", function (sortie) {
            modeleNoms.clear();
            for (const ligne of sortie.split("\n")) {
                if (!ligne) continue;
                const c = ligne.split("\t");
                if (c.length < 2) continue;
                modeleNoms.append({ proto: c[0], nom: c[1] });
            }
        });
        // Output devices
        shell.lancer("--sinks", function (sortie) {
            modelePeripheriques.clear();
            for (const ligne of sortie.split("\n")) {
                if (!ligne) continue;
                const c = ligne.split("\t");
                if (c.length < 3) continue;
                modelePeripheriques.append({
                    description: c[0],
                    nom: c[1],
                    estActif: c[2] === "1"
                });
                if (c[2] === "1") {
                    root.peripheriqueActuel = c[1];
                    root.descriptionActive = c[0];
                    root.dernierEtat = c[1];
                }
            }
        });
    }

    function basculer(nom) {
        if (occupe || nom === peripheriqueActuel) return;
        occupe = true;
        shell.lancer('"' + nom + '"', function () {
            occupe = false;
            dernierEtat = nom;
            rafraichir();
        });
    }

    function basculerService(svc) {
        if (occupe) return;
        occupe = true;
        shell.lancer("--toggle " + svc, function () {
            occupe = false;
            rafraichir();
        });
    }

    function redemarrerService(svc) {
        if (occupe) return;
        occupe = true;
        shell.lancer("--restart " + svc, function () {
            occupe = false;
            rafraichir();
        });
    }

    function toutRedemarrer() {
        if (occupe) return;
        occupe = true;
        shell.lancer("--restart-all", function () {
            occupe = false;
            rafraichir();
        });
    }

    function renommerTous(nom) {
        if (occupe || !nom || nom.length === 0) return;
        occupe = true;
        const safeNom = nom.replace(/'/g, "'\\''");
        shell.lancer("--rename-all '" + safeNom + "'", function () {
            occupe = false;
            rafraichir();
        });
    }

    Component.onCompleted: rafraichir()

    // Polling : vérifie si le sink actif a changé (switch externe).
    Timer {
        interval: 500; running: true; repeat: true
        onTriggered: {
            if (root.occupe) return
            shell.lancer("--current", function (sortie) {
                if (sortie !== root.dernierEtat) {
                    root.dernierEtat = sortie
                    root.rafraichir()
                }
            })
        }
    }

    // Polling des services : vérifie toutes les 3 s si un service a changé d'état.
    Timer {
        interval: 3000; running: true; repeat: true
        onTriggered: {
            if (!root.occupe) {
                shell.lancer("--services", function (sortie) {
                    modeleServices.clear();
                    for (const ligne of sortie.split("\n")) {
                        if (!ligne) continue;
                        const c = ligne.split("\t");
                        if (c.length < 3) continue;
                        modeleServices.append({
                            nom: c[0], service: c[1], actif: c[2] === "1"
                        });
                    }
                })
            }
        }
    }

    readonly property string icone: "org.gmediarender.kde"
    Plasmoid.icon: icone
    toolTipMainText: i18n("Bureau Receivers")
    toolTipSubText: i18n("DLNA · AirPlay · Spotify")

    compactRepresentation: MouseArea {
        onClicked: root.expanded = !root.expanded
        Kirigami.Icon {
            anchors.fill: parent
            source: root.icone
            isMask: true
        }
    }

    fullRepresentation: PlasmaExtras.Representation {
        Layout.minimumWidth: Kirigami.Units.gridUnit * 26
        Layout.minimumHeight: Kirigami.Units.gridUnit * 14
        Layout.preferredHeight: Kirigami.Units.gridUnit * 22

        header: PlasmaExtras.PlasmoidHeading {
            RowLayout {
                anchors.fill: parent
                spacing: Kirigami.Units.smallSpacing

                // Single editable name field — updates all three receivers.
                PlasmaComponents.TextField {
                    id: champNomGlobal
                    Layout.fillWidth: true
                    enabled: !root.occupe
                    text: {
                        for (let i = 0; i < modeleNoms.count; i++) {
                            const e = modeleNoms.get(i);
                            if (e.proto === "DLNA") return e.nom.replace(/ \(DLNA\)$/, "");
                        }
                        return "Bureau";
                    }
                    placeholderText: i18n("Receiver name")
                    readOnly: true

                    MouseArea {
                        anchors.fill: parent
                        acceptedButtons: Qt.LeftButton
                        onDoubleClicked: {
                            champNomGlobal.readOnly = false;
                            champNomGlobal.selectAll();
                            champNomGlobal.forceActiveFocus();
                        }
                    }

                    onAccepted: {
                        if (!readOnly) {
                            readOnly = true;
                            focus = false;
                            root.renommerTous(text);
                        }
                    }
                    onActiveFocusChanged: {
                        if (!activeFocus && !readOnly) {
                            readOnly = true;
                            root.renommerTous(text);
                        }
                    }
                }

                PlasmaComponents.BusyIndicator {
                    running: root.occupe
                    visible: running
                    Layout.preferredWidth: Kirigami.Units.iconSizes.small
                    Layout.preferredHeight: Kirigami.Units.iconSizes.small
                }
                PlasmaComponents.ToolButton {
                    icon.name: "view-refresh"
                    enabled: !root.occupe
                    onClicked: root.toutRedemarrer()
                    PlasmaComponents.ToolTip.text: i18n("Restart all receivers")
                    PlasmaComponents.ToolTip.visible: hovered
                    PlasmaComponents.ToolTip.delay: 700
                }
            }
        }

        contentItem: ColumnLayout {
            spacing: Kirigami.Units.smallSpacing

            // --- Section : Receivers ---
            PlasmaComponents.Label {
                text: i18n("Receivers")
                font: Kirigami.Theme.smallFont
                opacity: 0.6
                Layout.leftMargin: Kirigami.Units.smallSpacing
            }

            Repeater {
                model: modeleServices

                delegate: RowLayout {
                    Layout.fillWidth: true
                    Layout.leftMargin: Kirigami.Units.smallSpacing
                    Layout.rightMargin: Kirigami.Units.smallSpacing
                    spacing: Kirigami.Units.smallSpacing

                    Kirigami.Icon {
                        source: model.actif ? "media-playback-start" : "media-playback-pause"
                        Layout.preferredWidth: Kirigami.Units.iconSizes.small
                        Layout.preferredHeight: Kirigami.Units.iconSizes.small
                        opacity: model.actif ? 1.0 : 0.4
                    }

                    PlasmaComponents.Label {
                        text: model.nom
                        Layout.fillWidth: true
                        font.bold: model.actif
                        opacity: model.actif ? 1.0 : 0.5
                    }

                    PlasmaComponents.ToolButton {
                        icon.name: "view-refresh"
                        enabled: !root.occupe && model.actif
                        onClicked: root.redemarrerService(model.service)
                        PlasmaComponents.ToolTip.text: i18n("Restart %1", model.nom)
                        PlasmaComponents.ToolTip.visible: hovered
                        PlasmaComponents.ToolTip.delay: 700
                    }

                    PlasmaComponents.Switch {
                        checked: model.actif
                        enabled: !root.occupe
                        onClicked: root.basculerService(model.service)
                    }
                }
            }

            Kirigami.Separator {
                Layout.fillWidth: true
                Layout.topMargin: Kirigami.Units.smallSpacing
                Layout.bottomMargin: Kirigami.Units.smallSpacing
            }

            // --- Section : Output devices ---
            PlasmaComponents.Label {
                text: i18n("Output device")
                font: Kirigami.Theme.smallFont
                opacity: 0.6
                Layout.leftMargin: Kirigami.Units.smallSpacing
            }

            PlasmaComponents.ScrollView {
                Layout.fillWidth: true
                Layout.fillHeight: true
                ListView {
                    model: modelePeripheriques
                    spacing: Kirigami.Units.smallSpacing
                    clip: true
                    currentIndex: -1

                    delegate: PlasmaComponents.ItemDelegate {
                        width: ListView.view.width
                        enabled: !root.occupe
                        highlighted: model.estActif
                        onClicked: root.basculer(model.nom)

                        contentItem: RowLayout {
                            spacing: Kirigami.Units.smallSpacing

                            Kirigami.Icon {
                                source: model.estActif ? "checkmark" : "audio-card"
                                Layout.preferredWidth: Kirigami.Units.iconSizes.small
                                Layout.preferredHeight: Kirigami.Units.iconSizes.small
                                opacity: model.estActif ? 1.0 : 0.6
                            }

                            ColumnLayout {
                                Layout.fillWidth: true
                                spacing: 0
                                PlasmaComponents.Label {
                                    text: model.description
                                    elide: Text.ElideRight
                                    Layout.fillWidth: true
                                    font.bold: model.estActif
                                }
                                PlasmaComponents.Label {
                                    text: model.nom
                                    elide: Text.ElideRight
                                    font: Kirigami.Theme.smallFont
                                    opacity: 0.6
                                    Layout.fillWidth: true
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}