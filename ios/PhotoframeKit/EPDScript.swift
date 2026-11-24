import Foundation
import JavaScriptCore

/// Runs the web page's own `epd.js` (bundled from `server/public/epd.js` at
/// build time) in JavaScriptCore, so the app dithers and packs exactly as the
/// browser does. There is no Swift port of the dithering on purpose.
///
/// Not thread-safe: use one instance from one task at a time (`ImagePipeline`
/// does this).
public final class EPDScript {
    public enum Failure: LocalizedError {
        case missingScript
        case unsupportedModuleSyntax(String)
        case javaScript(String)
        case badResult(String)

        public var errorDescription: String? {
            switch self {
            case .missingScript: return "epd.js is missing from the app bundle."
            case .unsupportedModuleSyntax(let line): return "epd.js uses module syntax the app cannot load: \(line)"
            case .javaScript(let message): return "Image code failed: \(message)"
            case .badResult(let what): return "Image code returned an unexpected \(what)."
            }
        }
    }

    public struct Dithered {
        /// One ink index (into `INKS`) per pixel, viewer orientation.
        public let indices: Data
        /// RGBA of how the panel will look (`toRGBA(indices, 'rgb')`).
        public let previewRGBA: Data
        public let width: Int
        public let height: Int
    }

    public let frameBytes: Int
    private let context: JSContext
    private let api: JSValue
    private var lastException: String?

    public convenience init(bundle: Bundle = .main) throws {
        guard let url = bundle.url(forResource: "epd", withExtension: "js"),
              let source = try? String(contentsOf: url, encoding: .utf8) else { throw Failure.missingScript }
        try self.init(moduleSource: source)
    }

    public init(moduleSource: String) throws {
        guard let context = JSContext() else { throw Failure.javaScript("could not create a JavaScript context") }
        self.context = context
        context.name = "epd.js"
        var captured: String?
        context.exceptionHandler = { _, exception in
            captured = exception?.toString() ?? "unknown error"
        }

        let script = try Self.scriptSource(fromModule: moduleSource)
        context.evaluateScript(script, withSourceURL: URL(string: "epd.js"))
        if let captured { throw Failure.javaScript(captured) }

        guard let api = context.objectForKeyedSubscript("__photoframeEPD"), api.isObject,
              let frameBytes = api.forProperty("FRAME_BYTES")?.toInt32(), frameBytes > 0
        else { throw Failure.javaScript("epd.js did not load") }
        self.api = api
        self.frameBytes = Int(frameBytes)
        context.exceptionHandler = { [weak self] _, exception in
            self?.lastException = exception?.toString() ?? "unknown error"
        }
    }

