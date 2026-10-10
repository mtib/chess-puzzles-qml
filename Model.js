// FEN/board helpers for the chess puzzle panel. The board is a 64-entry
// array in FEN order: index 0 is a8, index 63 is h1. Each entry is ""
// (empty) or a two-char piece code "<p|n|b|r|q|k><w|b>".
// pragma: no inline chess rules — the puzzle's solution list is the only
// arbiter of what a legal move is, so no move generator lives here.

function emptyBoard() {
  var board = []
  for (var i = 0; i < 64; i++) board.push("")
  return board
}

// "e4" -> 36 (rank 8 rows at the top, a8 = 0)
function squareToIndex(square) {
  var file = square.charCodeAt(0) - 97
  var rank = Number(square[1])
  return (8 - rank) * 8 + file
}

function indexToSquare(index) {
  var file = "abcdefgh"[index % 8]
  var rank = 8 - Math.floor(index / 8)
  return file + rank
}

// "6k1/2Q1R3/... b - - 1 1" -> { board, turn }
function parseFen(fen) {
  var board = emptyBoard()
  var rows = String(fen || "").split(" ")
  var ranks = String(rows[0] || "").split("/")
  for (var r = 0; r < 8 && r < ranks.length; r++) {
    var file = 0
    var chars = ranks[r]
    for (var c = 0; c < chars.length; c++) {
      var ch = chars[c]
      if (ch >= "1" && ch <= "8") {
        file += Number(ch)
      } else {
        var color = ch === ch.toUpperCase() ? "w" : "b"
        var index = r * 8 + file
        board[index] = ch.toLowerCase() + color
        file++
      }
    }
  }
  return { board: board, turn: String(rows[1] || "w") }
}

// Play a UCI move ("e2e4", "e7e8q") onto a board copy and return the new
// board. Handles the three moves that touch more than one square: castling
// moves the rook, en passant removes the passed pawn, promotion swaps the
// piece.
function applyUci(board, uci) {
  var from = squareToIndex(uci.slice(0, 2))
  var to = squareToIndex(uci.slice(2, 4))
  var promotion = uci.length > 4 ? uci[4] : ""
  var piece = board[from]
  var next = board.slice()

  next[to] = piece
  next[from] = ""

  // En passant: a pawn moving onto an empty square captured the pawn that
  // just passed it, sitting beside the pawn's origin.
  if (piece[0] === "p" && from % 8 !== to % 8 && board[to] === "") {
    next[Math.floor(from / 8) * 8 + (to % 8)] = ""
  }

  // Castling: the king moved two files; park the rook on its inside square.
  if (piece[1] === "k" && Math.abs((from % 8) - (to % 8)) === 2) {
    var row = Math.floor(from / 8)
    if (to % 8 === 6) {
      next[row * 8 + 5] = next[row * 8 + 7]
      next[row * 8 + 7] = ""
    } else {
      next[row * 8 + 3] = next[row * 8 + 0]
      next[row * 8 + 0] = ""
    }
  }

  if (promotion) next[to] = promotion + piece[1]
  return next
}

// Extract the puzzle record from either a raw Lichess /api/puzzle/next
// response (nested .puzzle) or a flat pick.sh record, or null when it has no
// usable FEN + solution pair.
function parsePuzzle(raw) {
  var parsed = null
  try {
    parsed = JSON.parse(String(raw || ""))
  } catch (e) {
    return null
  }
  var puzzle = parsed && parsed.puzzle ? parsed.puzzle : parsed
  if (!puzzle || !puzzle.fen || !puzzle.solution || puzzle.solution.length === 0) return null
  return {
    id: String(puzzle.id || ""),
    fen: String(puzzle.fen),
    rating: Number(puzzle.rating) || 0,
    themes: (puzzle.themes || []).slice(0, 3),
    solution: puzzle.solution.map(String)
  }
}

// "White to play — mate in 2" style headline.
function sideName(color) {
  return color === "b" ? "Black" : "White"
}
