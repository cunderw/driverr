#!/usr/bin/env swift
//
// Frames the raw App Store tour captures for the store: each capture inside a device
// frame, on a background drawn from the default theme's accent, under one short caption.
// It also draws the product page header from the same captures.
//
//   swift scripts/frame-screenshots.swift iphone-max <raw dir> <out dir>
//   swift scripts/frame-screenshots.swift ipad       <raw dir> <out dir>
//   swift scripts/frame-screenshots.swift header     <raw root> <out dir> [<crops dir>]
//   swift scripts/frame-screenshots.swift --list     the published names, one per line
//
// `scripts/screenshots.sh` calls it after a tour, and `scripts/screenshots.sh --frame`
// calls it on the committed raw captures without a tour.
//
// The app UI inside a frame is the capture, scaled and nothing else. App Review guideline
// 2.3.3 requires that, so the background, the frame, the phone's Dynamic Island and the
// caption are the only things drawn here.
//
// CoreGraphics, CoreText and ImageIO only, so it runs on any Mac that builds the app.

import CoreGraphics
import CoreText
import Foundation
import ImageIO

// MARK: - What is published

/// The store order, and the caption for each capture. The filename sets the upload order,
/// so a published image is `NN-<stem>.png` with `NN` from its place here. A raw capture
/// that is not listed is not published. The tour still takes `hosts` on the phone.
///
/// Each caption is one of the listing's bullets in `docs/appstore/copy.json`, or something
/// the capture shows. Keep them short and true: no superlatives and no claim the picture
/// does not back up.
let published: [(stem: String, caption: String)] = [
  ("needs-you", "See which agent needs you"),
  ("chat", "Reply without a terminal"),
  ("terminal", "A real terminal for any pane"),
  ("pane-actions", "Rename or close a pane"),
  ("settings", "Themes and type sizes"),
]

/// The header's one phrase.
let headerPhrase = "Know when an agent needs you"

// MARK: - Sizes

/// One device kind: the canvas App Store Connect takes, the capture that goes in it, and
/// the frame around it.
struct Kind {
  let canvas: CGSize
  /// The tour's capture size. A capture of any other size is the wrong device.
  let capture: CGSize
  /// The display's corner radius in capture pixels. Measured from the keyboard's lower
  /// corners, which iOS draws concentric with the display: about 180 on the 6.9" phone and
  /// 55 on the 13" iPad. Rounded up, because a clip smaller than the drawn corner leaves a
  /// sliver of the app's background between the keyboard and the frame.
  let screenRadius: CGFloat
  /// The Dynamic Island in capture pixels, or nil for a device without one. The simulator
  /// does not draw it, and the status bar leaves its place empty, so drawing it covers no
  /// app UI.
  let island: CGRect?
  /// The bezel's width in canvas pixels.
  let bezel: CGFloat
  let captionSize: CGFloat
  /// Above the caption, between the caption and the device, and below the device.
  let top: CGFloat
  let gap: CGFloat
  let bottom: CGFloat
}

let kinds: [String: Kind] = [
  "iphone-max": Kind(
    canvas: CGSize(width: 1320, height: 2868), capture: CGSize(width: 1320, height: 2868),
    screenRadius: 186,
    // 126 by 37 points, 11 points from the top edge, at 3x.
    island: CGRect(x: 471, y: 34, width: 378, height: 112),
    bezel: 28, captionSize: 112, top: 170, gap: 120, bottom: 120),
  "ipad": Kind(
    canvas: CGSize(width: 2064, height: 2752), capture: CGSize(width: 2064, height: 2752),
    screenRadius: 60, island: nil, bezel: 40, captionSize: 132, top: 160, gap: 120,
    bottom: 130),
]

/// The header fills both the product page header and the search results, and Apple crops
/// it to 21:9 for one and 3:2 for the other. Everything that matters stays inside the
/// central 70% each way, which both crops keep.
let headerSize = CGSize(width: 5244, height: 2950)
let headerCrops: [(name: String, aspect: CGSize, out: CGSize)] = [
  ("crop-21x9", CGSize(width: 21, height: 9), CGSize(width: 3840, height: 1646)),
  ("crop-3x2", CGSize(width: 3, height: 2), CGSize(width: 3840, height: 2560)),
]

/// The most lines a caption may take. Every caption gets this much room, so the devices
/// sit at the same height across a set.
let captionLines = 2

// MARK: - Colour

/// `Theme.system`'s light ANSI 4, which `Theme.accent(for: .light)` returns unchanged.
/// The captures are in light appearance, so the light accent is the one they show.
let accent = RGB(hex: 0x5786F6)

