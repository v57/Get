import Foundation
import SSHTunnel
import URLDownload
import VaultKit

/// The user's other devices a link can be downloaded on (Download on…): the hosts the Vault app keeps for the
/// devices on their Hub, reached at their Hub Network address over SSH, signed in with this device's key (the
/// Secure Enclave key every v57 app shares) or the host's saved password. The file lands in that device's
/// `~/Downloads`.
@MainActor enum HubDevices {
  /// The devices to offer, by name.
  static var hosts: [VaultHost] {
    Vault.shared.hubHosts.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
  }

  static func host(id: String) -> VaultHost? { Vault.shared.host(id: id) }

  /// The devices as the Download sheet lists them: id and name.
  static var choices: [(id: String, name: String)] { hosts.map { ($0.id, $0.displayName) } }

  static func name(of id: String) -> String? { host(id: id)?.displayName }

  /// Starts the download on the device. `onEvent` gets what the command reports, on the main actor; the task ends
  /// with the command's exit status (nil when stopped).
  static func start(
    _ download: RemoteDownload, on host: VaultHost, onEvent: @escaping @MainActor (RemoteDownload.Event) -> Void
  ) throws -> (command: SSHCommand, finished: Task<Int32?, Error>) {
    let server = try server(for: host)
    let command = SSHCommand(server: server, command: download.command)
    let parser = ParserBox()
    let finished = Task {
      let status = try await command.run { data in
        let events = parser.consume(data)
        guard !events.isEmpty else { return }
        Task { @MainActor in events.forEach(onEvent) }
      }
      // Trust on first use, as Shell and Database do; a device's signed key is trusted ahead of time by Vault.
      if server.knownFingerprint == nil, !command.hostKeyFingerprint.isEmpty {
        try? await MainActor.run {
          try Vault.shared.store?.trust(fingerprint: command.hostKeyFingerprint, host: host.hostname, port: host.port)
        }
      }
      return status
    }
    return (command, finished)
  }

  /// How Get logs in to the host: its user, this device's key or the saved password, the trusted host key.
  static func server(for host: VaultHost) throws -> SSHServer {
    let known = try? Vault.shared.store?.knownFingerprint(host: host.hostname, port: host.port)
    let user = host.user.isEmpty ? NSUserName() : host.user
    if host.auth == .password {
      return SSHServer(
        host: host.hostname, port: host.port, user: user, password: VaultSecrets.password(for: host.id),
        knownFingerprint: known)
    }
    return SSHServer(host: host.hostname, port: host.port, user: user, key: try deviceKey(), knownFingerprint: known)
  }

  /// This device's SSH key (Secure Enclave, shared by the v57 apps), as Database signs in with it.
  private static func deviceKey() throws -> SSHKey {
    let key = try VaultIdentity.key()
    let blob = VaultIdentity.publicKeyBlob(key)
    return SSHKey(kind: .ecdsaP256, publicKeyBlob: Array(blob), comment: VaultDevice.name) { data in
      Array(try VaultIdentity.sshSignature(Data(data), key: key))
    }
  }

  /// The parser, fed from the command's thread.
  private final class ParserBox: @unchecked Sendable {
    private let lock = NSLock()
    private var parser = RemoteDownload.Parser()
    func consume(_ data: Data) -> [RemoteDownload.Event] { lock.withLock { parser.consume(data) } }
  }
}
