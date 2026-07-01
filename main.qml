import QtQuick 2.15
import QtQuick.Layouts 1.15
import QtQuick.Controls 2.15
import org.kde.plasma.plasmoid 2.0
import org.kde.plasma.core 2.0 as PlasmaCore
import org.kde.kirigami 2.20 as Kirigami

PlasmoidItem {
    id: root

    toolTipMainText: "Dragon Shell"
    toolTipSubText: "Local AI terminal assistant"
    preferredRepresentation: compactRepresentation

    compactRepresentation: Item {
        Kirigami.Icon {
            anchors.centerIn: parent
            width: Math.min(parent.width, parent.height)
            height: width
            source: "utilities-terminal"
        }
        MouseArea {
            anchors.fill: parent
            onClicked: root.expanded = !root.expanded
        }
    }

    onExpandedChanged: {
        if (!expanded) {
            var xhr = new XMLHttpRequest()
            xhr.open("POST", "http://127.0.0.1:29156/shutdown_ollama")
            xhr.setRequestHeader("Content-Type", "application/json")
            xhr.send("{}")
        } else {
            var xhr2 = new XMLHttpRequest()
            xhr2.open("POST", "http://127.0.0.1:29156/cancel_shutdown")
            xhr2.setRequestHeader("Content-Type", "application/json")
            xhr2.send("{}")
        }
    }

    fullRepresentation: Item {
        id: popup
        implicitWidth: 700
        implicitHeight: Math.min(mainCol.implicitHeight + 32, 700)

        // ── State ────────────────────────────────────────────────────
        property bool queryBusy: false
        property string lastQuestion: ""
        property string lastCommand: ""
        property string lastSource: ""
        property string lastHistoryId: ""
        property string activeTab: "ask"

        function loadHistory() {
            var xhr = new XMLHttpRequest()
            xhr.open("GET", "http://127.0.0.1:29156/history")
            xhr.onreadystatechange = function() {
                if (xhr.readyState === XMLHttpRequest.DONE && xhr.status === 200) {
                    var data = JSON.parse(xhr.responseText)
                    historyListModel.clear()
                    for (var i = 0; i < data.history.length; i++) {
                        var h = data.history[i]
                        historyListModel.append({
                            histId: h.id,
                            question: h.question || "",
                            command: h.command || "",
                            explanation: h.explanation || "",
                            risk: h.risk || "LOW",
                            feedback: h.feedback || ""
                        })
                    }
                }
            }
            xhr.send()
        }

        function setHistoryFeedback(id, feedback, index) {
            var xhr = new XMLHttpRequest()
            xhr.open("POST", "http://127.0.0.1:29156/history_feedback")
            xhr.setRequestHeader("Content-Type", "application/json")
            xhr.send(JSON.stringify({id: id, feedback: feedback}))
            historyListModel.setProperty(index, "feedback", feedback)
        }
        property int unloadDelay: 0
        property string pullStatus: "idle"

        function loadSettings() {
            var xhr = new XMLHttpRequest()
            xhr.open("GET", "http://127.0.0.1:29156/get_settings")
            xhr.onreadystatechange = function() {
                if (xhr.readyState === XMLHttpRequest.DONE && xhr.status === 200) {
                    var data = JSON.parse(xhr.responseText)
                    popup.unloadDelay = data.unload_delay
                    modelListModel.clear()
                    for (var i = 0; i < data.models.length; i++) {
                        var m = data.models[i]
                        modelListModel.append({
                            modelId: m.id,
                            label: m.label,
                            installed: m.installed,
                            current: m.id === data.current_model
                        })
                    }
                }
            }
            xhr.send()
        }

        function selectModel(modelId) {
            var xhr = new XMLHttpRequest()
            xhr.open("POST", "http://127.0.0.1:29156/set_model")
            xhr.setRequestHeader("Content-Type", "application/json")
            xhr.onreadystatechange = function() {
                if (xhr.readyState === XMLHttpRequest.DONE) popup.loadSettings()
            }
            xhr.send(JSON.stringify({model_id: modelId}))
        }

        function installModel(modelId) {
            var xhr = new XMLHttpRequest()
            xhr.open("POST", "http://127.0.0.1:29156/pull_model")
            xhr.setRequestHeader("Content-Type", "application/json")
            xhr.send(JSON.stringify({model_id: modelId}))
            pullPollTimer.start()
        }

        function setUnloadDelay(seconds) {
            popup.unloadDelay = seconds
            var xhr = new XMLHttpRequest()
            xhr.open("POST", "http://127.0.0.1:29156/set_unload_delay")
            xhr.setRequestHeader("Content-Type", "application/json")
            xhr.send(JSON.stringify({seconds: seconds}))
        }

        Timer {
            id: pullPollTimer
            interval: 1500
            repeat: true
            onTriggered: {
                var xhr = new XMLHttpRequest()
                xhr.open("GET", "http://127.0.0.1:29156/pull_status")
                xhr.onreadystatechange = function() {
                    if (xhr.readyState === XMLHttpRequest.DONE && xhr.status === 200) {
                        var data = JSON.parse(xhr.responseText)
                        popup.pullStatus = data.status
                        pullStatusText.text = data.status === "downloading" ? ("Downloading: " + data.last_line) : ""
                        if (data.status === "done") {
                            pullPollTimer.stop()
                            popup.loadSettings()
                        } else if (data.status === "error") {
                            pullPollTimer.stop()
                            pullStatusText.text = "Download failed: " + data.last_line
                        }
                    }
                }
                xhr.send()
            }
        }

        // ── Functions ────────────────────────────────────────────────
        function submitQuery() {
            var q = queryInput.text.trim()
            if (q === "" || popup.queryBusy) return
            popup.queryBusy = true
            popup.lastQuestion = q
            statusLabel.text = "⏳  Starting Ollama & thinking..."
            resultArea.visible = false

            var xhr = new XMLHttpRequest()
            xhr.open("POST", "http://127.0.0.1:29156/query")
            xhr.setRequestHeader("Content-Type", "application/json")
            xhr.onreadystatechange = function() {
                if (xhr.readyState === XMLHttpRequest.DONE) {
                    popup.queryBusy = false
                    askBtn.enabled = true
                    if (xhr.status === 200) {
                        displayResult(JSON.parse(xhr.responseText))
                    } else {
                        statusLabel.text = "✗  Server error — is Dragon Shell running?"
                    }
                }
            }
            xhr.send(JSON.stringify({question: q}))
        }

        function displayResult(data) {
            var risk = (data.risk || "LOW").toUpperCase()
            var colors = {
                "LOW":      {bg:"#1a2e1a", border:"#2d5a2d", text:"#5dba5d", bar:"#3d8c3d", fill:0.25},
                "MODERATE": {bg:"#2e2a1a", border:"#5a4a1a", text:"#c4942a", bar:"#c4942a", fill:0.5},
                "HIGH":     {bg:"#2e1f1a", border:"#5a3020", text:"#d4622a", bar:"#d4622a", fill:0.75},
                "EXTREME":  {bg:"#2e1a1a", border:"#6a2020", text:"#e03030", bar:"#e03030", fill:1.0}
            }
            var c = colors[risk] || colors["LOW"]

            riskBadge.color = c.bg
            riskBadge.border.color = c.border
            riskText.text = risk
            riskText.color = c.text
            riskBarFill.width = riskBarFill.parent.width * c.fill
            riskBarFill.color = c.bar
            riskReasonLabel.text = data.risk_reason || ""
            cmdText.text = data.command || "(no command)"
            popup.lastCommand = data.command || ""
            explanationLabel.text = data.explanation || ""

            var conf = data.confidence || 0.5
            var source = data._source || "ai"
            popup.lastSource = source

            if (source === "db") {
                sourceLabel.text = "✓ From your history  (match: " + Math.round((data.db_score||1)*100) + "%)"
                sourceLabel.color = "#5a9fd4"
            } else if (data.web_verified) {
                sourceLabel.text = "🔍 Verified against real files on your system"
                sourceLabel.color = "#c4942a"
            } else if (conf >= 0.65) {
                sourceLabel.text = "🤖 AI  (confidence: " + Math.round(conf*100) + "%)"
                sourceLabel.color = "#8888aa"
            } else {
                sourceLabel.text = "⚠️  Low confidence (" + Math.round(conf*100) + "%) — verify before running"
                sourceLabel.color = "#d4622a"
            }

            undoBtn.undoCmd = data.undo || ""
            undoBtn.visible = !!data.undo
            workedBtn.visible = source !== "db"
            failedBtn.visible = source !== "db"
            popup.lastHistoryId = data.history_id || ""

            if (risk === "HIGH" || risk === "EXTREME") {
                snapCmdText.text = 'sudo snapper -c root create --description "before: ' + popup.lastCommand.substring(0,60) + '"'
                snapshotFrame.visible = true
            } else {
                snapshotFrame.visible = false
            }

            statusLabel.text = ""
            resultArea.visible = true
        }

        function copyText(txt) {
            var xhr = new XMLHttpRequest()
            xhr.open("POST", "http://127.0.0.1:29156/copy")
            xhr.setRequestHeader("Content-Type", "application/json")
            xhr.send(JSON.stringify({text: txt}))
        }

        function markWorked() {
            var xhr = new XMLHttpRequest()
            xhr.open("POST", "http://127.0.0.1:29156/mark_worked")
            xhr.setRequestHeader("Content-Type", "application/json")
            xhr.send(JSON.stringify({
                question: popup.lastQuestion,
                command: popup.lastCommand,
                source: popup.lastSource,
                history_id: popup.lastHistoryId
            }))
        }

        function markFailedAndRetry() {
            statusLabel.text = "⏳  Trying a different approach..."
            resultArea.visible = false
            var xhr = new XMLHttpRequest()
            xhr.open("POST", "http://127.0.0.1:29156/retry")
            xhr.setRequestHeader("Content-Type", "application/json")
            xhr.onreadystatechange = function() {
                if (xhr.readyState === XMLHttpRequest.DONE) {
                    if (xhr.status === 200) {
                        displayResult(JSON.parse(xhr.responseText))
                    } else {
                        statusLabel.text = "✗  Retry failed"
                    }
                }
            }
            xhr.send(JSON.stringify({
                question: popup.lastQuestion,
                failed_command: popup.lastCommand,
                history_id: popup.lastHistoryId
            }))
        }

        // ── Background ───────────────────────────────────────────────
        Rectangle {
            anchors.fill: parent
            color: "#1a1a1f"
            radius: 12
        }

        // ── UI ───────────────────────────────────────────────────────
        ScrollView {
            anchors.fill: parent
            anchors.margins: 0
            clip: true
            ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
            ScrollBar.vertical.policy: ScrollBar.AsNeeded

            ColumnLayout {
            id: mainCol
            width: popup.width - 32
            x: 16
            y: 16
            spacing: 12

            RowLayout {
                Layout.fillWidth: true
                Text {
                    text: "🐉 Dragon Shell"
                    color: "#c47a2a"
                    font.pixelSize: 15
                    font.weight: Font.DemiBold
                }
                Item { Layout.fillWidth: true }
                Button {
                    id: historyBtn
                    text: "🕘"
                    implicitWidth: 28; implicitHeight: 28
                    onClicked: {
                        popup.activeTab = popup.activeTab === "history" ? "ask" : "history"
                        if (popup.activeTab === "history") popup.loadHistory()
                    }
                    background: Rectangle {
                        color: historyBtn.hovered || popup.activeTab === "history" ? "#2a2a35" : "transparent"
                        radius: 14
                    }
                    contentItem: Text {
                        text: historyBtn.text
                        color: "#888899"
                        font.pixelSize: 14
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                    }
                }
                Button {
                    id: settingsBtn
                    text: "⚙"
                    implicitWidth: 28; implicitHeight: 28
                    onClicked: {
                        settingsPanel.visible = !settingsPanel.visible
                        if (settingsPanel.visible) popup.loadSettings()
                    }
                    background: Rectangle {
                        color: settingsBtn.hovered ? "#2a2a35" : "transparent"
                        radius: 14
                    }
                    contentItem: Text {
                        text: settingsBtn.text
                        color: "#888899"
                        font.pixelSize: 15
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                    }
                }
            }

            ColumnLayout {
                id: askTab
                Layout.fillWidth: true
                visible: popup.activeTab === "ask"
                spacing: 12

            RowLayout {
                Layout.fillWidth: true
                spacing: 8

                TextField {
                    id: queryInput
                    Layout.fillWidth: true
                    placeholderText: "Ask anything about your system..."
                    color: "#d4d4e8"
                    placeholderTextColor: "#444455"
                    font.pixelSize: 14
                    background: Rectangle {
                        color: "#12121a"
                        border.color: queryInput.activeFocus ? "#4a3a70" : "#2e2e3a"
                        border.width: 1
                        radius: 8
                    }
                    leftPadding: 12; rightPadding: 12
                    topPadding: 8; bottomPadding: 8
                    Keys.onReturnPressed: popup.submitQuery()
                }

                Button {
                    id: askBtn
                    text: "Ask"
                    implicitWidth: 60
                    enabled: !popup.queryBusy
                    onClicked: popup.submitQuery()
                    background: Rectangle {
                        color: askBtn.enabled ? (askBtn.hovered ? "#4a3880" : "#3a2870") : "#252530"
                        radius: 8
                    }
                    contentItem: Text {
                        text: askBtn.text
                        color: askBtn.enabled ? "#c8b8f0" : "#444455"
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                        font.pixelSize: 13
                        font.weight: Font.DemiBold
                    }
                }
            }

            Text {
                id: statusLabel
                Layout.fillWidth: true
                visible: text !== ""
                color: "#666677"
                font.pixelSize: 13
            }

            // ── Settings panel ──────────────────────────────────────────
            Rectangle {
                id: settingsPanel
                Layout.fillWidth: true
                visible: false
                color: "#12121a"
                border.color: "#2a2a3a"
                border.width: 1
                radius: 8
                implicitHeight: settingsCol.implicitHeight + 24

                ColumnLayout {
                    id: settingsCol
                    anchors { left: parent.left; right: parent.right; top: parent.top; margins: 12 }
                    spacing: 10

                    Text { text: "AI Model"; color: "#c47a2a"; font.pixelSize: 13; font.weight: Font.DemiBold }

                    Repeater {
                        id: modelRepeater
                        model: ListModel { id: modelListModel }
                        delegate: RowLayout {
                            Layout.fillWidth: true
                            spacing: 8

                            Text {
                                Layout.fillWidth: true
                                text: (model.current ? "● " : "○ ") + model.label + (model.installed ? "" : "  (not installed)")
                                color: model.current ? "#5dba5d" : "#aaaabb"
                                font.pixelSize: 12
                            }

                            Button {
                                text: model.installed ? (model.current ? "Active" : "Use") : "Install"
                                enabled: !(model.current) && popup.pullStatus !== "downloading"
                                implicitWidth: 70
                                onClicked: {
                                    if (model.installed) {
                                        popup.selectModel(model.modelId)
                                    } else {
                                        popup.installModel(model.modelId)
                                    }
                                }
                                background: Rectangle {
                                    color: parent.enabled ? "#2a2050" : "#1a1a20"
                                    radius: 5
                                }
                                contentItem: Text {
                                    text: parent.text
                                    color: parent.enabled ? "#c8b8f0" : "#555566"
                                    font.pixelSize: 11
                                    horizontalAlignment: Text.AlignHCenter
                                    verticalAlignment: Text.AlignVCenter
                                }
                            }
                        }
                    }

                    Text {
                        id: pullStatusText
                        Layout.fillWidth: true
                        visible: text !== ""
                        color: "#c4942a"
                        font.pixelSize: 11
                        wrapMode: Text.WordWrap
                    }

                    Rectangle { Layout.fillWidth: true; height: 1; color: "#2a2a3a" }

                    Text { text: "Unload model after closing"; color: "#c47a2a"; font.pixelSize: 13; font.weight: Font.DemiBold }

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 6

                        Repeater {
                            model: [
                                {label: "Immediately", val: 0},
                                {label: "10s", val: 10},
                                {label: "30s", val: 30},
                                {label: "2min", val: 120},
                                {label: "Never", val: -1}
                            ]
                            delegate: Button {
                                text: modelData.label
                                implicitWidth: 62
                                background: Rectangle {
                                    color: popup.unloadDelay === modelData.val ? "#3a2870" : "#1e1e28"
                                    radius: 5
                                }
                                contentItem: Text {
                                    text: parent.text
                                    color: popup.unloadDelay === modelData.val ? "#c8b8f0" : "#888899"
                                    font.pixelSize: 11
                                    horizontalAlignment: Text.AlignHCenter
                                    verticalAlignment: Text.AlignVCenter
                                }
                                onClicked: popup.setUnloadDelay(modelData.val)
                            }
                        }
                    }
                }
            }

            ColumnLayout {
                id: resultArea
                Layout.fillWidth: true
                visible: false
                spacing: 8

                Text {
                    id: sourceLabel
                    Layout.fillWidth: true
                    font.pixelSize: 11
                    color: "#8888aa"
                }

                RowLayout {
                    Layout.fillWidth: true
                    spacing: 10
                    Rectangle {
                        id: riskBadge
                        width: 70; height: 22; radius: 4
                        color: "#1a2e1a"; border.color: "#2d5a2d"
                        Text {
                            id: riskText
                            anchors.centerIn: parent
                            text: "LOW"; color: "#5dba5d"
                            font.pixelSize: 11; font.weight: Font.Bold
                        }
                    }
                    Rectangle {
                        Layout.fillWidth: true
                        height: 6; radius: 3; color: "#252530"
                        Rectangle {
                            id: riskBarFill
                            width: parent.width * 0.25
                            height: parent.height; radius: 3; color: "#3d8c3d"
                            Behavior on width { NumberAnimation { duration: 300 } }
                        }
                    }
                }

                Text {
                    id: riskReasonLabel
                    Layout.fillWidth: true
                    wrapMode: Text.WordWrap
                    color: "#666677"; font.pixelSize: 12
                }

                Rectangle { Layout.fillWidth: true; height: 1; color: "#2a2a3a" }

                Rectangle {
                    Layout.fillWidth: true
                    color: "#0e1a0e"; border.color: "#1e3a1e"; border.width: 1; radius: 6
                    implicitHeight: cmdText.implicitHeight + 16
                    TextEdit {
                        id: cmdText
                        anchors { left: parent.left; right: parent.right; top: parent.top; margins: 8 }
                        readOnly: true; selectByMouse: true; wrapMode: Text.WrapAnywhere
                        color: "#a8e0a8"
                        font.family: "JetBrains Mono, Fira Code, monospace"
                        font.pixelSize: 13
                    }
                }

                Text {
                    id: explanationLabel
                    Layout.fillWidth: true
                    wrapMode: Text.WordWrap
                    color: "#888899"; font.pixelSize: 13
                }

                RowLayout {
                    spacing: 8
                    Button {
                        id: copyBtn
                        text: "Copy command"
                        onClicked: { popup.copyText(cmdText.text); text = "Copied!"; copyTimer.restart() }
                        Timer { id: copyTimer; interval: 1500; onTriggered: copyBtn.text = "Copy command" }
                        background: Rectangle { color: copyBtn.hovered ? "#253525" : "#1e2e1e"; border.color: "#2d4a2d"; border.width: 1; radius: 6 }
                        contentItem: Text { text: copyBtn.text; color: "#5dba5d"; font.pixelSize: 12; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
                    }
                    Button {
                        id: workedBtn
                        text: "✓ This worked"
                        visible: false
                        onClicked: { popup.markWorked(); text = "✓ Saved!"; workedTimer.restart() }
                        Timer { id: workedTimer; interval: 2000; onTriggered: workedBtn.text = "✓ This worked" }
                        background: Rectangle { color: workedBtn.hovered ? "#223344" : "#1a2a3a"; border.color: "#2a4a6a"; border.width: 1; radius: 6 }
                        contentItem: Text { text: workedBtn.text; color: "#5a9fd4"; font.pixelSize: 12; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
                    }
                    Button {
                        id: failedBtn
                        text: "✗ Didn't work — retry"
                        visible: false
                        onClicked: { popup.markFailedAndRetry() }
                        background: Rectangle { color: failedBtn.hovered ? "#3a1f1f" : "#2a1515"; border.color: "#5a2a2a"; border.width: 1; radius: 6 }
                        contentItem: Text { text: failedBtn.text; color: "#d46a6a"; font.pixelSize: 12; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
                    }
                    Button {
                        id: undoBtn
                        text: "Copy undo"
                        visible: false
                        property string undoCmd: ""
                        onClicked: { popup.copyText(undoCmd); text = "Copied!"; undoTimer.restart() }
                        Timer { id: undoTimer; interval: 1500; onTriggered: undoBtn.text = "Copy undo" }
                        background: Rectangle { color: undoBtn.hovered ? "#352810" : "#2a2010"; border.color: "#4a3820"; border.width: 1; radius: 6 }
                        contentItem: Text { text: undoBtn.text; color: "#c49040"; font.pixelSize: 12; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
                    }
                }

                Rectangle {
                    id: snapshotFrame
                    Layout.fillWidth: true
                    visible: false
                    color: "#1a1000"; border.color: "#5a3a00"; border.width: 1; radius: 8
                    implicitHeight: snapCol.implicitHeight + 20
                    ColumnLayout {
                        id: snapCol
                        anchors { left: parent.left; right: parent.right; top: parent.top; margins: 10 }
                        spacing: 6
                        Text { text: "⚠️  High risk — consider a snapshot first:"; color: "#c4942a"; font.pixelSize: 12; font.weight: Font.DemiBold }
                        Rectangle {
                            Layout.fillWidth: true
                            color: "#0e0a00"; border.color: "#3a2a00"; border.width: 1; radius: 6
                            implicitHeight: snapCmdText.implicitHeight + 12
                            TextEdit {
                                id: snapCmdText
                                anchors { left: parent.left; right: parent.right; top: parent.top; margins: 6 }
                                readOnly: true; selectByMouse: true; wrapMode: Text.WrapAnywhere
                                color: "#e8c87a"
                                font.family: "JetBrains Mono, monospace"
                                font.pixelSize: 12
                            }
                        }
                        Button {
                            id: copySnapBtn
                            text: "Copy snapshot command"
                            onClicked: { popup.copyText(snapCmdText.text); text = "Copied!"; snapTimer.restart() }
                            Timer { id: snapTimer; interval: 1500; onTriggered: copySnapBtn.text = "Copy snapshot command" }
                            background: Rectangle { color: copySnapBtn.hovered ? "#3a2a00" : "#2a1e00"; border.color: "#5a3a00"; border.width: 1; radius: 6 }
                            contentItem: Text { text: copySnapBtn.text; color: "#c4942a"; font.pixelSize: 12; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
                        }
                    }
                }
            }
            } // end askTab

            // ── History tab ──────────────────────────────────────────────
            ColumnLayout {
                id: historyTab
                Layout.fillWidth: true
                visible: popup.activeTab === "history"
                spacing: 8

                Text {
                    text: "Last " + historyListModel.count + " queries"
                    color: "#8888aa"
                    font.pixelSize: 12
                }

                Repeater {
                    model: ListModel { id: historyListModel }
                    delegate: Rectangle {
                        Layout.fillWidth: true
                        color: "#12121a"
                        border.color: "#2a2a3a"
                        border.width: 1
                        radius: 8
                        implicitHeight: histCol.implicitHeight + 20

                        ColumnLayout {
                            id: histCol
                            anchors { left: parent.left; right: parent.right; top: parent.top; margins: 10 }
                            spacing: 6

                            Text {
                                Layout.fillWidth: true
                                text: model.question
                                color: "#d4d4e8"
                                font.pixelSize: 13
                                font.weight: Font.DemiBold
                                wrapMode: Text.WordWrap
                            }

                            Rectangle {
                                Layout.fillWidth: true
                                color: "#0e1a0e"
                                border.color: "#1e3a1e"
                                border.width: 1
                                radius: 6
                                implicitHeight: histCmdText.implicitHeight + 12

                                TextEdit {
                                    id: histCmdText
                                    anchors { left: parent.left; right: parent.right; top: parent.top; margins: 6 }
                                    readOnly: true
                                    selectByMouse: true
                                    wrapMode: Text.WrapAnywhere
                                    text: model.command
                                    color: "#a8e0a8"
                                    font.family: "JetBrains Mono, monospace"
                                    font.pixelSize: 12
                                }
                            }

                            RowLayout {
                                Layout.fillWidth: true
                                spacing: 6

                                Button {
                                    text: "Copy"
                                    implicitWidth: 56
                                    onClicked: popup.copyText(model.command)
                                    background: Rectangle { color: "#1e2e1e"; border.color: "#2d4a2d"; border.width: 1; radius: 5 }
                                    contentItem: Text { text: "Copy"; color: "#5dba5d"; font.pixelSize: 11; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
                                }

                                Item { Layout.fillWidth: true }

                                // Feedback indicator / buttons
                                Text {
                                    visible: model.feedback === "worked"
                                    text: "✓ Worked"
                                    color: "#5dba5d"
                                    font.pixelSize: 11
                                }
                                Text {
                                    visible: model.feedback === "failed"
                                    text: "✗ Didn't work"
                                    color: "#d46a6a"
                                    font.pixelSize: 11
                                }

                                Button {
                                    visible: model.feedback === ""
                                    text: "✓ Worked"
                                    implicitWidth: 70
                                    onClicked: popup.setHistoryFeedback(model.histId, "worked", index)
                                    background: Rectangle { color: "#1a2a3a"; border.color: "#2a4a6a"; border.width: 1; radius: 5 }
                                    contentItem: Text { text: "✓ Worked"; color: "#5a9fd4"; font.pixelSize: 11; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
                                }
                                Button {
                                    visible: model.feedback === ""
                                    text: "✗ Failed"
                                    implicitWidth: 64
                                    onClicked: popup.setHistoryFeedback(model.histId, "failed", index)
                                    background: Rectangle { color: "#2a1515"; border.color: "#5a2a2a"; border.width: 1; radius: 5 }
                                    contentItem: Text { text: "✗ Failed"; color: "#d46a6a"; font.pixelSize: 11; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
                                }
                            }
                        }
                    }
                }

                Text {
                    visible: historyListModel.count === 0
                    text: "No history yet — ask something first."
                    color: "#555566"
                    font.pixelSize: 12
                }
            }
            } // end mainCol ColumnLayout
        } // end ScrollView
    }
}