struct RGB {
  var r, g, b: Double

  init(r: Double, g: Double, b: Double) { (self.r, self.g, self.b) = (r, g, b) }
  init(hex: Int) {
    self.init(
      r: Double((hex >> 16) & 0xFF) / 255, g: Double((hex >> 8) & 0xFF) / 255,
      b: Double(hex & 0xFF) / 255)
  }

  /// WCAG relative luminance.
  var luminance: Double {
    func linear(_ c: Double) -> Double {
      c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }
    return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
  }

  func contrast(with other: RGB) -> Double {
    let (a, b) = (luminance, other.luminance)
    return (max(a, b) + 0.05) / (min(a, b) + 0.05)
  }

  func blended(toward other: RGB, by amount: Double) -> RGB {
    RGB(
      r: r + (other.r - r) * amount, g: g + (other.g - g) * amount,
      b: b + (other.b - b) * amount)
  }

  /// `self` toward black by the least amount that gives `ink` `minimum` contrast on it.
  /// The mirror of `TerminalColor.lifted(toReach:against:)` in `ThemeAccent.swift`.
  func darkened(toReach minimum: Double, for ink: RGB) -> RGB {
    guard contrast(with: ink) < minimum else { return self }
    let black = RGB(r: 0, g: 0, b: 0)
    var failing = 0.0
    var passing = 1.0
    for _ in 0..<24 {
      let midpoint = (passing + failing) / 2
      if blended(toward: black, by: midpoint).contrast(with: ink) >= minimum {
        passing = midpoint
      } else {
        failing = midpoint
      }
    }
    return blended(toward: black, by: passing)
  }

  func cg(alpha: Double = 1) -> CGColor {
    CGColor(srgbRed: r, green: g, blue: b, alpha: alpha)
  }
}

let white = RGB(r: 1, g: 1, b: 1)
/// The accent, darkened until white reads at 4.8:1 on it, so a caption still clears 4.5:1
/// where the glow lightens it. `drawText` measures that and fails below 4.5:1. White on the
/// accent itself reads 3.42:1, which CLAUDE.md already records for the in-app accent fill.
let backgroundTop = accent.darkened(toReach: 4.8, for: white)
/// Darker toward the bottom, so the device stands on something.
let backgroundBottom = backgroundTop.blended(toward: RGB(r: 0, g: 0, b: 0), by: 0.4)

// MARK: - Drawing

func fail(_ message: String) -> Never {
  FileHandle.standardError.write(Data("error: \(message)\n".utf8))
  exit(1)
}

let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

