import QuotaBarCore
import SwiftUI

/// The mark of the local tool a row of usage came from: the same OpenAI, Claude, OpenCode, and Pi
/// marks the usage report draws, so a model reads the same in the menu and in the report.
struct SourceMark: View {
    let source: CostUsageSource
    var size: CGFloat = 12

    var body: some View {
        let art = SourceMarkArt.art(for: self.source)
        ZStack {
            ForEach(Array(art.layers.enumerated()), id: \.offset) { _, layer in
                SVGPathShape(path: layer.path, viewBox: art.viewBox)
                    .fill(layer.tone.color, style: FillStyle(eoFill: layer.evenOdd))
            }
        }
        .frame(width: self.size, height: self.size)
        .accessibilityHidden(true)
    }
}

/// One mark as the report's SVG has it: a view box and the filled paths drawn in it.
struct SourceMarkArt {
    enum Tone {
        /// The monochrome marks follow the text color, as the report's do in each theme.
        case ink
        case faint
        case claude

        var color: Color {
            switch self {
            case .ink: Color(nsColor: .labelColor)
            case .faint: Color(nsColor: .tertiaryLabelColor)
            case .claude: Color(red: 0xD9 / 255, green: 0x77 / 255, blue: 0x57 / 255)
            }
        }
    }

    struct Layer {
        let tone: Tone
        let evenOdd: Bool
        let path: Path

        init(tone: Tone, evenOdd: Bool, data: String) {
            self.tone = tone
            self.evenOdd = evenOdd
            self.path = Path(SVGPathParser.path(from: data))
        }
    }

    let viewBox: CGRect
    let layers: [Layer]

    static func art(for source: CostUsageSource) -> SourceMarkArt {
        switch source {
        case .codex: Self.codex
        case .claude: Self.claude
        case .openCode: Self.openCode
        case .piAgent: Self.piAgent
        }
    }

    // Path data copied from the usage report's ICONS table in report.js.

    static let codex = SourceMarkArt(
        viewBox: CGRect(x: 100, y: 100, width: 411, height: 411),
        layers: [
            Layer(tone: .ink, evenOdd: true, data:
            """
            M252.794 108.802C289.191 99.0484 326.265 110.305 351.148 135.135C385.113 126.072 422.85 134.862 \
            449.492 161.505C476.136 188.149 484.925 225.888 475.862 259.85V259.854C500.696 284.735 511.95 32\
            1.81 502.198 358.207C492.447 394.602 464.161 421.084 430.215 430.217C421.083 464.162 394.603 492\
            .448 358.206 502.199C321.812 511.951 284.734 500.693 259.852 475.864C225.887 484.927 188.15 476.\
            137 161.507 449.495C134.864 422.851 126.073 385.111 135.136 351.149C110.304 326.266 99.0496 289.\
            192 108.801 252.795C118.552 216.4 146.84 189.918 180.784 180.785C189.917 146.841 216.396 118.553\
             252.794 108.802ZM374.292 407.145C374.292 411.271 372.092 415.086 368.517 417.148L283.723 466.10\
            2C302.487 480.585 327.555 486.459 352.217 479.852C386.997 470.532 410.068 439.312 410.555 405.00\
            6V317.717C410.555 315.08 409.125 312.621 406.843 311.303L374.292 292.509V407.145ZM251.868 415.89\
            7C248.296 417.959 243.893 417.959 240.317 415.897L155.526 366.942C152.366 390.436 159.811 415.08\
             177.866 433.136H177.863C203.325 458.594 241.896 462.962 271.85 446.232L347.449 402.586C349.735 \
            401.268 351.148 398.8 351.148 396.163V358.579L251.868 415.897ZM368.602 220.628C366.319 219.309 3\
            63.474 219.318 361.191 220.637L328.641 239.431L427.921 296.749C431.496 298.811 433.697 302.627 4\
            33.697 306.752V404.661C455.622 395.654 473.244 376.881 479.851 352.218C489.169 317.442 473.668 2\
            81.85 444.201 264.274L368.602 220.628ZM177.303 206.34C155.377 215.348 137.756 234.122 131.148 25\
            8.783C121.832 293.561 137.331 329.153 166.799 346.727L242.398 390.373C244.68 391.692 247.525 391\
            .684 249.807 390.366L282.357 371.572L183.078 314.253C179.504 312.189 177.303 308.375 177.303 304\
            .251V206.34ZM259.849 279.145V331.858L305.5 358.213L351.15 331.858V279.145L305.5 252.789L259.849 \
            279.145ZM327.276 144.9C308.512 130.418 283.445 124.543 258.782 131.15C224.002 140.471 200.931 17\
            1.691 200.445 205.995V293.286C200.445 295.923 201.875 298.381 204.158 299.7L236.707 318.493V203.\
            856C236.707 199.731 238.909 195.916 242.483 193.853L327.276 144.9ZM433.137 177.867C407.675 152.4\
            07 369.103 148.038 339.149 164.769L263.55 208.415C261.265 209.734 259.852 212.202 259.852 214.83\
            8V252.423L359.132 195.105C362.703 193.041 367.108 193.041 370.682 195.105L455.473 244.06C458.635\
             220.567 451.189 195.922 433.135 177.867H433.137Z
            """
            ),
        ]
    )

