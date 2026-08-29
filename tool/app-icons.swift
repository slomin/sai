#!/usr/bin/env swift

import AppKit
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

private let sizes = [16, 32, 64, 128, 256, 512, 1024]
private let sourceSize = 1024
private let artworkSize = 824
private let artworkInset = (sourceSize - artworkSize) / 2
private let cornerRadius = CGFloat(artworkSize) * 0.225
private let flavors = ["stable", "dev"]
private let placeholderDigests: Set<String> = [
  "6232e5815af17e25e0268b2fec7aea9e068cc92ec709e9605c2b31df4ff2a313",
  "15591f03f31313af6fd644ed0512106cc04365130b8b73244f1cfa6dddfb4400",
  "cc6928b5adfc00dbf526192e2705dd9af641cdf20ab4c6c7ca7cd4936dca59f0",
  "416efd77cde932d42ef34168da24dd428a495b1f4f34bbbd125a18d2add186a2",
  "ae8c4458e41f1e28b1e851ed87d3268d4a0351ceea427fa2a84cc94ddfb6d4c5",
  "0a91c6c1bf242e54ee179e34629e9ef3e8a6d286c0fce01e302280a8be9277e6",
  "6ad229623498e5f1277800db3ab7cb11faf85eb2569e1213f7d8e55003c07b42",
]

private enum IconToolError: Error, CustomStringConvertible {
  case message(String)

  var description: String {
    switch self {
    case let .message(message): message
    }
  }
}

private let fileManager = FileManager.default
private let root = URL(fileURLWithPath: fileManager.currentDirectoryPath)
private let runner = root.appendingPathComponent("apps/sai_app/macos/Runner")
private let sources = runner.appendingPathComponent("IconSources")
private let assets = runner.appendingPathComponent("Assets.xcassets")

private func sourceURL(_ flavor: String) -> URL {
  sources.appendingPathComponent("sai-\(flavor)-1024.png")
}

private func catalogURL(_ flavor: String) -> URL {
  assets.appendingPathComponent("AppIcon-\(flavor).appiconset")
}

private func imageURL(_ flavor: String, _ size: Int) -> URL {
  catalogURL(flavor).appendingPathComponent("app_icon_\(size).png")
}

private func loadImage(_ url: URL) throws -> CGImage {
  guard
    let source = CGImageSourceCreateWithURL(url as CFURL, nil),
    let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
  else {
    throw IconToolError.message("cannot decode \(url.path)")
  }
  return image
}

private func context(size: Int) throws -> CGContext {
  guard
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
    let context = CGContext(
      data: nil,
      width: size,
      height: size,
      bitsPerComponent: 8,
      bytesPerRow: 0,
      space: colorSpace,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        | CGBitmapInfo.byteOrder32Big.rawValue
    )
  else {
    throw IconToolError.message("cannot create a \(size) px sRGB canvas")
  }
  return context
}

private func drawUpright(
  _ image: CGImage,
  in rect: CGRect,
  on context: CGContext
) {
  context.interpolationQuality = .high
  context.draw(image, in: rect)
}

private func preparedMaster(_ source: CGImage) throws -> CGImage {
  let canvas = try context(size: sourceSize)
  let rect = CGRect(
    x: artworkInset,
    y: artworkInset,
    width: artworkSize,
    height: artworkSize
  )
  canvas.saveGState()
  canvas.addPath(
    CGPath(
      roundedRect: rect,
      cornerWidth: cornerRadius,
      cornerHeight: cornerRadius,
      transform: nil
    )
  )
  canvas.clip()
  canvas.interpolationQuality = .high
  canvas.draw(source, in: rect)
  canvas.restoreGState()
  guard let image = canvas.makeImage() else {
    throw IconToolError.message("cannot render the prepared master")
  }
  return image
}

private func resize(_ image: CGImage, to size: Int) throws -> CGImage {
  if size == image.width, size == image.height { return image }
  let canvas = try context(size: size)
  drawUpright(
    image,
    in: CGRect(x: 0, y: 0, width: size, height: size),
    on: canvas
  )
  guard let resized = canvas.makeImage() else {
    throw IconToolError.message("cannot render the \(size) px icon")
  }
  return resized
}

private func writePNG(_ image: CGImage, to url: URL) throws {
  guard
    let destination = CGImageDestinationCreateWithURL(
      url as CFURL,
      UTType.png.identifier as CFString,
      1,
      nil
    )
  else {
    throw IconToolError.message("cannot create \(url.path)")
  }
  CGImageDestinationAddImage(destination, image, nil)
  guard CGImageDestinationFinalize(destination) else {
    throw IconToolError.message("cannot write \(url.path)")
  }
}

private func manifest() -> String {
  let entries = [16, 32, 128, 256, 512].flatMap { size in
    [1, 2].map { scale in
      """
          {
            \"size\" : \"\(size)x\(size)\",
            \"idiom\" : \"mac\",
            \"filename\" : \"app_icon_\(size * scale).png\",
            \"scale\" : \"\(scale)x\"
          }
      """
    }
  }
  return """
  {
    \"images\" : [
  \(entries.joined(separator: ",\n"))
    ],
    \"info\" : {
      \"version\" : 1,
      \"author\" : \"xcode\"
    }
  }

  """
}

