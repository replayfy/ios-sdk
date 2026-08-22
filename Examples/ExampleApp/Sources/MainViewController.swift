import UIKit
import Replay

/// Menu screen for the Tic-Tac-Toe replay demo. Boots into the game
/// after a short beat (simulating a tap on "play"), so the recording
/// shows a real screen transition followed by gameplay across several
/// rounds — not a single static screen.
final class MainViewController: UIViewController {

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(red: 0.06, green: 0.09, blue: 0.16, alpha: 1)

        let title = UILabel()
        title.text = "TIC-TAC-TOE"
        title.font = .systemFont(ofSize: 42, weight: .heavy)
        title.textColor = .white
        title.textAlignment = .center

        let subtitle = UILabel()
        subtitle.text = "auto-play demo"
        subtitle.font = .systemFont(ofSize: 18, weight: .regular)
        subtitle.textColor = UIColor(red: 0.58, green: 0.64, blue: 0.72, alpha: 1)
        subtitle.textAlignment = .center

        let play = UIButton(type: .system)
        play.setTitle("TAP TO PLAY", for: .normal)
        play.titleLabel?.font = .systemFont(ofSize: 22, weight: .semibold)
        play.addTarget(self, action: #selector(startGame), for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [title, subtitle, play])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 24
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        Replay.identify("tic-tac-toe-player", properties: ["plan": "free", "demo": "tic-tac-toe"])
        Replay.tagScreenName("Menu")
        Replay.track("app_opened", properties: ["game": "tic-tac-toe"])
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            Replay.track("menu_play_clicked")
            self?.startGame()
        }
    }

    private var navigated = false
    @objc private func startGame() {
        guard !navigated else { return }
        navigated = true
        navigationController?.pushViewController(GameViewController(), animated: true)
    }
}

/// The board screen. A tiny win/block AI drives a few full rounds with
/// pauses between moves so the recording captures the progression.
final class GameViewController: UIViewController {

    private var board = [Int](repeating: 0, count: 9) // 0 empty, 1 X, 2 O
    private var cells: [UIButton] = []
    private var current = 1
    private var round = 1
    private var moves = 0
    private var startedAt = Date()
    private let statusLabel = UILabel()

    private let maxRounds = 3
    private let lines = [
        [0, 1, 2], [3, 4, 5], [6, 7, 8],
        [0, 3, 6], [1, 4, 7], [2, 5, 8],
        [0, 4, 8], [2, 4, 6],
    ]

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(red: 0.06, green: 0.09, blue: 0.16, alpha: 1)
        startedAt = Date()

        let title = UILabel()
        title.text = "TIC-TAC-TOE"
        title.font = .systemFont(ofSize: 28, weight: .heavy)
        title.textColor = .white
        title.textAlignment = .center

        statusLabel.text = "X to move"
        statusLabel.font = .systemFont(ofSize: 24, weight: .semibold)
        statusLabel.textColor = UIColor(red: 0.22, green: 0.74, blue: 0.97, alpha: 1)
        statusLabel.textAlignment = .center

        // 3×3 grid of buttons via nested stack views.
        var rows: [UIStackView] = []
        for r in 0..<3 {
            var rowButtons: [UIView] = []
            for c in 0..<3 {
                let b = UIButton(type: .system)
                b.titleLabel?.font = .systemFont(ofSize: 46, weight: .heavy)
                b.backgroundColor = UIColor(red: 0.12, green: 0.16, blue: 0.23, alpha: 1)
                b.layer.cornerRadius = 10
                b.tag = r * 3 + c
                b.widthAnchor.constraint(equalToConstant: 92).isActive = true
                b.heightAnchor.constraint(equalToConstant: 92).isActive = true
                cells.append(b)
                rowButtons.append(b)
            }
            let rowStack = UIStackView(arrangedSubviews: rowButtons)
            rowStack.axis = .horizontal
            rowStack.spacing = 10
            rows.append(rowStack)
        }
        let grid = UIStackView(arrangedSubviews: rows)
        grid.axis = .vertical
        grid.spacing = 10
        grid.alignment = .center