/// An opaque RGB canvas. `noneSkipLast` has no alpha, so the PNG has none either, which
/// App Store Connect requires.
func canvas(_ size: CGSize) -> CGContext {
  guard
    let context = CGContext(
      data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
      bytesPerRow: 0, space: sRGB, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
  else { fail("cannot make a \(Int(size.width))x\(Int(size.height)) canvas") }
  context.interpolationQuality = .high
  context.setShouldAntialias(true)
  return context
}

/// A rectangle measured from the canvas's top edge. CoreGraphics measures from the bottom.
func fromTop(_ context: CGContext, x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat)
  -> CGRect
{
  CGRect(x: x, y: CGFloat(context.height) - y - height, width: width, height: height)
}

func drawBackground(_ context: CGContext) {
  let size = CGSize(width: context.width, height: context.height)
  let gradient = CGGradient(
    colorsSpace: sRGB, colors: [backgroundTop.cg(), backgroundBottom.cg()] as CFArray,
    locations: [0, 1])!
  context.drawLinearGradient(
    gradient, start: CGPoint(x: 0, y: size.height), end: CGPoint(x: 0, y: 0), options: [])
  // A soft light behind the middle, in the accent itself, so the flat gradient has some
  // depth. The accent is lighter than the top colour, so the glow lowers the caption's
  // contrast a little. `drawText` measures what is left.
  let glow = CGGradient(
    colorsSpace: sRGB, colors: [accent.cg(alpha: 0.35), accent.cg(alpha: 0)] as CFArray,
    locations: [0, 1])!
  let centre = CGPoint(x: size.width / 2, y: size.height * 0.55)
  context.drawRadialGradient(
    glow, startCenter: centre, startRadius: 0, endCenter: centre,
    endRadius: max(size.width, size.height) * 0.6, options: [])
}

func loadImage(_ url: URL) -> CGImage {
  guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
    let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
  else { fail("cannot read \(url.path)") }
  return image
}

/// Draws `capture` as a device's screen with its top-left corner at `origin` (from the
/// canvas's top), `scale` capture pixels to canvas pixels, and returns the device's outer
/// rectangle.
@discardableResult
func drawDevice(
  _ context: CGContext, _ capture: CGImage, kind: Kind, origin: CGPoint, scale: CGFloat
) -> CGRect {
  let screenSize = CGSize(
    width: CGFloat(capture.width) * scale, height: CGFloat(capture.height) * scale)
  let screen = fromTop(
    context, x: origin.x + kind.bezel, y: origin.y + kind.bezel, width: screenSize.width,
    height: screenSize.height)
  let outer = screen.insetBy(dx: -kind.bezel, dy: -kind.bezel)
  let screenRadius = kind.screenRadius * scale
  let outerRadius = screenRadius + kind.bezel

  // The shadow goes on the body only. It is cleared before the capture is drawn, or the
  // screen casts one of its own onto the bezel.
  context.saveGState()
  context.setShadow(
    offset: CGSize(width: 0, height: -outer.height * 0.018), blur: outer.height * 0.05,
    color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.45))
  context.addPath(
    CGPath(roundedRect: outer, cornerWidth: outerRadius, cornerHeight: outerRadius,
      transform: nil))
  context.setFillColor(RGB(hex: 0x5C5C60).cg())
  context.fillPath()
  context.restoreGState()

  // A thin light edge, then the black bezel inside it.
  let rim = max(3, kind.bezel * 0.14)
  let bezel = outer.insetBy(dx: rim, dy: rim)
  context.addPath(
    CGPath(roundedRect: bezel, cornerWidth: outerRadius - rim, cornerHeight: outerRadius - rim,
      transform: nil))
  context.setFillColor(RGB(hex: 0x0B0B0C).cg())
  context.fillPath()

  context.saveGState()
  context.addPath(
    CGPath(roundedRect: screen, cornerWidth: screenRadius, cornerHeight: screenRadius,
      transform: nil))
  context.clip()
  context.draw(capture, in: screen)
  if let island = kind.island {
    let pill = CGRect(
      x: screen.minX + island.minX * scale, y: screen.maxY - island.maxY * scale,
      width: island.width * scale, height: island.height * scale)
    context.addPath(
      CGPath(roundedRect: pill, cornerWidth: pill.height / 2, cornerHeight: pill.height / 2,
        transform: nil))
    context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
    context.fillPath()
  }
  context.restoreGState()
  return outer
}

/// The lightest colour already drawn inside `rect`, sampled every few pixels.
func lightest(_ context: CGContext, in rect: CGRect) -> RGB {
  let pixels = context.data!.assumingMemoryBound(to: UInt8.self)
  // Row 0 of the buffer is the canvas's top edge.
  let top = context.height - Int(rect.maxY)
  var best = RGB(r: 0, g: 0, b: 0)
  for row in stride(from: max(0, top), to: min(context.height, top + Int(rect.height)), by: 4) {
    for column in stride(
      from: max(0, Int(rect.minX)), to: min(context.width, Int(rect.maxX)), by: 4)
    {
      let pixel = pixels + row * context.bytesPerRow + column * 4
      let colour = RGB(
        r: Double(pixel[0]) / 255, g: Double(pixel[1]) / 255, b: Double(pixel[2]) / 255)
      if colour.luminance > best.luminance { best = colour }
    }
  }
  return best
}

