import XCTest
@testable import MWBClient

/// A thread-safe box for capturing values from @Sendable callbacks.
final class SendableBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T?

    func set(_ newValue: T) {
        lock.lock()
        value = newValue
        lock.unlock()
    }

    func get() -> T? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

/// End-to-end loopback over a real localhost TCP socket: one channel listens
/// on the clipboard port, the other pulls. Proves the channel handshake
/// (noise + 64-byte header packet), the 1024-byte UTF-16LE header framing,
/// the AES-CBC stream chunking, and the 32-byte body padding without a
/// Windows machine.
final class ClipboardChannelLoopbackTests: XCTestCase {

    private let securityKey = "loopback-test-key-0123456789"

    private func makeChannel(name: String, id: UInt32, port: UInt16 = MWBConstants.clipboardPort) -> ClipboardChannel {
        ClipboardChannel(
            securityKey: securityKey,
            machineID: MachineID(rawValue: id),
            machineName: name,
            port: port)
    }

    /// Starts a server channel on an ephemeral port and returns the channel
    /// plus the port it bound, so the loopback never competes for the real
    /// clipboard port.
    private func startServer() async throws -> (server: ClipboardChannel, port: UInt16) {
        let server = makeChannel(name: "ServerMac", id: 1001, port: 0)
        await server.updateRemote(host: "127.0.0.1", name: "ClientMac")
        await server.start()

        let bound = await server.listeningPort
        guard await server.isListening, let bound else {
            throw XCTSkip("Could not bind the loopback clipboard channel listener")
        }

        await addTeardownBlock { await server.stop() }
        return (server, bound)
    }

    private func makeClient(port: UInt16) async -> ClipboardChannel {
        let client = makeChannel(name: "ClientMac", id: 1002, port: port)
        await client.updateRemote(host: "127.0.0.1", name: "ServerMac")
        await addTeardownBlock { await client.stop() }
        return client
    }

    // MARK: - Text transfer

    func testPullReceivesStagedText() async throws {
        let (server, port) = try await startServer()

        let text = "The quick brown fox jumps over the lazy dog — ✓ 0123456789"
        let payload = ClipboardCodec.makeTextPayload(text: text)
        let compressed = ClipboardCodec.compressData(payload.data(using: .utf16LittleEndian)!)
        await server.setPendingData(.text(compressed))

        let client = await makeClient(port: port)
        let received = XCTestExpectation(description: "text received")
        let box = SendableBox<ClipboardCodec.DecodedClipboardText>()

        await client.setCallbacks(
            onReceivedText: { decoded in
                box.set(decoded)
                received.fulfill()
            },
            onReceivedImage: { _ in
                XCTFail("unexpected image received")
            },
            onReceivedFile: { _, _ in
                XCTFail("unexpected file received")
            },
            onConnectionAccepted: nil)

        await client.pull(postAction: .other)
        await fulfillment(of: [received], timeout: 10.0)

        XCTAssertEqual(box.get()?.plain, text)
    }

    // MARK: - Image transfer

    func testPullReceivesStagedImage() async throws {
        let (server, port) = try await startServer()

        // Payload larger than one 64 KB chunk exercises multi-chunk bodies,
        // and its odd length exercises the 32-byte zero padding.
        var png = Data()
        for i in 0..<100_003 {
            png.append(UInt8(truncatingIfNeeded: i * 7))
        }
        await server.setPendingData(.image(png))

        let client = await makeClient(port: port)
        let received = XCTestExpectation(description: "image received")
        let box = SendableBox<Data>()

        await client.setCallbacks(
            onReceivedText: { _ in
                XCTFail("unexpected text received")
            },
            onReceivedImage: { data in
                box.set(data)
                received.fulfill()
            },
            onReceivedFile: { _, _ in
                XCTFail("unexpected file received")
            },
            onConnectionAccepted: nil)

        await client.pull(postAction: .other)
        await fulfillment(of: [received], timeout: 10.0)

        XCTAssertEqual(box.get(), png)
    }

    // MARK: - File transfer