    static let claude = SourceMarkArt(
        viewBox: CGRect(x: 0, y: 0, width: 256, height: 257),
        layers: [
            Layer(tone: .claude, evenOdd: false, data:
            """
            m50.228 170.321 50.357-28.257.843-2.463-.843-1.361h-2.462l-8.426-.518-28.775-.778-24.952-1.037-2\
            4.175-1.296-6.092-1.297L0 125.796l.583-3.759 5.12-3.434 7.324.648 16.202 1.101 24.304 1.685 17.6\
            29 1.037 26.118 2.722h4.148l.583-1.685-1.426-1.037-1.101-1.037-25.147-17.045-27.22-18.017-14.258\
            -10.37-7.713-5.25-3.888-4.925-1.685-10.758 7-7.713 9.397.649 2.398.648 9.527 7.323 20.35 15.75L9\
            4.817 91.9l3.889 3.24 1.555-1.102.195-.777-1.75-2.917-14.453-26.118-15.425-26.572-6.87-11.018-1.\
            814-6.61c-.648-2.723-1.102-4.991-1.102-7.778l7.972-10.823L71.42 0 82.05 1.426l4.472 3.888 6.61 1\
            5.101 10.694 23.786 16.591 32.34 4.861 9.592 2.592 8.879.973 2.722h1.685v-1.556l1.36-18.211 2.52\
            8-22.36 2.463-28.776.843-8.1 4.018-9.722 7.971-5.25 6.222 2.981 5.12 7.324-.713 4.73-3.046 19.76\
            8-5.962 30.98-3.889 20.739h2.268l2.593-2.593 10.499-13.934 17.628-22.036 7.778-8.749 9.073-9.657\
             5.833-4.601h11.018l8.1 12.055-3.628 12.443-11.342 14.388-9.398 12.184-13.48 18.147-8.426 14.518\
            .778 1.166 2.01-.194 30.46-6.481 16.462-2.982 19.637-3.37 8.88 4.148.971 4.213-3.5 8.62-20.998 5\
            .184-24.628 4.926-36.682 8.685-.454.324.519.648 16.526 1.555 7.065.389h17.304l32.21 2.398 8.426 \
            5.574 5.055 6.805-.843 5.184-12.962 6.611-17.498-4.148-40.83-9.721-14-3.5h-1.944v1.167l11.666 11\
            .406 21.387 19.314 26.767 24.887 1.36 6.157-3.434 4.86-3.63-.518-23.526-17.693-9.073-7.972-20.54\
            5-17.304h-1.36v1.814l4.73 6.935 25.017 37.59 1.296 11.536-1.814 3.76-6.481 2.268-7.13-1.297-14.6\
            47-20.544-15.1-23.138-12.185-20.739-1.49.843-7.194 77.448-3.37 3.953-7.778 2.981-6.48-4.925-3.43\
            6-7.972 3.435-15.749 4.148-20.544 3.37-16.333 3.046-20.285 1.815-6.74-.13-.454-1.49.194-15.295 2\
            0.999-23.267 31.433-18.406 19.702-4.407 1.75-7.648-3.954.713-7.064 4.277-6.286 25.47-32.405 15.3\
            6-20.092 9.917-11.6-.065-1.686h-.583L44.07 198.125l-12.055 1.555-5.185-4.86.648-7.972 2.463-2.59\
            3 20.35-13.999-.064.065Z
            """
            ),
        ]
    )

    static let openCode = SourceMarkArt(
        viewBox: CGRect(x: 0, y: 0, width: 32, height: 40),
        layers: [
            Layer(tone: .faint, evenOdd: false, data:
            "M24 32H8V16H24V32Z"
            ),
            Layer(tone: .ink, evenOdd: false, data:
            "M24 8H8V32H24V8ZM32 40H0V0H32V40Z"
            ),
        ]
    )