/// Draws `text` centred in `box` (from the canvas's top), in the bold system font, which is
/// SF Pro. Fails when it needs more than `maxLines`, rather than shrink one caption and not
/// the others.
func drawText(
  _ context: CGContext, _ text: String, size: CGFloat, box: CGRect, alignment: CTTextAlignment,
  maxLines: Int
) {
  let font = CTFontCreateUIFontForLanguage(.emphasizedSystem, size, nil)!
  let lineHeight = size * 1.12
  let style = withUnsafeBytes(of: alignment) { align in
    withUnsafeBytes(of: lineHeight) { height in
      let settings = [
        CTParagraphStyleSetting(
          spec: .alignment, valueSize: align.count, value: align.baseAddress!),
        CTParagraphStyleSetting(
          spec: .minimumLineHeight, valueSize: height.count, value: height.baseAddress!),
        CTParagraphStyleSetting(
          spec: .maximumLineHeight, valueSize: height.count, value: height.baseAddress!),
      ]
      return CTParagraphStyleCreate(settings, settings.count)
    }
  }
  let string = NSAttributedString(
    string: text,
    attributes: [
      NSAttributedString.Key(kCTFontAttributeName as String): font,
      NSAttributedString.Key(kCTForegroundColorAttributeName as String): white.cg(),
      NSAttributedString.Key(kCTParagraphStyleAttributeName as String): style,
    ])
  let setter = CTFramesetterCreateWithAttributedString(string)
  let target = fromTop(context, x: box.minX, y: box.minY, width: box.width, height: box.height)
  // Read from what is drawn under the text, not from the gradient's end colours, so the
  // glow is counted.
  let contrast = lightest(context, in: target).contrast(with: white)
  guard contrast >= 4.5 else {
    fail(String(format: "'%@' reads at %.2f:1 on its background", text, contrast))
  }
  print(String(format: "  the text reads at %.2f:1 or better on its background", contrast))
  func lineCount(_ width: CGFloat) -> Int {
    let tall = CGPath(rect: CGRect(x: 0, y: 0, width: width, height: 100_000), transform: nil)
    let frame = CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0), tall, nil)
    return (CTFrameGetLines(frame) as? [CTLine])?.count ?? 0
  }
  let lines = lineCount(target.width)
  guard lines >= 1, lines <= maxLines else {
    fail("'\(text)' takes \(lines) lines at \(Int(size)) pt, and the most is \(maxLines)")
  }
  // Wrapped text is set in the narrowest width that keeps the same number of lines, so the
  // lines come out even and no one word sits alone on the last.
  var narrow = target.width / CGFloat(lines)
  var wide = target.width
  while wide - narrow > 1 {
    let midpoint = (narrow + wide) / 2
    if lineCount(midpoint) > lines { narrow = midpoint } else { wide = midpoint }
  }
  let width = lines > 1 ? ceil(wide) : target.width
  let fitted = CTFramesetterSuggestFrameSizeWithConstraints(
    setter, CFRange(location: 0, length: 0), nil,
    CGSize(width: width, height: .greatestFiniteMagnitude), nil)
  // Centred vertically in the box, and across it when the text is centred.
  let x = alignment == .center ? target.minX + (target.width - width) / 2 : target.minX
  let path = CGPath(
    rect: CGRect(
      x: x, y: target.minY + (target.height - fitted.height) / 2,
      width: width, height: ceil(fitted.height)), transform: nil)
  let frame = CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0), path, nil)
  let range = CTFrameGetVisibleStringRange(frame)
  guard range.length == (text as NSString).length else {
    fail("'\(text)' does not fit its box")
  }
  context.textMatrix = .identity
  CTFrameDraw(frame, context)
}

func writePNG(_ image: CGImage, to url: URL) {
  guard
    let destination = CGImageDestinationCreateWithURL(
      url as CFURL, "public.png" as CFString, 1, nil)
  else { fail("cannot write \(url.path)") }
  CGImageDestinationAddImage(destination, image, nil)
  guard CGImageDestinationFinalize(destination) else { fail("cannot write \(url.path)") }
}

// MARK: - The two jobs

func frameSet(_ name: String, kind: Kind, raw: URL, out: URL) {
  let listed = Set(published.map(\.stem))
  let unlisted = ((try? FileManager.default.contentsOfDirectory(atPath: raw.path)) ?? [])
    .filter { $0.hasSuffix(".png") && !listed.contains(String($0.dropLast(4))) }
  for file in unlisted.sorted() { print("\(name): not published: \(file)") }

  for (index, shot) in published.enumerated() {
    let capture = loadImage(raw.appendingPathComponent("\(shot.stem).png"))
    guard CGFloat(capture.width) == kind.capture.width,
      CGFloat(capture.height) == kind.capture.height
    else {
      fail(
        "\(name)/\(shot.stem).png is \(capture.width)x\(capture.height), expected "
          + "\(Int(kind.capture.width))x\(Int(kind.capture.height))")
    }
    let context = canvas(kind.canvas)
    drawBackground(context)

    let width = kind.canvas.width
    let margin = width * 0.08
    let captionHeight = kind.captionSize * 1.12 * CGFloat(captionLines)
    drawText(
      context, shot.caption, size: kind.captionSize,
      box: CGRect(x: margin, y: kind.top, width: width - 2 * margin, height: captionHeight),
      alignment: .center, maxLines: captionLines)

    let deviceTop = kind.top + captionHeight + kind.gap
    let deviceHeight = kind.canvas.height - deviceTop - kind.bottom
    let scale = (deviceHeight - 2 * kind.bezel) / kind.capture.height
    let deviceWidth = kind.capture.width * scale + 2 * kind.bezel
    drawDevice(
      context, capture, kind: kind,
      origin: CGPoint(x: (width - deviceWidth) / 2, y: deviceTop), scale: scale)

    let file = String(format: "%02d-%@.png", index + 1, shot.stem)
    writePNG(context.makeImage()!, to: out.appendingPathComponent(file))
    print("\(name): \(file) \"\(shot.caption)\"")
  }
}

