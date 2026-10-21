#!/bin/bash
# Read the text off a photo of the phone's screen.
#
# The lisa fbcon is a ring buffer that never scrolls, so every boot verdict
# comes from photographs. This converts a HEIC/JPEG/PNG photo of the display
# into plain text using the macOS Vision framework (no tesseract, no pip).
#
#   tools/lisa-ocr.sh ~/Downloads/IMG_0723.HEIC
#   tools/lisa-ocr.sh --rotate 90 photo.HEIC      # phones are often shot sideways
#   tools/lisa-ocr.sh --auto photo.HEIC            # try all 4 rotations, best one
#
# It prints the recognised text, top to bottom, and nothing is written to the
# phone. Photos stay out of the repo.
set -euo pipefail
cd "$(dirname "$0")/.."

ROT=0
MODE=fixed
while [ $# -gt 0 ]; do
	case "$1" in
		--rotate) ROT="$2"; shift 2 ;;
		--auto) MODE=auto; shift ;;
		-h|--help) sed -n '2,16p' "$0"; exit 0 ;;
		*) IMG="$1"; shift ;;
	esac
done
: "${IMG:?usage: tools/lisa-ocr.sh [--auto|--rotate N] PHOTO}"

[ -f "$IMG" ] || { echo "no such file: $IMG" >&2; exit 1; }

BIN=$(mktemp -d)/ocr
cat >"$BIN.swift" <<'SWIFT'
import Foundation
import Vision
import AppKit

let args = CommandLine.arguments
guard args.count >= 2 else { exit(2) }
let path = args[1]
let rotate = args.count > 2 ? (Double(args[2]) ?? 0) : 0
let score = args.count > 3 && args[3] == "--score"

func rotated(_ src: CGImage, _ deg: Double) -> CGImage {
    let rad = deg * .pi / 180
    let w = Int(Double(src.height) * abs(cos(rad))) + Int(Double(src.width) * abs(sin(rad)))
    let h = Int(Double(src.width) * abs(sin(rad))) + Int(Double(src.height) * abs(cos(rad)))
    let cs = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                              bytesPerRow: 0, space: cs,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return src }
    ctx.translateBy(x: Double(w) / 2, y: Double(h) / 2)
    ctx.rotate(by: rad)
    ctx.draw(src, in: CGRect(x: -Double(src.width) / 2, y: -Double(src.height) / 2,
                              width: Double(src.width), height: Double(src.height)))
    return ctx.makeImage() ?? src
}

func recognize(_ cg: CGImage) -> [(Double, String, Double)] {
    let req = VNRecognizeTextRequest()
    req.recognitionLevel = .accurate
    req.usesLanguageCorrection = false
    req.recognitionLanguages = ["en-US"]
    let handler = VNImageRequestHandler(cgImage: cg, options: [:])
    try? handler.perform([req])
    guard let obs = req.results else { return [] }
    // Vision's normalized origin is bottom-left, so sorting by descending
    // midY gives the lines top-to-bottom as they appear on the phone.
    return obs.compactMap { o -> (Double, String, Double)? in
        guard let top = o.topCandidates(1).first else { return nil }
        let bb = o.boundingBox
        return (Double(bb.midY), top.string, Double(top.confidence))
    }.sorted { $0.0 > $1.0 }
}

guard let img = NSImage(contentsOfFile: path),
      let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    FileHandle.standardError.write("cannot read image\n".data(using: .utf8)!)
    exit(1)
}

if score {
    // Score each rotation by how many lines contain real console vocabulary.
    // Mean confidence alone is a poor signal: the fbcon font is 12 px tall,
    // so even the correct rotation has low absolute confidence.
    let vocab = ["SWEET", "CPU", "cpu", "cluster", "mpidr", "PSCI", "init", "BSD",
                 "root", "md0", "kext", "kext", "IOKit", "kernel", "ml_processor",
                 "EL1", "IRQ", "panic", "KMEM", "zone", "VFS", "vnode", "ALERT"]
    var bestAngle = 0.0
    var bestScore = 0.0
    var bestLines = 0
    for deg in [0.0, 90.0, 180.0, 270.0] {
        let r = recognize(rotated(cg, deg))
        guard !r.isEmpty else { continue }
        var hits = 0
        for (_, text, _) in r {
            for w in vocab where text.contains(w) { hits += 1; break }
        }
        // Reward vocabulary hits heavily; line count is only a tiebreak.
        let s = Double(hits) * 100 + Double(r.count)
        if s > bestScore { bestAngle = deg; bestScore = s; bestLines = r.count }
    }
    let msg = String(format: "BEST_ROT=%.0f SCORE=%.1f LINES=%d\n", bestAngle, bestScore, bestLines)
    FileHandle.standardError.write(msg.data(using: .utf8)!)
    exit(0)
}

var work = cg
if rotate != 0 { work = rotated(cg, rotate) }

for (_, text, conf) in recognize(work) {
    print(String(format: "%.2f  %@", conf, text))
}
SWIFT

swiftc -O -o "$BIN" "$BIN.swift"

# Convert to PNG first: Vision reads HEIC inconsistently, and PNG keeps the
# full resolution of the photo so the small console glyphs stay legible.
OUT=$(mktemp -d)/shot.png
sips -s format png "$IMG" --out "$OUT" >/dev/null 2>&1

if [ "$MODE" = auto ]; then
	# Score all four rotations, then print the winner in full.
	ROT=$(mktemp -d)/rot.txt
	"$BIN" "$OUT" 0 --score 2>"$ROT" || true
	ROT=$(sed -n 's/^BEST_ROT=\([0-9]*\).*/\1/p' "$ROT")
	echo "# best rotation: ${ROT:-0} degrees" >&2
	exec "$BIN" "$OUT" "${ROT:-0}"
fi

"$BIN" "$OUT" "$ROT" | sed 's/^[0-9.]*  //'
