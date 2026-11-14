import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Model.js" as Model

// Clash Verge bar widget: a globe glyph that dims when the core is offline,
// a compact live rate in the bar, and a keyboard panel over the whole core —
// mode, TUN, proxy groups, traffic, DNS health, and two one-shot tools.
Panel {
  id: root

  moduleName: "punkmonday.clash"
  ipcTarget: "punkmonday.clash"

  Commons.Translations { id: strings; directory: Qt.resolvedUrl("i18n") }

  readonly property color foreground: bar ? bar.foreground : Commons.Color.foreground
  readonly property color urgent: bar ? bar.urgent : Commons.Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  // Bar glyphs follow barForeground (the bar's own contrast-adjusted color,
  // what the neighbours use), while panel content uses the theme foreground.
  readonly property color barIconColor: !clash.reachable
    ? Qt.darker(barForeground, 1.9)
    : (clash.tunEnabled ? barForeground : Qt.darker(barForeground, 1.35))
  readonly property string modeLabel: strings.t("clash.mode." + clash.mode)

  // Flattened cursor over the interactive controls: TUN, mode, each proxy
  // group, then the three tool buttons.
  // Items inside the panel's lazily built content, null until it first
  // opens.
  readonly property Item panelFlick: panel.loadedContent ? panel.loadedContent.panelFlick : null

  property bool cursorActive: false
  property int cursor: 0
  readonly property int controlCount: 5 + clash.groups.length
  readonly property int groupsCursorTop: 2

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  function activateCursor() {
    cursorActive = true
    if (cursor === 0) {
      clash.toggleTun()
      return
    }
    if (cursor === 1) {
      clash.refreshStatus()
      return
    }
    var groupIndex = cursor - groupsCursorTop
    if (groupIndex < clash.groups.length) {
      var dropdown = groupsRepeater.itemAt(groupIndex)
      if (dropdown) dropdown.toggle()
      return
    }
    var toolIndex = groupIndex - clash.groups.length
    if (toolIndex === 0) flushButton.clicked()
    else if (toolIndex === 1) vergeButton.clicked()
    else if (toolIndex === 2) refreshButton.clicked()
  }

  function moveCursor(dx, dy) {
    if (dy !== 0) {
      cursorActive = true
      cursor = (cursor + dy + controlCount) % controlCount
      return
    }
    // Left/Right only drive something on the mode row: they cycle the core
    // through rule → global → direct without opening a popup.
    if (dx !== 0 && cursorActive && cursor === 1) {
      var index = Model.MODES.indexOf(clash.mode)
      if (index === -1) index = 0
      clash.setMode(Model.MODES[(index + dx + Model.MODES.length) % Model.MODES.length])
    }
  }

  // While any group popup is open the whole key catcher forwards keys, so
  // the popup's own Esc/Enter/arrow handling stays intact.
  property bool anyPopupOpen: false
  function updatePopupBlock() {
    var open = false
    for (var i = 0; i < groupsRepeater.count; i++) {
      var item = groupsRepeater.itemAt(i)
      if (item && item.popupOpen) {
        open = true
        break
      }
    }
    anyPopupOpen = open
  }

  function formatValue(parts) {
    return Commons.I18n.formatNumber(parts.value, parts.digits) + " " + parts.unit
  }

  onOpenedChanged: if (opened) {
    cursorActive = false
    cursor = 0
    if (panelFlick) panelFlick.contentY = 0
    clash.refreshNow()
    Qt.callLater(function() { if (panel.loadedContent) panel.loadedContent.forceActiveFocus() })
  }

  Service {
    id: clash
    settings: root.settings
    trafficWanted: root.opened
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    iconComponent: Component {
      Item {
        ClashText {
          x: (parent.width - width) / 2
          y: (parent.height - height) / 2
          // mdi-web: the fine wireframe globe, matched to the weight of the
          // neighbouring line-style bar glyphs.
          text: "󰖙"
          font.pixelSize: button.iconSize
          color: root.barIconColor
        }
      }
    }
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton) clash.toggleTun()
      else if (buttonCode === Qt.MiddleButton) clash.refreshNow()
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: panel.loadedContent
    contentWidth: panel.fittedContentWidth(Style.space(360))
    contentHeight: panel.fittedContentHeight(panel.loadedContentHeight, Style.space(580))

    content: PanelKeyCatcher {
      id: keyCatcher
      property alias panelFlick: panelFlick
      anchors.fill: parent
      blocked: root.anyPopupOpen
      implicitHeight: column.implicitHeight
      onMoveRequested: function(dx, dy) { root.moveCursor(dx, dy) }
      onActivateRequested: root.activateCursor()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(text) {
        if (text === "t" || text === "T") clash.toggleTun()
        else if (text === "r" || text === "R") clash.refreshNow()
        else if (text === "1") clash.setMode("rule")
        else if (text === "2") clash.setMode("global")
        else if (text === "3") clash.setMode("direct")
      }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: panelFlick.width
          spacing: Style.space(12)

          Item {
            id: header
            width: parent.width
            implicitHeight: hero.implicitHeight
            // Exposed for the hero's trailingControl, whose `root` resolves to
            // PanelHero rather than this panel.
            readonly property bool ringVisible: root.cursorActive && root.cursor === 0

            PanelHero {
              id: hero
              width: parent.width
              title: strings.t("clash.title")
              meta: clash.reachable
                ? strings.t("clash.mihomo").arg(clash.coreVersion || "?") + " · " + root.modeLabel
                : strings.t("clash.offline")
              detail: clash.reachable && clash.mixedPort > 0
                ? strings.t("clash.mixedPort").arg(Commons.I18n.formatNumber(clash.mixedPort))
                : ""
              foreground: root.foreground
              fontFamily: root.fontFamily
              iconOpacity: clash.reachable ? 1.0 : 0.5
              iconComponent: Component {
                ClashText {
                  text: "󰖙"
                  font.pixelSize: Style.font.display
                  color: clash.reachable ? root.foreground : root.dim
                }
              }

              trailingControl: Component {
                ToggleSwitch {
                  checked: clash.tunEnabled
                  busy: clash.busy
                  hasCursor: header.ringVisible
                  foreground: hero.foreground
                  onToggled: clash.toggleTun()
                }
              }
            }
          }

          Item {
            visible: clash.lastError !== ""
            width: parent.width
            height: visible ? errorText.implicitHeight : 0
            ClashText {
              id: errorText
              width: parent.width
              text: clash.lastError
              color: root.urgent
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }
          }

          Item {
            width: parent.width
            implicitHeight: modeColumn.implicitHeight
            Column {
              id: modeColumn
              width: parent.width
              spacing: Style.space(6)
              PanelSectionHeader {
                text: strings.t("clash.section.mode")
                foreground: root.foreground
                fontFamily: root.fontFamily
              }
              ButtonGroup {
                width: parent.width
                options: [
                  { value: "rule", label: strings.t("clash.mode.rule") },
                  { value: "global", label: strings.t("clash.mode.global") },
                  { value: "direct", label: strings.t("clash.mode.direct") }
                ]
                value: clash.mode
                foreground: root.foreground
                fontFamily: root.fontFamily
                cursorIndex: root.cursorActive && root.cursor === 1
                  ? Math.max(0, Model.MODES.indexOf(clash.mode))
                  : -1
                onChanged: function(next) { clash.setMode(next) }
              }
            }
          }

          Item {
            width: parent.width
            implicitHeight: proxiesColumn.implicitHeight
            Column {
              id: proxiesColumn
              width: parent.width
              spacing: Style.space(6)
              PanelSectionHeader {
                text: strings.t("clash.section.proxies")
                foreground: root.foreground
                fontFamily: root.fontFamily
              }
              ClashText {
                visible: clash.reachable && clash.groups.length === 0
                width: parent.width
                text: strings.t("clash.noGroups")
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
              Repeater {
                id: groupsRepeater
                model: clash.groups
                delegate: Dropdown {
                  id: dropdown
                  width: proxiesColumn.width
                  label: modelData.auto
                    ? modelData.name + " · " + strings.t("clash.auto")
                    : modelData.name
                  value: modelData.now
                  options: modelData.all
                  showLabel: true
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  hasCursor: root.cursorActive && root.cursor === root.groupsCursorTop + index
                  onChanged: function(next) { clash.selectProxy(modelData.name, next) }
                  Connections {
                    target: dropdown
                    function onPopupOpenChanged() { root.updatePopupBlock() }
                  }
                }
              }
            }
          }

          Item {
            width: parent.width
            implicitHeight: trafficColumn.implicitHeight
            Column {
              id: trafficColumn
              width: parent.width
              spacing: Style.space(4)

              PanelSectionHeader {
                text: strings.t("clash.section.traffic")
                foreground: root.foreground
                fontFamily: root.fontFamily
              }

              RowLayout {
                width: parent.width
                spacing: Style.space(8)
                ClashText {
                  Layout.fillWidth: true
                  text: strings.t("clash.traffic.down")
                  color: root.dim
                  font.family: root.fontFamily
                }
                ClashText {
                  Layout.alignment: Qt.AlignRight
                  text: clash.reachable ? root.formatValue(Model.rate(clash.downBps)) : ""
                  color: root.foreground
                  font.family: root.fontFamily
                }
              }

              RowLayout {
                width: parent.width
                spacing: Style.space(8)
                ClashText {
                  Layout.fillWidth: true
                  text: strings.t("clash.traffic.up")
                  color: root.dim
                  font.family: root.fontFamily
                }
                ClashText {
                  Layout.alignment: Qt.AlignRight
                  text: clash.reachable ? root.formatValue(Model.rate(clash.upBps)) : ""
                  color: root.foreground
                  font.family: root.fontFamily
                }
              }

              RowLayout {
                width: parent.width
                spacing: Style.space(8)
                ClashText {
                  Layout.fillWidth: true
                  text: strings.t("clash.traffic.received")
                  color: root.dim
                  font.family: root.fontFamily
                }
                ClashText {
                  Layout.alignment: Qt.AlignRight
                  text: clash.reachable ? root.formatValue(Model.bytes(clash.downloadTotal)) : ""
                  color: root.foreground
                  font.family: root.fontFamily
                }
              }

              RowLayout {
                width: parent.width
                spacing: Style.space(8)
                ClashText {
                  Layout.fillWidth: true
                  text: strings.t("clash.traffic.sent")
                  color: root.dim
                  font.family: root.fontFamily
                }
                ClashText {
                  Layout.alignment: Qt.AlignRight
                  text: clash.reachable ? root.formatValue(Model.bytes(clash.uploadTotal)) : ""
                  color: root.foreground
                  font.family: root.fontFamily
                }
              }

              ClashText {
                width: parent.width
                visible: clash.reachable && clash.connectionsCount > 0
                text: clash.connectionsCount > 0
                  ? strings.tn("clash.traffic.activeConnections", clash.connectionsCount)
                      .arg(Commons.I18n.formatNumber(clash.connectionsCount))
                  : ""
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }

              Column {
                width: parent.width
                spacing: 0
                visible: clash.reachable && clash.topConnections.length > 0
                PanelSectionHeader {
                  text: strings.t("clash.section.top")
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                }
                Repeater {
                  model: clash.topConnections
                  delegate: RowLayout {
                    width: trafficColumn.width
                    spacing: Style.space(8)
                    ClashText {
                      Layout.fillWidth: true
                      text: modelData.port !== "" ? modelData.host + ":" + modelData.port : modelData.host
                      elide: Text.ElideMiddle
                      color: root.dim
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                    }
                    ClashText {
                      Layout.maximumWidth: Style.space(140)
                      text: modelData.proxy
                      elide: Text.ElideLeft
                      horizontalAlignment: Text.AlignRight
                      color: root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                    }
                  }
                }
              }
            }
          }

          Item {
            width: parent.width
            implicitHeight: dnsColumn.implicitHeight
            Column {
              id: dnsColumn
              width: parent.width
              spacing: Style.space(6)
              PanelSectionHeader {
                text: strings.t("clash.section.dns")
                foreground: root.foreground
                fontFamily: root.fontFamily
              }
              RowLayout {
                width: parent.width
                spacing: Style.space(8)
                ClashText {
                  text: "●"
                  color: clash.dnsState === "ok" ? root.foreground
                    : (clash.dnsState === "empty" || clash.dnsState === "failed" ? root.urgent : root.dim)
                  font.pixelSize: Style.font.caption
                }
                ClashText {
                  Layout.fillWidth: true
                  text: clash.dnsState === "ok"
                    ? strings.tn("clash.dns.ok", clash.dnsAnswers)
                        .arg(Commons.I18n.formatNumber(clash.dnsAnswers)).arg(clash.dnsProbeName)
                    : (clash.dnsState === "empty" ? strings.t("clash.dns.empty")
                        : clash.dnsState === "failed" ? strings.t("clash.dns.failed")
                          : strings.t("clash.dns.unknown"))
                  elide: Text.ElideRight
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }
              }
            }
          }

          Item {
            width: parent.width
            implicitHeight: toolsRow.implicitHeight
            Column {
              width: parent.width
              spacing: Style.space(6)
              PanelSectionHeader {
                text: strings.t("clash.section.tools")
                foreground: root.foreground
                fontFamily: root.fontFamily
              }
              RowLayout {
                id: toolsRow
                width: parent.width
                spacing: Style.space(8)
                Button {
                  id: flushButton
                  Layout.fillWidth: true
                  text: strings.t("clash.tool.flush")
                  bordered: true
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  hasCursor: root.cursorActive && root.cursor === root.groupsCursorTop + clash.groups.length
                  onClicked: clash.flushFakeIp()
                }
                Button {
                  id: vergeButton
                  Layout.fillWidth: true
                  text: strings.t("clash.tool.verge")
                  bordered: true
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  hasCursor: root.cursorActive && root.cursor === root.groupsCursorTop + clash.groups.length + 1
                  onClicked: clash.openVerge()
                }
                Button {
                  id: refreshButton
                  Layout.fillWidth: true
                  text: strings.t("clash.tool.refresh")
                  bordered: true
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  hasCursor: root.cursorActive && root.cursor === root.groupsCursorTop + clash.groups.length + 2
                  onClicked: clash.refreshNow()
                }
              }
            }
          }
        }
      }
    }
  }
}
