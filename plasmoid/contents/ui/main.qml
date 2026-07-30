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

    // gmediarender-output vit dans ~/.local/bin, absent du PATH de plasmashell :
    // on passe par un shell pour que $HOME soit resolu.
    readonly property string bin: "$HOME/.local/bin/gmediarender-output"

    property string peripheriqueActuel: "…"
    property string descriptionActive: "…"
    property bool rendererActif: false
    property bool occupe: false

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

    ListModel { id: modelePeripheriques }

    function rafraichir() {
        shell.lancer("--data", function (sortie) {
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
                }
            }
        });
        shell.lancer("--status", function (sortie, code) {
            root.rendererActif = (code === 0);
        });
    }

    function basculer(nom) {
        if (occupe || nom === peripheriqueActuel) return;
        occupe = true;
        shell.lancer('"' + nom + '"', function () {
            occupe = false;
            rafraichir();
        });
    }

    Component.onCompleted: { rafraichir(); abonnement.ecouter() }

    // Écoute des événements PulseAudio en temps réel : on lance une commande
    // qui bloque jusqu'au prochain événement sink-input (avec un timeout de
    // sécurité de 10 s), puis on la relance immédiatement. Le moteur
    // "executable" de Plasma attend la fin de la commande pour émettre
    // onNewData, donc on ne peut pas garder pactl subscribe ouvert en continu.
    Plasma5Support.DataSource {
        id: abonnement
        engine: "executable"
        connectedSources: []

        property bool actif: false

        function ecouter() {
            if (actif) return
            actif = true
            // stdbuf -oL désactive le buffer de sortie de pactl subscribe,
            // sinon grep ne reçoit jamais les lignes (buffer de pipe).
            // timeout 10 sur pactl : si aucun événement, le processus se
            // termine et on relance. grep -m 1 sort au premier sink-input.
            // Le || true couvre le SIGPIPE de grep quand pactl est tué.
            connectSource("sh -c 'stdbuf -oL timeout 10 pactl subscribe 2>/dev/null | grep --line-buffered -m 1 \"sink-input\" || true'")
        }

        onNewData: (source, data) => {
            disconnectSource(source)
            actif = false
            if (!root.occupe) root.rafraichir()
            // Relance immédiate : on se remet à écouter le prochain événement.
            ecouter()
        }
    }

    // Filet de sécurité : rafraîchissement toutes les 30 s au cas où un
    // événement serait manqué (pactl subscribe redémarre, etc.).
    Timer {
        interval: 30000; running: true; repeat: true
        onTriggered: if (!root.occupe) root.rafraichir()
    }

    readonly property string icone: "org.gmediarender.kde"
    Plasmoid.icon: icone
    toolTipMainText: i18n("Bureau Renderer")
    toolTipSubText: rendererActif
        ? i18n("Output: %1", descriptionActive)
        : i18n("Renderer inactive")

    compactRepresentation: MouseArea {
        onClicked: root.expanded = !root.expanded
        Kirigami.Icon {
            anchors.fill: parent
            source: root.icone
            isMask: true
            opacity: root.rendererActif ? 1.0 : 0.5
        }
    }

    fullRepresentation: PlasmaExtras.Representation {
        Layout.minimumWidth: Kirigami.Units.gridUnit * 24
        Layout.minimumHeight: Kirigami.Units.gridUnit * 10
        Layout.preferredHeight: Kirigami.Units.gridUnit * 18

        header: PlasmaExtras.PlasmoidHeading {
            RowLayout {
                anchors.fill: parent
                spacing: Kirigami.Units.smallSpacing

                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 0
                    PlasmaExtras.Heading {
                        level: 4
                        text: root.rendererActif ? root.descriptionActive : i18n("Inactive")
                        elide: Text.ElideRight
                        Layout.fillWidth: true
                    }
                    PlasmaComponents.Label {
                        text: root.rendererActif
                            ? i18n("DLNA renderer output")
                            : i18n("Run systemctl --user start gmediarender")
                        font: Kirigami.Theme.smallFont
                        opacity: 0.7
                        elide: Text.ElideRight
                        Layout.fillWidth: true
                    }
                }
                PlasmaComponents.BusyIndicator {
                    running: root.occupe
                    visible: running
                    Layout.preferredWidth: Kirigami.Units.iconSizes.small
                    Layout.preferredHeight: Kirigami.Units.iconSizes.small
                }
            }
        }

        contentItem: PlasmaComponents.ScrollView {
            ListView {
                id: liste
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

        footer: PlasmaExtras.PlasmoidHeading {
            position: QQC.ToolBar.Footer
            contentItem: PlasmaComponents.Label {
                text: i18n("Click a device to switch the renderer output")
                font: Kirigami.Theme.smallFont
                opacity: 0.7
                horizontalAlignment: Text.AlignHCenter
                Layout.fillWidth: true
            }
        }
    }
}