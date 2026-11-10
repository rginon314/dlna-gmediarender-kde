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
    ListModel { id: modeleGroupes }
    ListModel { id: modeleDistants }

    function rafraichir() {
        if (!enVie) return;
        poll();
    }

    // Single --poll call: returns services, active player, player info,
    // volume, current sink, sinks, and names in one output. This avoids
    // multiple concurrent DataSource connections that crash plasmashell.
    function poll() {
        if (!enVie) return;
        shell.lancer("--poll", function (sortie) {
            if (!enVie) return;
            var section = "";
            var lines = sortie.split("\n");
            for (var i = 0; i < lines.length; i++) {
                var line = lines[i];
                if (line.startsWith("### ")) {
                    section = line.substring(4);
                    continue;
                }
                if (line === "### end") break;
                var c = line.split("\t");

                switch (section) {
                case "services":
                    if (c.length >= 3) {
                        // Check if we need to update the model.
                        var found = false;
                        for (var j = 0; j < modeleServices.count; j++) {
                            var e = modeleServices.get(j);
                            if (e.nom === c[0]) {
                                e.service = c[1];
                                e.actif = c[2] === "1";
                                found = true;
                                break;
                            }
                        }
                        if (!found) {
                            modeleServices.append({ nom: c[0], service: c[1], actif: c[2] === "1" });
                        }
                    }
                    break;
                case "active":
                    var proto = line.trim();
                    if (proto === "") joueurActif = "";
                    break;
                case "player":
                    if (c.length >= 6) {
                        joueurActif = c[0] || joueurActif;
                        playerStatus = c[0];
                        playerTitle = c[1];
                        playerArtist = c[2];
                        playerAlbum = c[3];
                        playerPosition = parseFloat(c[4]) || 0;
                        playerDuration = parseFloat(c[5]) || 0;
                    }
                    break;
                case "volume":
                    playerVolume = parseInt(line) || 0;
                    break;
                case "current":
                    dernierEtat = line.trim();
                    break;
                case "sinks":
                    if (c.length >= 3) {
                        // Update model in place.
                        var sfound = false;
                        for (var k = 0; k < modelePeripheriques.count; k++) {
                            var s = modelePeripheriques.get(k);
                            if (s.nom === c[1]) {
                                s.description = c[0];
                                s.estActif = c[2] === "1";
                                sfound = true;
                                break;
                            }
                        }
                        if (!sfound) {
                            modelePeripheriques.append({ description: c[0], nom: c[1], estActif: c[2] === "1" });
                        }
                        if (c[2] === "1") {
                            root.peripheriqueActuel = c[1];
                            root.descriptionActive = c[0];
                        }
                    }
                    break;
                case "names":
                    if (c.length >= 2) {
                        var nfound = false;
                        for (var m = 0; m < modeleNoms.count; m++) {
                            var n = modeleNoms.get(m);
                            if (n.proto === c[0]) {
                                n.nom = c[1];
                                nfound = true;
                                break;
                            }
                        }
                        if (!nfound) {
                            modeleNoms.append({ proto: c[0], nom: c[1] });
                        }
                    }
                    break;
                case "groups":
                    // TSV: name, members, applied(0/1)
                    if (c.length >= 3) {
                        var gfound = false;
                        for (var g = 0; g < modeleGroupes.count; g++) {
                            var ge = modeleGroupes.get(g);
                            if (ge.nom === c[0]) {
                                ge.membres = c[1];
                                ge.applique = c[2] === "1";
                                gfound = true;
                                break;
                            }
                        }
                        if (!gfound) {
                            modeleGroupes.append({
                                nom: c[0], membres: c[1], applique: c[2] === "1"
                            });
                        }
                    }
                    break;
                case "remotes":
                    // TSV: id, name, type, sink, up(0/1)
                    if (c.length >= 5) {
                        var rfound = false;
                        for (var r = 0; r < modeleDistants.count; r++) {
                            var re = modeleDistants.get(r);
                            if (re.id === c[0]) {
                                re.nom = c[1];
                                re.type = c[2];
                                re.actif = c[4] === "1";
                                rfound = true;
                                break;
                            }
                        }
                        if (!rfound) {
                            modeleDistants.append({
                                id: c[0], nom: c[1], type: c[2], actif: c[4] === "1"
                            });
                        }
                    }
                    break;
                }
            }
        });
    }

    // Returns the name of the currently applied group, or "".
    function groupeApplique() {
        for (var i = 0; i < modeleGroupes.count; i++) {
            var g = modeleGroupes.get(i);
            if (g.applique) return g.nom;
        }
        return "";
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

    // --- Multi-room actions ---

    function appliquerGroupe(nom) {
        if (occupe || !nom) return;
        occupe = true;
        const safe = nom.replace(/'/g, "'\\''");
        shell.lancer("--group-apply '" + safe + "'", function () {
            occupe = false;
            poll();
        });
    }

    function leverGroupe() {
        if (occupe) return;
        occupe = true;
        shell.lancer("--group-unapply", function () {
            occupe = false;
            poll();
        });
    }

    function basculerDistante(id) {
        if (occupe || !id) return;
        occupe = true;
        // Figure out whether it is up by looking at the model.
        var up = false;
        for (var i = 0; i < modeleDistants.count; i++) {
            var d = modeleDistants.get(i);
            if (d.id === id) { up = d.actif; break; }
        }
        const cmd = up ? "--remote-down " : "--remote-up ";
        shell.lancer(cmd + id, function () {
            occupe = false;
            poll();
        });
    }

    // Open a discover + save dialog handled by the CLI.
    function ajouterAppareil() {
        if (occupe) return;
        occupe = true;
        shell.lancer("--discover", function (sortie) {
            occupe = false;
            // Feed results into a picker; simple approach: append any
            // discovered device that isn't known yet.
            var lignes = sortie.split("\n");
            var toAdd = [];
            for (var i = 0; i < lignes.length; i++) {
                if (!lignes[i]) continue;
                var c = lignes[i].split("\t");
                if (c.length < 5) continue;
                var known = false;
                for (var k = 0; k < modeleDistants.count; k++) {
                    if (modeleDistants.get(k).id === c[4]) { known = true; break; }
                }
                if (!known) toAdd.push(c);
            }
            if (toAdd.length === 0) { poll(); return; }
            // Add them sequentially.
            var idx = 0;
            function next() {
                if (idx >= toAdd.length) { poll(); return; }
                var c = toAdd[idx++];
                var spec = c[0] + ":" + c[1] + ":" + c[2] + ":" + c[3];
                var safe = spec.replace(/'/g, "'\\''");
                shell.lancer("--add-device '" + safe + "'", function () { next(); });
            }
            next();
        });
    }

    property bool enVie: true

    Component.onCompleted: rafraichir()
    Component.onDestruction: enVie = false

    // Single polling timer: one --poll call every 1s replaces the
    // previous 3 timers (500ms, 1s, 3s) that each launched multiple
    // DataSource connections and crashed plasmashell.
    Timer {
        interval: 1000; running: true; repeat: true
        onTriggered: if (!root.occupe && root.enVie) root.poll()
    }

    // Délai avant rafraîchissement après une commande de transport :
    // laisse le temps au renderer de changer d'état avant de relire.
    Timer {
        id: delaiRafraichir
        interval: 500
        onTriggered: root.poll()
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
                        id: curseurPosition
                        Layout.fillWidth: true
                        from: 0
                        to: Math.max(1, playerDuration)
                        enabled: playerDuration > 0 && joueurActif !== "" && joueurActif !== "AirPlay" && joueurActif !== "Spotify"
                        // Ne pas mettre à jour la position pendant que
                        // l'utilisateur glide le curseur : la valeur serait
                        // écrasée par le polling et le curseur reviendrait.
                        value: pressed ? value : playerPosition
                        onMoved: {
                            occupe = true
                            shell.lancer("--player " + joueurActif + " seek " + Math.round(value), function(){
                                occupe = false
                                delaiRafraichir.start()
                            })
                        }
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

                // Transport buttons.
                // DLNA: play/pause only (next/prev not supported by gmediarender).
                // AirPlay/Spotify: transport controlled from the source device.
                RowLayout {
                    Layout.fillWidth: true
                    Layout.alignment: Qt.AlignHCenter
                    spacing: Kirigami.Units.largeSpacing
                    visible: joueurActif === "DLNA"

                    PlasmaComponents.ToolButton {
                        icon.name: playerStatus === "Playing" ? "media-playback-pause" : "media-playback-start"
                        onClicked: {
                            var cmd = playerStatus === "Playing" ? "pause" : "play";
                            occupe = true
                            shell.lancer("--player " + joueurActif + " " + cmd, function(){
                                occupe = false
                                delaiRafraichir.start()
                            })
                        }
                    }
                }

                // Info message for protocols without transport control.
                PlasmaComponents.Label {
                    Layout.fillWidth: true
                    text: i18n("Transport controlled from the source device")
                    font: Kirigami.Theme.smallFont
                    opacity: 0.5
                    horizontalAlignment: Text.AlignHCenter
                    visible: joueurActif === "AirPlay" || joueurActif === "Spotify"
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

            // --- Section : Multi-room groups ---
            Kirigami.Separator {
                Layout.fillWidth: true
                Layout.topMargin: Kirigami.Units.smallSpacing
                Layout.bottomMargin: Kirigami.Units.smallSpacing
            }

            RowLayout {
                Layout.fillWidth: true
                Layout.leftMargin: Kirigami.Units.smallSpacing
                Layout.rightMargin: Kirigami.Units.smallSpacing

                PlasmaComponents.Label {
                    text: i18n("Multi-room")
                    font: Kirigami.Theme.smallFont
                    opacity: 0.6
                    Layout.fillWidth: true
                }

                PlasmaComponents.ToolButton {
                    icon.name: "list-add"
                    enabled: !root.occupe
                    onClicked: root.ajouterAppareil()
                    PlasmaComponents.ToolTip.text: i18n("Discover and add devices")
                    PlasmaComponents.ToolTip.visible: hovered
                    PlasmaComponents.ToolTip.delay: 700
                }
                PlasmaComponents.ToolButton {
                    icon.name: "edit-delete"
                    enabled: !root.occupe && root.groupeApplique() !== ""
                    onClicked: root.leverGroupe()
                    PlasmaComponents.ToolTip.text: i18n("Stop multi-room")
                    PlasmaComponents.ToolTip.visible: hovered
                    PlasmaComponents.ToolTip.delay: 700
                }
            }

            // Saved groups
            Repeater {
                model: modeleGroupes
                delegate: PlasmaComponents.ItemDelegate {
                    Layout.fillWidth: true
                    enabled: !root.occupe && !model.applique
                    onClicked: root.appliquerGroupe(model.nom)

                    contentItem: RowLayout {
                        spacing: Kirigami.Units.smallSpacing
                        Kirigami.Icon {
                            source: model.applique ? "checkmark" : "media-playlist-repeat"
                            Layout.preferredWidth: Kirigami.Units.iconSizes.small
                            Layout.preferredHeight: Kirigami.Units.iconSizes.small
                            opacity: model.applique ? 1.0 : 0.6
                        }
                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 0
                            PlasmaComponents.Label {
                                text: model.nom
                                font.bold: model.applique
                                elide: Text.ElideRight
                                Layout.fillWidth: true
                            }
                            PlasmaComponents.Label {
                                text: model.membres
                                font: Kirigami.Theme.smallFont
                                opacity: 0.55
                                elide: Text.ElideRight
                                Layout.fillWidth: true
                            }
                        }
                    }
                }
            }

            // Known remote devices with an on/off toggle
            Repeater {
                model: modeleDistants
                delegate: RowLayout {
                    Layout.fillWidth: true
                    Layout.leftMargin: Kirigami.Units.smallSpacing * 2
                    Layout.rightMargin: Kirigami.Units.smallSpacing
                    spacing: Kirigami.Units.smallSpacing

                    Kirigami.Icon {
                        source: model.type === "airplay" ? "video-telephone" : "network-server"
                        Layout.preferredWidth: Kirigami.Units.iconSizes.small
                        Layout.preferredHeight: Kirigami.Units.iconSizes.small
                        opacity: model.actif ? 1.0 : 0.45
                    }
                    PlasmaComponents.Label {
                        text: model.nom
                        Layout.fillWidth: true
                        font: Kirigami.Theme.smallFont
                        opacity: model.actif ? 0.95 : 0.55
                        elide: Text.ElideRight
                    }
                    PlasmaComponents.Switch {
                        checked: model.actif
                        enabled: !root.occupe
                        onClicked: root.basculerDistante(model.id)
                    }
                }
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