    /// Turns the ES module into a plain script. JSContext cannot load modules,
    /// so `export function` / `export const` lose their `export` keyword and the
    /// whole file runs inside a strict-mode function (modules are always strict)
    /// that hands the functions the app needs to one global object. Anything
    /// else that looks like module syntax is refused rather than guessed at.
    static func scriptSource(fromModule source: String) throws -> String {
        let exportDecl = try NSRegularExpression(
            pattern: #"^export\s+(?=(?:const|let|var|function|class|async)\b)"#,
            options: .anchorsMatchLines)
        let whole = NSRange(source.startIndex..., in: source)
        let stripped = exportDecl.stringByReplacingMatches(in: source, range: whole, withTemplate: "")

        let leftover = try NSRegularExpression(pattern: #"^\s*(?:export|import)\b.*$"#, options: .anchorsMatchLines)
        if let match = leftover.firstMatch(in: stripped, range: NSRange(stripped.startIndex..., in: stripped)),
           let range = Range(match.range, in: stripped) {
            throw Failure.unsupportedModuleSyntax(String(stripped[range]))
        }

        return """
        (function () {
        'use strict';
        \(stripped)
        ;
        globalThis.__photoframeEPD = {
          FRAME_BYTES,
          viewSize,
          // The same steps, in the same order, as render() in server/public/app.js:
          // the canvas pixels (a Uint8ClampedArray) are adjusted in place, then
          // dithered.
          dither(rgba, width, height, contrast, saturation) {
            const work = new Uint8ClampedArray(rgba);
            adjust(work, { contrast, saturation });
            const indices = dither(work, width, height);
            const preview = toRGBA(indices, 'rgb');
            return { indices, preview: new Uint8Array(preview.buffer) };
          },
          pack(indices, orientation, flip) {
            return pack(indices, orientation, flip);
          },
        };
        })();
        """
    }

    /// Picture size in the viewer's orientation (`viewSize` in epd.js).
    public func viewSize(_ orientation: Orientation) throws -> (width: Int, height: Int) {
        let size = try call("viewSize", [orientation.rawValue])
        guard let w = size.forProperty("width")?.toInt32(), let h = size.forProperty("height")?.toInt32(), w > 0, h > 0
        else { throw Failure.badResult("size") }
        return (Int(w), Int(h))
    }

    /// `adjust` then `dither` on RGBA bytes in viewer orientation.
    public func dither(rgba: Data, width: Int, height: Int, contrast: Double, saturation: Double) throws -> Dithered {
        guard rgba.count == width * height * 4 else { throw Failure.badResult("pixel count") }
        let input = try makeUint8Array(rgba)
        let result = try call("dither", [input, width, height, contrast, saturation])
        guard let indices = result.forProperty("indices"), let preview = result.forProperty("preview") else {
            throw Failure.badResult("dither result")
        }
        let indexBytes = try bytes(of: indices)
        let previewBytes = try bytes(of: preview)
        guard indexBytes.count == width * height, previewBytes.count == width * height * 4 else {
            throw Failure.badResult("dither size")
        }
        return Dithered(indices: indexBytes, previewRGBA: previewBytes, width: width, height: height)
    }

    /// `pack`: ink indices to the 192,000 bytes the panel wants.
    public func pack(indices: Data, orientation: Orientation, flip: Bool) throws -> Data {
        let result = try call("pack", [try makeUint8Array(indices), orientation.rawValue, flip])
        let frame = try bytes(of: result)
        guard frame.count == frameBytes else { throw Failure.badResult("frame size") }
        return frame
    }

    // MARK: - JavaScriptCore plumbing

    private func call(_ name: String, _ arguments: [Any]) throws -> JSValue {
        lastException = nil
        let value = api.invokeMethod(name, withArguments: arguments)
        if let lastException { throw Failure.javaScript(lastException) }
        guard let value, !value.isUndefined, !value.isNull else { throw Failure.badResult("value from \(name)") }
        return value
    }

    /// Copies bytes into a new JavaScript Uint8Array without going through a
    /// slow array of numbers.
    private func makeUint8Array(_ data: Data) throws -> JSValue {
        let ctx = context.jsGlobalContextRef
        let count = data.count
        guard let buffer = malloc(max(count, 1)) else { throw Failure.javaScript("out of memory") }
        data.copyBytes(to: buffer.assumingMemoryBound(to: UInt8.self), count: count)
        var exception: JSValueRef?
        let object = JSObjectMakeTypedArrayWithBytesNoCopy(
            ctx, kJSTypedArrayTypeUint8Array, buffer, count, { bytes, _ in free(bytes) }, nil, &exception)
        guard exception == nil, let object, let value = JSValue(jsValueRef: object, in: context) else {
            free(buffer)
            throw Failure.javaScript("could not make a Uint8Array")
        }
        return value
    }

    private func bytes(of value: JSValue) throws -> Data {
        let ctx = context.jsGlobalContextRef
        guard let ref = value.jsValueRef else { throw Failure.badResult("typed array") }
        var exception: JSValueRef?
        let type = JSValueGetTypedArrayType(ctx, ref, &exception)
        guard exception == nil, type == kJSTypedArrayTypeUint8Array || type == kJSTypedArrayTypeUint8ClampedArray,
              let object = JSValueToObject(ctx, ref, &exception)
        else { throw Failure.badResult("typed array") }
        let length = JSObjectGetTypedArrayByteLength(ctx, object, &exception)
        let offset = JSObjectGetTypedArrayByteOffset(ctx, object, &exception)
        guard length > 0 else { return Data() }
        // The pointer is to the start of the backing buffer, hence the offset.
        guard let base = JSObjectGetTypedArrayBytesPtr(ctx, object, &exception), exception == nil else {
            throw Failure.badResult("typed array")
        }
        return Data(bytes: base.advanced(by: offset), count: length)
    }
}