func frameHeader(rawRoot: URL, out: URL, crops: URL?) {
  let context = canvas(headerSize)
  drawBackground(context)
  let (w, h) = (headerSize.width, headerSize.height)
  // The central 70% each way. Both crops keep all of it.
  let safe = CGRect(x: w * 0.15, y: h * 0.15, width: w * 0.7, height: h * 0.7)

  let pad = kinds["ipad"]!
  let phone = kinds["iphone-max"]!
  let padCapture = loadImage(rawRoot.appendingPathComponent("ipad/needs-you.png"))
  let phoneCapture = loadImage(rawRoot.appendingPathComponent("iphone-max/chat.png"))

  // The iPad stands at the right of the safe area and the phone in front of its lower
  // right corner, both on one baseline near the safe area's bottom.
  let baseline = safe.maxY - h * 0.02
  let padHeight = safe.height * 0.93
  let padScale = (padHeight - 2 * pad.bezel) / pad.capture.height
  let padWidth = pad.capture.width * padScale + 2 * pad.bezel
  let phoneHeight = padHeight * 0.84
  let phoneScale = (phoneHeight - 2 * phone.bezel) / phone.capture.height
  let phoneWidth = phone.capture.width * phoneScale + 2 * phone.bezel
  let phoneX = safe.maxX - phoneWidth
  let padX = phoneX - padWidth + phoneWidth * 0.45
  drawDevice(
    context, padCapture, kind: pad, origin: CGPoint(x: padX, y: baseline - padHeight),
    scale: padScale)
  drawDevice(
    context, phoneCapture, kind: phone, origin: CGPoint(x: phoneX, y: baseline - phoneHeight),
    scale: phoneScale)

  // The phrase fills the space left of the devices.
  let textRight = padX - w * 0.04
  drawText(
    context, headerPhrase, size: 210,
    box: CGRect(x: safe.minX, y: safe.minY, width: textRight - safe.minX, height: safe.height),
    alignment: .left, maxLines: 3)

  let image = context.makeImage()!
  writePNG(image, to: out.appendingPathComponent("header.png"))
  print("header: header.png \"\(headerPhrase)\"")

  // The crops are checking aids: what the product page and search results keep. They are
  // redrawn on every run, so they are written outside the store directories.
  guard let crops else { return }
  try? FileManager.default.createDirectory(at: crops, withIntermediateDirectories: true)
  for crop in headerCrops {
    let keep: CGSize =
      w / h > crop.aspect.width / crop.aspect.height
      ? CGSize(width: h * crop.aspect.width / crop.aspect.height, height: h)
      : CGSize(width: w, height: w * crop.aspect.height / crop.aspect.width)
    let cut = image.cropping(
      to: CGRect(
        x: ((w - keep.width) / 2).rounded(), y: ((h - keep.height) / 2).rounded(),
        width: keep.width.rounded(), height: keep.height.rounded()))!
    let scaled = canvas(crop.out)
    scaled.draw(cut, in: CGRect(origin: .zero, size: crop.out))
    writePNG(scaled.makeImage()!, to: crops.appendingPathComponent("\(crop.name).png"))
    print("header: \(crop.name).png")
  }
}

// MARK: - Main

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments == ["--list"] {
  for shot in published { print(shot.stem) }
  exit(0)
}
guard arguments.count == 3 || (arguments.count == 4 && arguments[0] == "header") else {
  fail(
    "usage: frame-screenshots.swift iphone-max|ipad <raw dir> <out dir>, "
      + "header <raw root> <out dir> [<crops dir>], or --list")
}
let job = arguments[0]
let raw = URL(fileURLWithPath: arguments[1])
let out = URL(fileURLWithPath: arguments[2])
let crops = arguments.count == 4 ? URL(fileURLWithPath: arguments[3]) : nil
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
print(
  String(
    format: "background #%02X%02X%02X to #%02X%02X%02X, white reads at %.2f:1 on the top colour",
    Int(backgroundTop.r * 255), Int(backgroundTop.g * 255), Int(backgroundTop.b * 255),
    Int(backgroundBottom.r * 255), Int(backgroundBottom.g * 255), Int(backgroundBottom.b * 255),
    backgroundTop.contrast(with: white)))
switch job {
case "header": frameHeader(rawRoot: raw, out: out, crops: crops)
default:
  guard let kind = kinds[job] else { fail("unknown kind '\(job)' (iphone-max|ipad|header)") }
  frameSet(job, kind: kind, raw: raw, out: out)
}