    func testPullReceivesStagedFile() async throws {
        let (server, port) = try await startServer()

        // ~200 KB: spans multiple chunks; length not a multiple of 32 so the
        // padding path is exercised.
        var contents = Data()
        for i in 0..<200_009 {
            contents.append(UInt8(truncatingIfNeeded: i * 13))
        }
        let sourceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mwb-loopback-\(UUID().uuidString).bin")
        try contents.write(to: sourceURL)
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        await server.setPendingData(.file(sourceURL))

        let client = await makeClient(port: port)
        let received = XCTestExpectation(description: "file received")
        let box = SendableBox<URL>()
        let postActionBox = SendableBox<ClipboardPostAction>()

        await client.setCallbacks(
            onReceivedText: { _ in
                XCTFail("unexpected text received")
            },
            onReceivedImage: { _ in
                XCTFail("unexpected image received")
            },
            onReceivedFile: { url, postAction in
                box.set(url)
                postActionBox.set(postAction)
                received.fulfill()
            },
            onConnectionAccepted: nil)

        await client.pull(postAction: .other)
        await fulfillment(of: [received], timeout: 10.0)

        let receivedURL = try XCTUnwrap(box.get())
        XCTAssertEqual(postActionBox.get(), .other)
        XCTAssertEqual(receivedURL.lastPathComponent, sourceURL.lastPathComponent)
        XCTAssertEqual(try Data(contentsOf: receivedURL), contents)

        // Clean up the file the channel wrote to Application Support.
        try? FileManager.default.removeItem(at: receivedURL)
    }

    // MARK: - Nothing staged

    func testPullWithNothingStagedReportsNoData() async throws {
        let (server, port) = try await startServer()
        await server.setPendingData(nil)

        let client = await makeClient(port: port)
        let unexpected = XCTestExpectation(description: "no callback expected")
        unexpected.isInverted = true

        await client.setCallbacks(
            onReceivedText: { _ in unexpected.fulfill() },
            onReceivedImage: { _ in unexpected.fulfill() },
            onReceivedFile: { _, _ in unexpected.fulfill() },
            onConnectionAccepted: nil)

        // The pull connects, handshakes, and the server closes without a
        // header because nothing is staged. The pull must simply return.
        await client.pull(postAction: .other)
        await fulfillment(of: [unexpected], timeout: 2.0)
    }

    // MARK: - Push transfer (ClipboardAsk response)

    func testPushDeliversStagedFileToAskingSide() async throws {
        let (server, port) = try await startServer()

        // ~100 KB, length not a multiple of 32 to exercise padding.
        var contents = Data()
        for i in 0..<100_003 {
            contents.append(UInt8(truncatingIfNeeded: i * 7))
        }
        let sourceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mwb-loopback-\(UUID().uuidString).bin")
        try contents.write(to: sourceURL)
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        // The CLIENT stages the data and pushes it (ClipboardAsk response);
        // the SERVER receives. Proves the outbound-push direction is decided
        // by intent, not by the peer's always-79 server handshake type.
        let client = await makeClient(port: port)
        await client.setPendingData(.file(sourceURL))

        let received = XCTestExpectation(description: "file received by asking side")
        let box = SendableBox<URL>()
        let postActionBox = SendableBox<ClipboardPostAction>()

        await server.setCallbacks(
            onReceivedText: { _ in
                XCTFail("unexpected text received")
            },
            onReceivedImage: { _ in
                XCTFail("unexpected image received")
            },
            onReceivedFile: { url, postAction in
                box.set(url)
                postActionBox.set(postAction)
                received.fulfill()
 },
            onConnectionAccepted: nil)

        // Non-default post action proves the pusher echoes it in its
        // handshake package (reference passes package.PostAction through).
        await client.pushPendingData(postAction: .mspaint)
        await fulfillment(of: [received], timeout: 10.0)

        let receivedURL = try XCTUnwrap(box.get())
        XCTAssertEqual(receivedURL.lastPathComponent, sourceURL.lastPathComponent)
        XCTAssertEqual(try Data(contentsOf: receivedURL), contents)
        XCTAssertEqual(postActionBox.get(), .mspaint)

        // Clean up the file the channel wrote to Application Support.
        try? FileManager.default.removeItem(at: receivedURL)
    }
}