        let stack = UIStackView(arrangedSubviews: [title, statusLabel, grid])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 36
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 60),
        ])

        Replay.tagScreenName("Game")
        Replay.track("game_started", properties: ["round": round])
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.autoMove() }
    }

    private func autoMove() {
        guard isViewLoaded else { return }
        let move = chooseMove(board, current)
        if move >= 0 {
            board[move] = current
            moves += 1
            let b = cells[move]
            b.setTitle(current == 1 ? "X" : "O", for: .normal)
            b.setTitleColor(
                current == 1
                    ? UIColor(red: 0.22, green: 0.74, blue: 0.97, alpha: 1)
                    : UIColor(red: 0.98, green: 0.44, blue: 0.52, alpha: 1),
                for: .normal,
            )
            Replay.track("move", properties: [
                "player": current == 1 ? "X" : "O", "cell": move, "round": round,
            ])
        }

        let w = winner(board)
        if w != 0 || moves == 9 {
            endRound(w)
            return
        }
        current = current == 1 ? 2 : 1
        setStatus("\(current == 1 ? "X" : "O") to move",
                  current == 1 ? (0.22, 0.74, 0.97) : (0.98, 0.44, 0.52))
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) { [weak self] in self?.autoMove() }
    }

    private func endRound(_ w: Int) {
        let msg = w == 1 ? "X wins!" : (w == 2 ? "O wins!" : "It's a draw")
        setStatus(msg, (0.98, 0.75, 0.14))
        if w != 0 { highlightWin(w) }
        Replay.track("game_over", properties: ["result": msg, "round": round])

        let elapsed = Date().timeIntervalSince(startedAt)
        if round < maxRounds && elapsed < 60 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.8) { [weak self] in self?.resetBoard() }
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                self?.setStatus("Thanks for playing!", (0.20, 0.83, 0.60))
                Replay.track("session_complete", properties: ["rounds": self?.round ?? 0])
            }
            // Demo crash: raise an NSException (caught by the SDK's
            // uncaught-exception handler) so the Crashes tab is exercised.
            // Gated behind REPLAY_DEMO_CRASH=1 so gesture / short-break tests
            // can keep the app alive.
            if ProcessInfo.processInfo.environment["REPLAY_DEMO_CRASH"] == "1" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 4.7) { [weak self] in
                    self?.setStatus("Simulating crash…", (0.98, 0.44, 0.52))
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                        NSException(
                            name: NSExceptionName("ReplayDemoCrash"),
                            reason: "Simulated crash from the Tic-Tac-Toe demo",
                            userInfo: nil
                        ).raise()
                    }
                }
            }
        }
    }

    private func resetBoard() {
        round += 1
        board = [Int](repeating: 0, count: 9)
        current = 1
        moves = 0
        for b in cells {
            b.setTitle("", for: .normal)
            b.backgroundColor = UIColor(red: 0.12, green: 0.16, blue: 0.23, alpha: 1)
        }
        setStatus("Round \(round)  ·  X to move", (0.22, 0.74, 0.97))
        Replay.tagScreenName("Game-Round\(round)")
        Replay.track("game_started", properties: ["round": round])
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in self?.autoMove() }
    }

    private func setStatus(_ text: String, _ rgb: (CGFloat, CGFloat, CGFloat)) {
        statusLabel.text = text
        statusLabel.textColor = UIColor(red: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1)
    }

    private func highlightWin(_ w: Int) {
        for l in lines where board[l[0]] == w && board[l[1]] == w && board[l[2]] == w {
            for idx in l { cells[idx].backgroundColor = UIColor(red: 0.09, green: 0.39, blue: 0.20, alpha: 1) }
        }
    }

    private func chooseMove(_ b: [Int], _ p: Int) -> Int {
        let o = p == 1 ? 2 : 1
        if let win = winningMove(b, p) { return win }
        if let block = winningMove(b, o) { return block }
        if b[4] == 0 { return 4 }
        let empties = (0..<9).filter { b[$0] == 0 }
        return empties.isEmpty ? -1 : empties[(moves * 7 + round * 3) % empties.count]
    }

    private func winningMove(_ b: [Int], _ p: Int) -> Int? {
        for i in 0..<9 where b[i] == 0 {
            var t = b
            t[i] = p
            if winner(t) == p { return i }
        }
        return nil
    }

    private func winner(_ b: [Int]) -> Int {
        for l in lines where b[l[0]] != 0 && b[l[0]] == b[l[1]] && b[l[1]] == b[l[2]] {
            return b[l[0]]
        }
        return 0
    }
}
