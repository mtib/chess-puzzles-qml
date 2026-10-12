import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Chess puzzle panel: one Lichess puzzle at a time, played by clicking a
// piece and a destination. The puzzle's solution list is the only judge of
// what a move is — the opponent's replies are played automatically, so the
// board never needs a move generator.
Panel {
  id: root
  moduleName: "mtib.chesspuzzles"
  ipcTarget: "mtib.chesspuzzles"
  manageIpc: false

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property color accent: Color.accent
  readonly property color surface: Color.popups.background
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // Monochrome dark board: fixed palette, dark-mode only by design.
  readonly property color boardBackground: "#0e0e10"
  readonly property color boardHatch: "#3c3d44"    // diagonal hatch on light squares
  readonly property color boardGrid: "#45464e"       // dashed cell outlines
  readonly property color boardMove: "#e8890c"       // orange: moved / selected squares
  readonly property color boardMoveFill: Qt.rgba(0.91, 0.54, 0.05, 0.42)
  readonly property color boardWrong: "#c94f3d"

  // Nominal cell size drives the requested card width; the real cell size
  // clamps to the card's actual content width once laid out, so the board
  // can never overflow the card no matter how much inset the theme's
  // padding, borders, and corners eat.
  readonly property real baseCellSize: Style.space(38)
  property real cellSize: baseCellSize

  // ------------------------------------------------------------------ state

  property int targetElo: setting("elo", 1500)
  property int solvedCount: 0

  property var puzzle: null
  property int fetchRetries: 0
  property var board: []
  property string userColor: "w"   // side the player moves, from the FEN
  property int step: 0            // index into puzzle.solution
  property int selected: -1
  property int tries: 0
  property int wrongFlash: -1     // square index flashing red
  property int lastMoveFrom: -1
  property int lastMoveTo: -1

  // Arrow shown while a piece moves: origin/destination board indices plus a
  // fading alpha driven by a timer + Behavior so the canvas repaints smoothly.
  property var arrow: null
  property real arrowAlpha: 0.0

  // "loading" | "play" | "replying" | "won" | "revealed"
  property string phase: "loading"
  property string statusLine: "Fetching puzzle…"

  readonly property bool inputAllowed: phase === "play"
  readonly property var solution: puzzle ? puzzle.solution : []

  function open() {
    controller.show()
    if (!puzzle) fetchPuzzle()
  }

  function close() {
    controller.hide()
    solutionTimer.stop()
    replyTimer.stop()
  }

  function toggle() {
    opened ? close() : open()
  }

  function switchPanel(direction) {
    if (bar && typeof bar.switchPanelFrom === "function")
      return bar.switchPanelFrom(root, direction)
    return false
  }

  // ---------------------------------------------------------------- puzzles

  function fetchPuzzle() {
    phase = "loading"
    statusLine = "Fetching puzzle…"
    selected = -1
    wrongFlash = -1
    lastMoveFrom = -1
    lastMoveTo = -1
    fetchError = ""
    fetchProc.command = [
      Quickshell.env("HOME") + "/.config/omarchy/plugins/mtib.chesspuzzles/pick.sh",
      String(targetElo)
    ]
    fetchProc.running = true
  }

  property string fetchError: ""

  function fetchFailed() {
    phase = "idle"
    statusLine = fetchError !== "" ? fetchError : "Could not get a puzzle"
    // A missing cache won't fix itself, so only retry other failures.
    if (fetchError === "" && fetchRetries < 3) {
      fetchRetries++
      retryTimer.restart()
    }
  }

  function startPuzzle(record) {
    fetchRetries = 0
    var parsedFen = Model.parseFen(record.fen)
    puzzle = record
    board = parsedFen.board
    userColor = parsedFen.turn
    step = 0
    tries = 0
    selected = -1
    wrongFlash = -1
    lastMoveFrom = -1
    lastMoveTo = -1
    userArrows = []
    dragArrowFrom = -1
    dragArrowTo = -1
    phase = "play"
    statusLine = Model.sideName(userColor) + " to play — find the best move"
  }

  // Show an orange arrow for a move, then fade it out.
  function showArrow(from, to) {
    arrow = { from: from, to: to }
    arrowAlpha = 1.0
    arrowFade.restart()
  }

  function setElo(value) {
    var elo = Math.max(600, Math.min(2500, Math.round(value)))
    if (elo === targetElo) return
    targetElo = elo
    saveState()
    fetchPuzzle()
  }

  // Play the user's attempted move from->to against the expected solution
  // step. A promotion is accepted on its first four characters.
  function attemptMove(from, to) {
    if (!inputAllowed || !puzzle) return
    var uci = Model.indexToSquare(from) + Model.indexToSquare(to)
    var expected = solution[step] || ""

    if (expected.slice(0, 4) !== uci) {
      tries++
      wrongFlash = to
      flashTimer.restart()
      statusLine = "Not the move — try again"
      selected = -1
      return
    }

    board = Model.applyUci(board, expected)
    lastMoveFrom = from
    lastMoveTo = to
    showArrow(from, to)
    selected = -1
    step++

    if (step >= solution.length) {
      phase = "won"
      solvedCount++
      saveState()
      statusLine = tries === 0
        ? "Solved! Clean solve 🎉"
        : "Solved! (" + tries + " wrong " + (tries === 1 ? "try" : "tries") + ")"
      return
    }

    // The opponent's reply is played for you, then it's your move again.
    phase = "replying"
    statusLine = "Correct! Opponent replies…"
    replyTimer.restart()
  }

  function playReply() {
    if (!puzzle || step >= solution.length) return
    var move = solution[step]
    board = Model.applyUci(board, move)
    var replyFrom = Model.squareToIndex(move.slice(0, 2))
    var replyTo = Model.squareToIndex(move.slice(2, 4))
    lastMoveFrom = replyFrom
    lastMoveTo = replyTo
    showArrow(replyFrom, replyTo)
    step++
    if (step >= solution.length) {
      // Solution ended on the opponent's move (checkmate was delivered).
      phase = "won"
      solvedCount++
      saveState()
      statusLine = "Solved! 🎉"
    } else {
      phase = "play"
      statusLine = Model.sideName(userColor) + " to play"
    }
  }

  function showSolution() {
    if (!puzzle) return
    solutionTimer.stop()
    phase = "revealed"
    statusLine = "Solution"
    solutionTimer.restart()
  }

  function playSolutionStep() {
    if (!puzzle || step >= solution.length) return
    var move = solution[step]
    board = Model.applyUci(board, move)
    var solFrom = Model.squareToIndex(move.slice(0, 2))
    var solTo = Model.squareToIndex(move.slice(2, 4))
    lastMoveFrom = solFrom
    lastMoveTo = solTo
    showArrow(solFrom, solTo)
    step++
    if (step < solution.length) solutionTimer.restart()
    else statusLine = "Puzzle " + (puzzle.id || "") + " revealed"
  }

  // Arrows drawn by the user (shift+drag on the board): {from, to} board
  // indices, plus the live drag preview.
  property var userArrows: []
  property int dragArrowFrom: -1
  property int dragArrowTo: -1

  function clickSquare(index) {
    if (!inputAllowed) return
    // A plain click on an empty square clears the drawn arrows.
    if ((board[index] || "") === "") userArrows = []
    if (selected === -1) {
      var piece = board[index] || ""
      if (piece !== "" && piece[1] === userColor) selected = index
      return
    }
    if (index === selected) {
      selected = -1
      return
    }
    attemptMove(selected, index)
  }

  // ------------------------------------------------------------ persistence

  function statePath() {
    return Quickshell.env("HOME") + "/.local/state/omarchy/settings/chesspuzzles.json"
  }

  function saveState() {
    var payload = JSON.stringify({ elo: targetElo, solvedCount: solvedCount })
    saveProc.command = ["sh", "-c",
      "mkdir -p \"$(dirname '" + statePath() + "')\" && printf '%s' " +
      JSON.stringify(payload) + " > '" + statePath() + "'"]
    saveProc.running = true
  }

  function loadState(raw) {
    try {
      var parsed = JSON.parse(String(raw || ""))
      if (Number(parsed.elo) >= 600 && Number(parsed.elo) <= 2500) targetElo = Number(parsed.elo)
      if (Number(parsed.solvedCount) > 0) solvedCount = Number(parsed.solvedCount)
    } catch (e) {}
  }

  // -------------------------------------------------------------- processes

  Process {
    id: fetchProc
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.fetchError = String(text || "").trim().split("\n")[0]
    }
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var record = Model.parsePuzzle(String(text || ""))
        if (!record) {
          root.fetchFailed()
          return
        }
        root.startPuzzle(record)
      }
    }
  }

  Process { id: saveProc }

  property FileView stateFile: FileView {
    path: root.statePath()
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.loadState(text())
    onLoadFailed: root.loadState("")
  }

  Timer { id: replyTimer; interval: 650; onTriggered: root.playReply() }
  Timer { id: retryTimer; interval: 4000; onTriggered: root.fetchPuzzle() }
  Timer { id: arrowFade; interval: 900; onTriggered: root.arrowAlpha = 0 }

  Behavior on arrowAlpha {
    NumberAnimation { duration: 500; easing.type: Easing.OutQuad }
  }
  Timer {
    id: solutionTimer
    interval: 650
    onTriggered: root.playSolutionStep()
  }
  Timer { id: flashTimer; interval: 450; onTriggered: root.wrongFlash = -1 }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onOpenedChanged: if (opened) {
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
    if (puzzle && phase !== "loading") {
      // Returning to a live puzzle: keep its phase, just refresh the prompt.
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    iconComponent: Component {
      Image {
        anchors.centerIn: parent
        width: Style.bar.iconCanvas
        height: Style.bar.iconCanvas
        fillMode: Image.PreserveAspectFit
        smooth: true
        source: Qt.resolvedUrl("pieces/nw.svg")
      }
    }
    onPressed: function(buttonCode) { root.toggle() }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    centerOnBar: false
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(
      root.baseCellSize * 8 + panel.padding * 2 + Style.space(2))
    contentHeight: panel.fittedContentHeight(contentColumn.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTextKey: function(t) {
        if (t === "n" || t === "N") root.fetchPuzzle()
        else if (t === "s" || t === "S") root.showSolution()
        else if (t === "f" || t === "F") root.userColor = root.userColor === "w" ? "b" : "w"
      }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        onWidthChanged: {
          // Integer cells so nothing snaps: each cell renders on whole pixels
          // and the frame is exactly cells*8, so the dark frame color can
          // never peek past the last row or column. The card's leftover
          // fractional width shows as symmetric card padding instead.
          if (width > 0) root.cellSize = Math.floor(width / 8)
        }
        contentWidth: width
        contentHeight: contentColumn.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height

        ColumnLayout {
          id: contentColumn
            width: panelFlick.width
          spacing: Style.space(10)

          // ---- header + difficulty picker
          RowLayout {
            Layout.fillWidth: true
            spacing: Style.space(8)

            Text {
              text: "Chess Puzzles"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.heading
              Layout.fillWidth: true
            }

            Text {
              visible: root.solvedCount > 0
              text: root.solvedCount + " solved"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }

          // ---- target ELO slider
          RowLayout {
            Layout.fillWidth: true
            spacing: Style.space(8)

            Text {
              text: "Puzzle ELO"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }

            Text {
              text: root.targetElo
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              Layout.alignment: Qt.AlignRight
            }
          }

          PanelSlider {
            Layout.fillWidth: true
            bar: root.bar
            minimum: 600
            maximum: 2500
            step: 50
            integer: true
            value: root.targetElo
            onReleased: function(v) { root.setElo(v) }
          }

          // ---- board: monochrome canvas + transparent interaction grid
          Rectangle {
            id: boardFrame
            Layout.alignment: Qt.AlignHCenter
            implicitWidth: root.cellSize * 8
            implicitHeight: root.cellSize * 8
            color: root.boardBackground

            Canvas {
              id: boardCanvas
              anchors.fill: parent

              Component.onCompleted: requestPaint()

              // Repaint whenever any painted state changes.
              Connections {
                target: root
                function onCellSizeChanged() { boardCanvas.requestPaint() }
                function onUserColorChanged() { boardCanvas.requestPaint() }
                function onSelectedChanged() { boardCanvas.requestPaint() }
                function onWrongFlashChanged() { boardCanvas.requestPaint() }
                function onLastMoveFromChanged() { boardCanvas.requestPaint() }
                function onLastMoveToChanged() { boardCanvas.requestPaint() }
                function onUserArrowsChanged() { boardCanvas.requestPaint() }
                function onDragArrowFromChanged() { boardCanvas.requestPaint() }
                function onDragArrowToChanged() { boardCanvas.requestPaint() }
                function onArrowChanged() { boardCanvas.requestPaint() }
                function onArrowAlphaChanged() { boardCanvas.requestPaint() }
              }

              // Screen-space center of a board index, honoring orientation.
              function centerOf(boardIndex) {
                var row = Math.floor(boardIndex / 8)
                var file = boardIndex % 8
                var sr = root.userColor === "b" ? 7 - row : row
                var sf = root.userColor === "b" ? 7 - file : file
                return Qt.point((sf + 0.5) * root.cellSize, (sr + 0.5) * root.cellSize)
              }

              onPaint: {
                var ctx = getContext("2d")
                var cell = root.cellSize
                if (cell <= 0) return
                ctx.clearRect(0, 0, width, height)
                ctx.fillStyle = root.boardBackground
                ctx.fillRect(0, 0, width, height)

                // Involved squares first: selection, wrong attempt, and the
                // last move's from/to, all orange.
                var orange = [root.lastMoveFrom, root.lastMoveTo]
                for (var i = 0; i < 64; i++) {
                  var isOrange = orange.indexOf(i) >= 0
                  var isSelected = root.selected === i
                  var isWrong = root.wrongFlash === i
                  if (!isOrange && !isSelected && !isWrong) continue
                  var p = centerOf(i)
                  ctx.fillStyle = isWrong ? Qt.rgba(0.79, 0.31, 0.24, 0.55)
                    : isSelected ? Qt.rgba(0.91, 0.54, 0.05, 0.30)
                    : root.boardMoveFill
                  ctx.fillRect(p.x - cell / 2, p.y - cell / 2, cell, cell)
                }

                // Diagonal hatching on the light squares: clipped 45° lines.
                ctx.save()
                ctx.strokeStyle = root.boardHatch
                ctx.lineWidth = 1
                for (var row = 0; row < 8; row++) {
                  for (var file = 0; file < 8; file++) {
                    if ((row + file) % 2 !== 0) continue
                    var x = file * cell
                    var y = row * cell
                    ctx.save()
                    ctx.beginPath()
                    ctx.rect(x, y, cell, cell)
                    ctx.clip()
                    ctx.beginPath()
                    for (var d = -cell; d < cell + cell; d += 5) {
                      ctx.moveTo(x + d, y + cell)
                      ctx.lineTo(x + d + cell, y)
                    }
                    ctx.stroke()
                    ctx.restore()
                  }
                }
                ctx.restore()

                // Dashed cell outlines over everything.
                ctx.strokeStyle = root.boardGrid
                ctx.lineWidth = 1
                ctx.setLineDash([4, 3])
                ctx.beginPath()
                for (var g = 0; g <= 8; g++) {
                  ctx.moveTo(g * cell, 0)
                  ctx.lineTo(g * cell, height)
                  ctx.moveTo(0, g * cell)
                  ctx.lineTo(width, g * cell)
                }
                ctx.stroke()
                ctx.setLineDash([])

                // One arrow drawing path, shared by user arrows, the drag
                // preview, and automatic move arrows.
                function drawArrow(fromIdx, toIdx, color, alpha) {
                  var from = centerOf(fromIdx)
                  var to = centerOf(toIdx)
                  var dx = to.x - from.x
                  var dy = to.y - from.y
                  var len = Math.sqrt(dx * dx + dy * dy)
                  if (len <= 1) return
                  var head = Math.max(6, root.cellSize * 0.3)
                  var ux = dx / len
                  var uy = dy / len
                  var tipX = to.x - ux * (root.cellSize * 0.34)
                  var tipY = to.y - uy * (root.cellSize * 0.34)
                  var shaftX = tipX - ux * head
                  var shaftY = tipY - uy * head
                  ctx.save()
                  ctx.globalAlpha = alpha
                  ctx.strokeStyle = color
                  ctx.fillStyle = color
                  ctx.lineWidth = Math.max(2, root.cellSize * 0.09)
                  ctx.beginPath()
                  ctx.moveTo(from.x, from.y)
                  ctx.lineTo(shaftX, shaftY)
                  ctx.stroke()
                  ctx.beginPath()
                  ctx.moveTo(tipX, tipY)
                  ctx.lineTo(shaftX - uy * head * 0.45, shaftY + ux * head * 0.45)
                  ctx.lineTo(shaftX + uy * head * 0.45, shaftY - ux * head * 0.45)
                  ctx.closePath()
                  ctx.fill()
                  ctx.restore()
                }

                // User-drawn arrows: shift+drag on the board.
                for (var a = 0; a < root.userArrows.length; a++) {
                  drawArrow(root.userArrows[a].from, root.userArrows[a].to,
                    root.foreground, 0.85)
                }
                // Live preview while the drag is in progress.
                if (root.dragArrowFrom >= 0 && root.dragArrowTo >= 0
                    && root.dragArrowTo !== root.dragArrowFrom) {
                  drawArrow(root.dragArrowFrom, root.dragArrowTo,
                    root.foreground, 0.6)
                }

                // Automatic move arrow: origin -> destination, fading out.
                if (root.arrow && root.arrowAlpha > 0.01) {
                  drawArrow(root.arrow.from, root.arrow.to,
                    root.boardMove, root.arrowAlpha)
                }
              }
            }

            Grid {
              anchors.fill: parent
              columns: 8

              Repeater {
                model: 64

                delegate: Rectangle {
                  required property int index
                  readonly property int row: Math.floor(index / 8)
                  readonly property int file: index % 8
                  // Flip so the side to move sits at the bottom.
                  readonly property int boardIndex: root.userColor === "b"
                    ? (7 - row) * 8 + (7 - file)
                    : index
                  readonly property string piece: root.board.length === 64
                    ? root.board[boardIndex] : ""

                  // The canvas owns all cell painting; cells stay transparent.
                  color: "transparent"
                  width: root.cellSize
                  height: root.cellSize

                  Image {
                    visible: parent.piece !== ""
                    anchors.centerIn: parent
                    width: parent.width * 0.92
                    height: parent.height * 0.92
                    fillMode: Image.PreserveAspectFit
                    smooth: true
                    source: parent.piece !== ""
                      ? Qt.resolvedUrl("pieces/" + parent.piece + ".svg")
                      : ""
                  }
                }
              }
            }

            // One mouse area over the whole board: plain press plays/clears,
            // shift+drag draws an arrow from square to square.
            MouseArea {
              id: boardMouse
              anchors.fill: parent
              hoverEnabled: true
              acceptedButtons: Qt.LeftButton
              cursorShape: root.dragArrowFrom >= 0 ? Qt.CrossCursor
                : root.inputAllowed ? Qt.PointingHandCursor : Qt.ArrowCursor

              function cellAt(x, y) {
                var col = Math.min(7, Math.max(0, Math.floor(x / root.cellSize)))
                var row = Math.min(7, Math.max(0, Math.floor(y / root.cellSize)))
                return root.userColor === "b" ? (7 - row) * 8 + (7 - col) : row * 8 + col
              }

              onPressed: function(mouse) {
                if (mouse.modifiers & Qt.ShiftModifier) {
                  root.dragArrowFrom = cellAt(mouse.x, mouse.y)
                  root.dragArrowTo = root.dragArrowFrom
                } else {
                  root.clickSquare(cellAt(mouse.x, mouse.y))
                }
              }
              onPositionChanged: {
                if (root.dragArrowFrom >= 0)
                  root.dragArrowTo = cellAt(mouseX, mouseY)
              }
              onReleased: {
                if (root.dragArrowFrom >= 0) {
                  if (root.dragArrowTo !== root.dragArrowFrom && root.dragArrowTo >= 0) {
                    var next = root.userArrows.slice()
                    next.push({ from: root.dragArrowFrom, to: root.dragArrowTo })
                    root.userArrows = next
                  }
                  root.dragArrowFrom = -1
                  root.dragArrowTo = -1
                }
              }
            }
          }

          // ---- status line
          Text {
            Layout.alignment: Qt.AlignHCenter
            text: root.statusLine
            color: root.phase === "won" ? root.accent : root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
          }

          // ---- actions
          RowLayout {
            Layout.fillWidth: true
            spacing: Style.space(8)

            PuzzleButton {
              Layout.fillWidth: true
              label: "Show solution"
              enabled: root.puzzle !== null && root.phase !== "won"
              foreground: root.foreground
              fontFamily: root.fontFamily
              onClicked: root.showSolution()
            }

            PuzzleButton {
              Layout.fillWidth: true
              label: "New puzzle"
              accent: true
              accentColor: root.accent
              onColor: root.surface
              enabled: root.phase !== "loading"
              foreground: root.foreground
              fontFamily: root.fontFamily
              onClicked: root.fetchPuzzle()
            }
          }
        }
      }
    }
  }

  component PuzzleButton: Rectangle {
    id: btn
    property string label: ""
    property bool enabled: true
    property bool accent: false
    property color accentColor: "#ffffff"
    property color onColor: "#000000"
    property color foreground: "#ffffff"
    property string fontFamily: ""

    implicitHeight: Style.space(26)
    radius: Style.space(6)
    opacity: enabled ? 1.0 : 0.4
    color: accent ? accentColor
      : (mouse.containsMouse ? Qt.rgba(foreground.r, foreground.g, foreground.b, 0.18)
      : Qt.rgba(foreground.r, foreground.g, foreground.b, 0.08))

    Text {
      anchors.centerIn: parent
      text: btn.label
      color: btn.accent ? btn.onColor : btn.foreground
      font.family: btn.fontFamily
      font.pixelSize: Style.font.caption
    }

    MouseArea {
      id: mouse
      anchors.fill: parent
      hoverEnabled: true
      enabled: btn.enabled
      cursorShape: btn.enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
      onClicked: btn.clicked()
    }

    signal clicked()
  }
}
