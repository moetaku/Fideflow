import Darwin
import Foundation

/// Phase 1 native bootstrap for the packaged media stack.
///
/// The Runner target's "Embed Native Libraries" build phase runs
/// `tooling/native/macos/embed.sh`, which packages the native libraries:
///
/// * the third-party audio stack (FFmpeg, libsoxr, OpenSSL) and the exported CA
///   bundle, described by the report `embed.sh` writes to
///   `Contents/Resources/native-libraries.json`;
/// * the Rust media host `libff_media_core.dylib`, which links those FFmpeg
///   libraries and is loaded by the Dart host at runtime;
///
/// Three things have to happen at launch:
///
/// 1. OpenSSL's compiled-in `--openssldir` is a build directory that does not
///    exist on a user's Mac, so its default verification path resolves nowhere.
///    Point `SSL_CERT_FILE`/`SSL_CERT_DIR` at the packaged bundle instead. That
///    covers every consumer calling `SSL_CTX_set_default_verify_paths()`.
/// 2. FFmpeg 7.1.5 is *not* such a consumer: `tls_openssl.c` never loads default
///    verify paths and defaults `tls_verify` to 0, so whatever opens a source
///    must pass `tls_verify=1` and `ca_file=<`NativeLibraries.caBundleRelativePath`>`
///    explicitly. Otherwise FFmpeg connects without verifying the peer.
/// 3. Load the packaged media host through `@rpath`, so a broken bundle fails
///    loudly at launch instead of at the first playback attempt, and check every
///    library the report claims is really there at the size it was built with.
///
/// The third-party set is deliberately *not* `dlopen`ed here any more: the Rust
/// host links it, and the bundle layout resolves it through the same
/// `@executable_path/../Frameworks` rpath the app binary already has, which makes
/// the packaged binaries the ones that are exercised (docs/design/native-build.md).
enum NativeLibraries {
  /// Bundle-relative path of the packaged trust store (`embed.sh` writes it).
  static let caBundleRelativePath = "Contents/Resources/ssl/cert.pem"

  /// Bundle-relative path of the packaging report (`embed.sh` writes it).
  static let reportRelativePath = "Contents/Resources/native-libraries.json"

  /// The Rust media host, loaded by the Dart host through `dart:ffi`.
  static let mediaHostName = "libff_media_core.dylib"


  /// ABI version this app ships against; `schemas/media_core.h` publishes it and
  /// the contract check keeps this constant in step with it (issue 1).
  static let supportedAbiVersion: UInt32 = 3

  private static let frameworksRelativePath = "Contents/Frameworks"

  /// Called from `AppDelegate.applicationWillFinishLaunching`, before the Flutter
  /// engine and any playback work. Returns false when the bundle is incomplete.
  @discardableResult
  static func prepare(bundle: Bundle = .main) -> Bool {
    installTrustStore(bundle: bundle)
    return loadMediaHost(bundle: bundle)
  }

  private static func installTrustStore(bundle: Bundle) {
    let directory = bundle.bundleURL.appendingPathComponent("Contents/Resources/ssl")
    let file = directory.appendingPathComponent("cert.pem")
    guard FileManager.default.fileExists(atPath: file.path) else {
      NSLog(
        "Fideflow: no packaged CA bundle at %@; HTTPS sources cannot be verified",
        file.path)
      return
    }
    setenv("SSL_CERT_FILE", file.path, 1)
    setenv("SSL_CERT_DIR", directory.path, 1)
    NSLog("Fideflow: OpenSSL trust store is the packaged bundle at %@", file.path)
  }

  private static func loadMediaHost(bundle: Bundle) -> Bool {
    let frameworks = bundle.bundleURL.appendingPathComponent(frameworksRelativePath)
    verifyReportedLibraries(bundle: bundle, frameworks: frameworks)

    let path = frameworks.appendingPathComponent(mediaHostName).path
    // RTLD_LOCAL keeps the process namespace free of FFmpeg and OpenSSL symbols;
    // the library itself resolves its dependencies through @rpath.
    guard let handle = dlopen(path, RTLD_LAZY | RTLD_LOCAL) else {
      NSLog("Fideflow: cannot load the media host %@: %@", path, dlerrorText())
      NSLog("Fideflow: run tooling/native/macos/build.sh, then rebuild the app")
      return false
    }
    let version = abiVersion(handle: handle)
    guard version == supportedAbiVersion else {
      NSLog(
        "Fideflow: %@ speaks ABI %@, this app speaks ABI %d",
        mediaHostName, version.map(String.init) ?? "nothing", Int(supportedAbiVersion))
      return false
    }
    NSLog(
      "Fideflow: native media host loaded: %@ (ABI %d, %@)",
      mediaHostName, Int(version ?? 0), bundle.bundleURL.lastPathComponent)
    return true
  }

  /// Reads the packaging report and checks that what it describes is present.
  ///
  /// Size, not hash: the report is written by the same build phase that copied the
  /// files, so a mismatch means a truncated copy or a library from another build,
  /// and a full SHA-256 of the set would slow every launch for no extra signal.
  private static func verifyReportedLibraries(bundle: Bundle, frameworks: URL) {
    let report = bundle.bundleURL.appendingPathComponent(reportRelativePath)
    guard let data = try? Data(contentsOf: report),
      let document = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let libraries = document["libraries"] as? [[String: Any]]
    else {
      NSLog("Fideflow: no packaging report at %@", report.path)
      return
    }
    var missing: [String] = []
    var wrongSize: [String] = []
    for library in libraries {
      guard let name = library["name"] as? String else { continue }
      let file = frameworks.appendingPathComponent(name)
      guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
        let size = attributes[.size] as? Int
      else {
        missing.append(name)
        continue
      }
      if let expected = library["bytes"] as? Int, expected != size {
        wrongSize.append("\(name) (\(size) != \(expected) bytes)")
      }
    }
    if !missing.isEmpty {
      NSLog("Fideflow: packaged libraries are missing: %@", missing.joined(separator: ", "))
    }
    if !wrongSize.isEmpty {
      NSLog(
        "Fideflow: packaged libraries do not match the build report: %@",
        wrongSize.joined(separator: "; "))
    }
    let mode = (document["network"] as? [String: Any])?["mode"] as? String ?? "unknown"
    if missing.isEmpty && wrongSize.isEmpty {
      NSLog(
        "Fideflow: %d packaged native libraries match the build report (network mode: %@)",
        libraries.count, mode)
    }
  }

  /// Calls `uint32_t ff_media_core_abi_version(void)` through its address.
  private static func abiVersion(handle: UnsafeMutableRawPointer) -> UInt32? {
    guard let address = dlsym(handle, "ff_media_core_abi_version") else { return nil }
    typealias AbiVersionFunction = @convention(c) () -> UInt32
    return unsafeBitCast(address, to: AbiVersionFunction.self)()
  }

  private static func dlerrorText() -> String {
    guard let message = dlerror() else {
      return "unknown dlopen failure"
    }
    return String(cString: message)
  }
}
