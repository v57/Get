import Foundation

#if os(Windows)
  import WinSDK
  typealias DHTDescriptor = SOCKET
#elseif canImport(Glibc)
  import Glibc
  typealias DHTDescriptor = Int32
#else
  typealias DHTDescriptor = Int32
#endif

/// The DHT's UDP socket calls: POSIX sockets, or Winsock on Windows.
enum DHTSocket {
  /// A UDP socket bound to an ephemeral port on every IPv4 address.
  static func bindAny() throws -> DHTDescriptor {
    #if os(Windows)
      var data = WSADATA()
      _ = WSAStartup(0x0202, &data)
      let fd = socket(AF_INET, Int32(SOCK_DGRAM), 0)
      guard fd != INVALID_SOCKET else { throw DHTError.socket("socket(): \(WSAGetLastError())") }
    #else
      let fd = socket(AF_INET, Int32(SOCK_DGRAM_VALUE), 0)
      guard fd >= 0 else { throw DHTError.socket("socket(): \(errno)") }
    #endif
    var addr = sockaddr_in()
    addr.sin_family = family
    let rc = withUnsafePointer(to: &addr) { ptr in
      ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, length) }
    }
    guard rc == 0 else {
      close(fd)
      throw DHTError.socket("bind(): \(lastError)")
    }
    return fd
  }

  static func close(_ fd: DHTDescriptor) {
    #if os(Windows)
      _ = shutdown(fd, Int32(SD_BOTH))
      _ = closesocket(fd)
    #elseif canImport(Glibc)
      _ = shutdown(fd, Int32(SHUT_RDWR))
      _ = Glibc.close(fd)
    #else
      _ = shutdown(fd, SHUT_RDWR)
      _ = Darwin.close(fd)
    #endif
  }

  /// Waits up to `milliseconds` for a datagram: 1 when one is there, 0 on timeout, -1 on error.
  static func waitReadable(_ fd: DHTDescriptor, milliseconds: Int32) -> Int32 {
    #if os(Windows)
      var pfd = WSAPOLLFD(fd: fd, events: Int16(POLLRDNORM), revents: 0)
      let rc = WSAPoll(&pfd, 1, milliseconds)
      return rc < 0 ? -1 : (rc > 0 && pfd.revents & Int16(POLLRDNORM) != 0 ? 1 : 0)
    #else
      var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
      let rc = poll(&pfd, 1, milliseconds)
      return rc < 0 ? -1 : (rc > 0 && pfd.revents & Int16(POLLIN) != 0 ? 1 : 0)
    #endif
  }

  /// The next datagram and the IPv4 address and port it came from.
  static func receive(_ fd: DHTDescriptor) -> (Data, String, UInt16)? {
    var buf = [UInt8](repeating: 0, count: 65535)
    var from = sockaddr_in()
    var len = length
    let n = withUnsafeMutablePointer(to: &from) { ptr in
      ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { address in
        buf.withUnsafeMutableBytes { raw in
          #if os(Windows)
            Int(recvfrom(fd, raw.baseAddress!.assumingMemoryBound(to: CChar.self), Int32(raw.count), 0, address, &len))
          #else
            recvfrom(fd, raw.baseAddress, raw.count, 0, address, &len)
          #endif
        }
      }
    }
    guard n > 0 else { return nil }
    let host = String(cString: inet_ntoa(from.sin_addr))
    return (Data(buf.prefix(n)), host, UInt16(bigEndian: from.sin_port))
  }

  static func send(_ fd: DHTDescriptor, _ data: Data, to endpoint: sockaddr_in) {
    var ep = endpoint
    data.withUnsafeBytes { raw in
      withUnsafePointer(to: &ep) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
          #if os(Windows)
            _ = sendto(fd, raw.baseAddress?.assumingMemoryBound(to: CChar.self), Int32(data.count), 0, $0, length)
          #else
            _ = sendto(fd, raw.baseAddress, data.count, 0, $0, length)
          #endif
        }
      }
    }
  }

  /// An IPv4 endpoint for a dotted quad or a host name.
  static func resolve(_ host: String, port: UInt16) -> sockaddr_in? {
    var addr = sockaddr_in()
    addr.sin_family = family
    addr.sin_port = port.bigEndian
    if host.withCString({ inet_pton(AF_INET, $0, &addr.sin_addr) }) == 1 { return addr }
    // DNS for host names (the bootstrap routers): getaddrinfo returns a properly aligned sockaddr.
    var hints = addrinfo()
    hints.ai_family = AF_INET
    #if os(Windows)
      hints.ai_socktype = Int32(SOCK_DGRAM)
    #else
      hints.ai_socktype = Int32(SOCK_DGRAM_VALUE)
    #endif
    var result: UnsafeMutablePointer<addrinfo>?
    let rc = getaddrinfo(host, String(port), &hints, &result)
    guard rc == 0, let ai = result, let sa = ai.pointee.ai_addr else {
      if result != nil { freeaddrinfo(result) }
      return nil
    }
    var out = sockaddr_in()
    memcpy(&out, sa, MemoryLayout<sockaddr_in>.size)
    freeaddrinfo(result)
    return out
  }

  #if os(Windows)
    private static let family = ADDRESS_FAMILY(AF_INET)
    private static let length = Int32(MemoryLayout<sockaddr_in>.size)
    private static var lastError: Int32 { WSAGetLastError() }
  #else
    private static let family = sa_family_t(AF_INET)
    private static let length = socklen_t(MemoryLayout<sockaddr_in>.size)
    private static var lastError: Int32 { errno }
  #endif
}

#if canImport(Glibc)
  private let SOCK_DGRAM_VALUE = SOCK_DGRAM.rawValue
#elseif !os(Windows)
  private let SOCK_DGRAM_VALUE = SOCK_DGRAM
#endif