private func digest(_ data: Data) -> String {
  SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func rejectPlaceholder(_ url: URL) throws {
  let hash = digest(try Data(contentsOf: url))
  guard !placeholderDigests.contains(hash) else {
    throw IconToolError.message("Flutter placeholder returned at \(url.path)")
  }
}

private func rgba(_ image: CGImage) throws -> [UInt8] {
  let byteCount = image.width * image.height * 4
  var bytes = [UInt8](repeating: 0, count: byteCount)
  guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
    throw IconToolError.message("cannot create the sRGB comparison space")
  }
  try bytes.withUnsafeMutableBytes { buffer in
    guard let canvas = CGContext(
      data: buffer.baseAddress,
      width: image.width,
      height: image.height,
      bitsPerComponent: 8,
      bytesPerRow: image.width * 4,
      space: colorSpace,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        | CGBitmapInfo.byteOrder32Big.rawValue
    ) else {
      throw IconToolError.message("cannot compare a \(image.width) px icon")
    }
    canvas.setBlendMode(.copy)
    canvas.draw(
      image,
      in: CGRect(x: 0, y: 0, width: image.width, height: image.height)
    )
  }
  return bytes
}

private func grayscaleDifference(_ left: CGImage, _ right: CGImage) throws
  -> Double
{
  let a = try rgba(left)
  let b = try rgba(right)
  guard a.count == b.count else { return 1 }
  var changed = 0
  var pixels = 0
  for index in stride(from: 0, to: a.count, by: 4) {
    let alpha = max(a[index + 3], b[index + 3])
    if alpha == 0 { continue }
    pixels += 1
    let lumaA =
      299 * Int(a[index]) + 587 * Int(a[index + 1])
      + 114 * Int(a[index + 2])
    let lumaB =
      299 * Int(b[index]) + 587 * Int(b[index + 1])
      + 114 * Int(b[index + 2])
    if abs(lumaA - lumaB) > 24_000 { changed += 1 }
  }
  return pixels == 0 ? 0 : Double(changed) / Double(pixels)
}

private func prepare() throws {
  guard fileManager.fileExists(atPath: runner.path) else {
    throw IconToolError.message("run this command from the repository root")
  }
  for flavor in flavors {
    let input = sourceURL(flavor)
    let source = try loadImage(input)
    guard source.width == sourceSize, source.height == sourceSize else {
      throw IconToolError.message("expected a 1024×1024 master at \(input.path)")
    }
    try rejectPlaceholder(input)
    let prepared = try preparedMaster(source)
    let catalog = catalogURL(flavor)
    if fileManager.fileExists(atPath: catalog.path) {
      try fileManager.removeItem(at: catalog)
    }
    try fileManager.createDirectory(at: catalog, withIntermediateDirectories: true)
    for size in sizes {
      try writePNG(try resize(prepared, to: size), to: imageURL(flavor, size))
    }
    try manifest().write(
      to: catalog.appendingPathComponent("Contents.json"),
      atomically: true,
      encoding: .utf8
    )
  }
  try check()
}

private func check() throws {
  guard fileManager.fileExists(atPath: runner.path) else {
    throw IconToolError.message("run this command from the repository root")
  }
  let legacy = assets.appendingPathComponent("AppIcon.appiconset")
  guard !fileManager.fileExists(atPath: legacy.path) else {
    throw IconToolError.message("retired Flutter AppIcon catalog still exists")
  }

  var shipped: [String: [Int: CGImage]] = [:]
  for flavor in flavors {
    let input = sourceURL(flavor)
    let source = try loadImage(input)
    guard source.width == sourceSize, source.height == sourceSize else {
      throw IconToolError.message("expected a 1024×1024 master at \(input.path)")
    }
    try rejectPlaceholder(input)
    let prepared = try preparedMaster(source)
    let catalog = catalogURL(flavor)
    let expectedNames = Set(
      ["Contents.json"] + sizes.map { "app_icon_\($0).png" }
    )
    let actualNames = Set(try fileManager.contentsOfDirectory(atPath: catalog.path))
    guard actualNames == expectedNames else {
      throw IconToolError.message("unexpected contents in \(catalog.path)")
    }
    let actualManifest = try String(
      contentsOf: catalog.appendingPathComponent("Contents.json"),
      encoding: .utf8
    )
    guard actualManifest == manifest() else {
      throw IconToolError.message("stale manifest in \(catalog.path)")
    }

    var images: [Int: CGImage] = [:]
    for size in sizes {
      let url = imageURL(flavor, size)
      try rejectPlaceholder(url)
      let actual = try loadImage(url)
      guard actual.width == size, actual.height == size else {
        throw IconToolError.message("\(url.path) is not \(size)×\(size)")
      }
      let expected = try resize(prepared, to: size)
      guard try rgba(actual) == rgba(expected) else {
        throw IconToolError.message(
          "\(url.path) is stale; run swift tool/app-icons.swift prepare"
        )
      }
      images[size] = actual
    }
    shipped[flavor] = images
  }

  for size in sizes {
    guard
      let stable = shipped["stable"]?[size],
      let dev = shipped["dev"]?[size]
    else {
      throw IconToolError.message("missing flavor output at \(size) px")
    }
    let difference = try grayscaleDifference(stable, dev)
    guard difference >= 0.015 else {
      throw IconToolError.message(
        "stable and dev differ across only \(difference * 100)% at \(size) px"
      )
    }
  }
}

private func run() throws {
  guard CommandLine.arguments.count == 2 else {
    throw IconToolError.message(
      "usage: swift tool/app-icons.swift prepare|check"
    )
  }
  switch CommandLine.arguments[1] {
  case "prepare": try prepare()
  case "check": try check()
  default:
    throw IconToolError.message(
      "usage: swift tool/app-icons.swift prepare|check"
    )
  }
}

do {
  try run()
} catch {
  FileHandle.standardError.write(Data("app-icons: \(error)\n".utf8))
  exit(1)
}