    static let piAgent = SourceMarkArt(
        viewBox: CGRect(x: 165.29, y: 165.29, width: 469.43, height: 469.43),
        layers: [
            Layer(tone: .ink, evenOdd: true, data:
            "M165.29 165.29H517.36V400H400V517.36H282.65V634.72H165.29ZM282.65 282.65V400H400V282.65Z"
            ),
            Layer(tone: .ink, evenOdd: false, data:
            "M517.36 400H634.72V634.72H517.36Z"
            ),
        ]
    )
}

/// Scales a path drawn in `viewBox` to fit the frame, centered, the way SVG's default
/// `xMidYMid meet` does.
private struct SVGPathShape: Shape {
    let path: Path
    let viewBox: CGRect

    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width / self.viewBox.width, rect.height / self.viewBox.height)
        let x = rect.midX - self.viewBox.midX * scale
        let y = rect.midY - self.viewBox.midY * scale
        let transform = CGAffineTransform(a: scale, b: 0, c: 0, d: scale, tx: x, ty: y)
        return self.path.applying(transform)
    }
}

/// Reads the subset of SVG path syntax the marks use: move, line, horizontal, vertical, cubic
/// curve, and close, in absolute and relative form.
enum SVGPathParser {
    static func path(from data: String) -> CGPath {
        let path = CGMutablePath()
        var tokens = Tokens(data)
        var current = CGPoint.zero
        var start = CGPoint.zero
        var command: Character = "M"

        while let next = tokens.next() {
            if case let .command(c) = next {
                command = c
                if c == "Z" || c == "z" {
                    path.closeSubpath()
                    current = start
                    continue
                }
            } else {
                tokens.pushBack(next)
            }
            let relative = command.isLowercase
            let origin = relative ? current : .zero
            switch command.uppercased() {
            case "M":
                guard let point = tokens.point(offset: origin) else { return path }
                path.move(to: point)
                current = point
                start = point
                // Pairs after a move are implicit lines.
                command = relative ? "l" : "L"
            case "L":
                guard let point = tokens.point(offset: origin) else { return path }
                path.addLine(to: point)
                current = point
            case "H":
                guard let x = tokens.number() else { return path }
                current = CGPoint(x: x + origin.x, y: current.y)
                path.addLine(to: current)
            case "V":
                guard let y = tokens.number() else { return path }
                current = CGPoint(x: current.x, y: y + origin.y)
                path.addLine(to: current)
            case "C":
                guard let c1 = tokens.point(offset: origin),
                      let c2 = tokens.point(offset: origin),
                      let end = tokens.point(offset: origin) else { return path }
                path.addCurve(to: end, control1: c1, control2: c2)
                current = end
            default:
                return path
            }
        }
        return path
    }

    private enum Token {
        case command(Character)
        case number(CGFloat)
    }

    private struct Tokens {
        private let scalars: [Character]
        private var index = 0
        private var pending: Token?

        init(_ data: String) {
            self.scalars = Array(data)
        }

        mutating func pushBack(_ token: Token) {
            self.pending = token
        }

        mutating func number() -> CGFloat? {
            guard case let .number(value)? = self.next() else { return nil }
            return value
        }

        mutating func point(offset: CGPoint) -> CGPoint? {
            guard let x = self.number(), let y = self.number() else { return nil }
            return CGPoint(x: x + offset.x, y: y + offset.y)
        }

        mutating func next() -> Token? {
            if let pending = self.pending {
                self.pending = nil
                return pending
            }
            while self.index < self.scalars.count,
                  self.scalars[self.index] == " " || self.scalars[self.index] == "," {
                self.index += 1
            }
            guard self.index < self.scalars.count else { return nil }
            let first = self.scalars[self.index]
            if first.isLetter, first != "e", first != "E" {
                self.index += 1
                return .command(first)
            }
            // A number ends at a second sign, a second decimal point, or anything else.
            var text = ""
            var seenDot = false
            var seenExponent = false
            while self.index < self.scalars.count {
                let c = self.scalars[self.index]
                if c == "-" || c == "+" {
                    guard text.isEmpty || text.last == "e" || text.last == "E" else { break }
                } else if c == "." {
                    guard !seenDot, !seenExponent else { break }
                    seenDot = true
                } else if c == "e" || c == "E" {
                    guard !seenExponent else { break }
                    seenExponent = true
                } else if !c.isNumber {
                    break
                }
                text.append(c)
                self.index += 1
            }
            guard let value = Double(text) else { return nil }
            return .number(CGFloat(value))
        }
    }
}
