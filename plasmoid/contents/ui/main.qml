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
    property string joueurActif: ""
    property string playerStatus: ""
    property string playerTitle: ""
    property string playerArtist: ""
    property string playerAlbum: ""
    property real playerPosition: 0
    property real playerDuration: 0
    property int playerVolume: 0

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

    function rafraichirPlayer() {
        if (occupe) return;
        // Build list of active protocols.
        var protos = [];
        for (var i = 0; i < modeleServices.count; i++) {
            var s = modeleServices.get(i);
            if (s.actif) protos.push(s.nom);
        }
        if (protos.length === 0) {
            joueurActif = "";
            return;
        }
        // Query the first protocol. If inactive, the next poll will try
        // the next one. Avoid recursive callbacks — they crash plasmashell.
        var proto = protos[0];
        shell.lancer("--player-info " + proto, function (sortie) {
            var c = sortie.split("\t");
            if (c.length >= 6) {
                var status = c[0];
                if (status !== "Inactive" && status !== "Stopped") {
                    joueurActif = proto;
                    playerStatus = status;
                    playerTitle = c[1];
                    playerArtist = c[2];
                    playerAlbum = c[3];
                    playerPosition = parseFloat(c[4]) || 0;
                    playerDuration = parseFloat(c[5]) || 0;
                    shell.lancer("--volume-info " + proto, function (vol) {
                        playerVolume = parseInt(vol) || 0;
                    });
                } else if (protos.length > 1) {
                    // Try the next protocol.
                    var proto2 = protos[1];
                    shell.lancer("--player-info " + proto2, function (sortie2) {
                        var c2 = sortie2.split("\t");
                        if (c2.length >= 6 && c2[0] !== "Inactive" && c2[0] !== "Stopped") {
                            joueurActif = proto2;
                            playerStatus = c2[0];
                            playerTitle = c2[1];
                            playerArtist = c2[2];
                            playerAlbum = c2[3];
                            playerPosition = parseFloat(c2[4]) || 0;
                            playerDuration = parseFloat(c2[5]) || 0;
                            shell.lancer("--volume-info " + proto2, function (vol2) {
                                playerVolume = parseInt(vol2) || 0;
                            });
                        } else {
                            joueurActif = "";
                        }
                    });
                } else {
                    joueurActif = "";
                }
            }
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

    // Polling du player : met à jour les infos de lecture toutes les 1 s.
    Timer {
        interval: 1000; running: true; repeat: true
        onTriggered: root.rafraichirPlayer()
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

            // --- Section : Now Playing (player controls) ---

            // Affiché seulement si un player est actif.
            ColumnLayout {
                Layout.fillWidth: true
                Layout.leftMargin: Kirigami.Units.smallSpacing
                Layout.rightMargin: Kirigami.Units.smallSpacing
                visible: joueurActif !== ""
                spacing: Kirigami.Units.smallSpacing

                PlasmaComponents.Label {
                    text: i18n("Now Playing — %1", joueurActif)
                    font: Kirigami.Theme.smallFont
                    opacity: 0.6
                }

                // Track info
                PlasmaComponents.Label {
                    text: playerTitle || i18n("(no track info)")
                    elide: Text.ElideRight
                    Layout.fillWidth: true
                    font.bold: true
                }
                PlasmaComponents.Label {
                    text: playerArtist ? playerArtist + (playerAlbum ? " — " + playerAlbum : "") : ""
                    elide: Text.ElideRight
                    Layout.fillWidth: true
                    font: Kirigami.Theme.smallFont
                    opacity: 0.7
                    visible: playerArtist !== ""
                }

                // Time slider
                RowLayout {
                    Layout.fillWidth: true
                    PlasmaComponents.Label {
                        text: {
                            var m = Math.floor(playerPosition / 60);
                            var s = Math.floor(playerPosition % 60);
                            return m + ":" + (s < 10 ? "0" + s : s);
                        }
                        font: Kirigami.Theme.smallFont
                        opacity: 0.7
                    }
                    PlasmaComponents.Slider {
                        Layout.fillWidth: true
                        from: 0
                        to: Math.max(1, playerDuration)
                        value: playerPosition
                        enabled: playerDuration > 0
                    }
                    PlasmaComponents.Label {
                        text: {
                            var m = Math.floor(playerDuration / 60);
                            var s = Math.floor(playerDuration % 60);
                            return m + ":" + (s < 10 ? "0" + s : s);
                        }
                        font: Kirigami.Theme.smallFont
                        opacity: 0.7
                    }
                }

                // Transport buttons
                RowLayout {
                    Layout.fillWidth: true
                    Layout.alignment: Qt.AlignHCenter
                    spacing: Kirigami.Units.largeSpacing

                    PlasmaComponents.ToolButton {
                        icon.name: "media-skip-backward"
                        enabled: joueurActif !== "" && joueurActif !== "DLNA" && playerStatus !== "Inactive"
                        onClicked: shell.lancer("--player " + joueurActif + " prev", function(){ root.rafraichirPlayer() })
                    }
                    PlasmaComponents.ToolButton {
                        icon.name: playerStatus === "Playing" ? "media-playback-pause" : "media-playback-start"
                        enabled: joueurActif !== "" && joueurActif !== "DLNA" && playerStatus !== "Inactive"
                        onClicked: {
                            var cmd = playerStatus === "Playing" ? "pause" : "play";
                            shell.lancer("--player " + joueurActif + " " + cmd, function(){ root.rafraichirPlayer() })
                        }
                    }
                    PlasmaComponents.ToolButton {
                        icon.name: "media-skip-forward"
                        enabled: joueurActif !== "" && joueurActif !== "DLNA" && playerStatus !== "Inactive"
                        onClicked: shell.lancer("--player " + joueurActif + " next", function(){ root.rafraichirPlayer() })
                    }
                }

                // Volume slider
                RowLayout {
                    Layout.fillWidth: true
                    spacing: Kirigami.Units.smallSpacing
                    Kirigami.Icon {
                        source: "audio-volume-low"
                        Layout.preferredWidth: Kirigami.Units.iconSizes.small
                        Layout.preferredHeight: Kirigami.Units.iconSizes.small
                        opacity: 0.7
                    }
                    PlasmaComponents.Slider {
                        Layout.fillWidth: true
                        from: 0
                        to: 100
                        value: playerVolume
                        enabled: joueurActif !== ""
                        onMoved: {
                            shell.lancer("--volume " + joueurActif + " " + Math.round(value), function(){})
                        }
                    }
                    Kirigami.Icon {
                        source: "audio-volume-high"
                        Layout.preferredWidth: Kirigami.Units.iconSizes.small
                        Layout.preferredHeight: Kirigami.Units.iconSizes.small
                        opacity: 0.7
                    }
                }
            }

            Kirigami.Separator {
                Layout.fillWidth: true
                Layout.topMargin: Kirigami.Units.smallSpacing
                Layout.bottomMargin: Kirigami.Units.smallSpacing
                visible: joueurActif !== ""
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