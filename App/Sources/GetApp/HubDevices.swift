import Foundation
import SSHTunnel
import URLDownload
import VaultKit
import VaultUI

/// The user's other devices a link can be downloaded on (Download on…): the devices on the user's Hubs and the Macs
/// that let the user's devices in (Settings ▸ Remote), reached over SSH at whichever of their addresses answers,
/// signed in with this device's key (the Secure Enclave key every v57 app shares) or the host's saved password. The file lands in that device's `~/Downloads`.
/// Each call takes the vault the device came from, so a download keeps its account's host.
@MainActor enum HubDevices {
  /// The devices to offer, by name.
  static func hosts(in vault: Vault) -> [VaultHost] {
    vault.otherDeviceHosts.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
  }

  /// The devices as the Download sheet lists them: id and name.
  static func choices(in vault: Vault) -> [(id: String, name: String)] {
    hosts(in: vault).map { ($0.id, $0.displayName) }
  }

  /// Starts the download on the device. `onEvent` gets what the command reports, on the main actor; the task ends
  /// with the command's exit status (nil when stopped).
  static func start(
    _ download: RemoteDownload, on host: VaultHost, in vault: Vault,
    onEvent: @escaping @MainActor (RemoteDownload.Event) -> Void
  ) throws -> (command: SSHCommand, finished: Task<Int32?, Error>) {
    let server = try server(for: host, in: vault)
    let command = SSHCommand(server: server, command: download.command)
    let parser = ParserBox()
    let finished = Task {
      try await command.run { data in
        let events = parser.consume(data)
        guard !events.isEmpty else { return }
        Task { @MainActor in events.forEach(onEvent) }
      }
    }
    return (command, finished)
  }

  /// How Get logs in to the host: its user, this device's key or the saved password, and the trusted host key: one a
  /// device signed or the user accepted, else the user is asked before anything is sent.
  static func server(for host: VaultHost, in vault: Vault) throws -> SSHServer {
    let trust = SSHHostTrust.known(
      vault.knownHost(for: host)?.fingerprint,
      otherwise: .ask { key in
        await VaultHostKeyRequest.shared.approve(key.fingerprint, keyType: key.type, for: host, in: vault)
      })
    let user = host.user.isEmpty ? NSUserName() : host.user
    // The device's other addresses, tried when this one doesn't answer.
    let fallbacks = vault.fallbackAddresses(of: host)
    if host.auth == .password {
      return SSHServer(
        host: host.hostname, fallbackHosts: fallbacks, port: host.port, user: user,
        password: VaultSecrets.password(for: host.id), trust: trust)
    }
    return SSHServer(
      host: host.hostname, fallbackHosts: fallbacks, port: host.port, user: user, key: try deviceKey(),
      trust: trust)
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
