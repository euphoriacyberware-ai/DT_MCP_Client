import Foundation
import Logging
import MCP
@preconcurrency import NIOCore
@preconcurrency import NIOHTTP1
@preconcurrency import NIOPosix

/// Streamable-HTTP MCP endpoint at http://127.0.0.1:<port>/mcp, protected by a bearer token.
/// One MCP `Server` per client session, all sharing a single `MCPToolbox`.
public actor MCPHTTPServer {
    public enum ServerError: Error, LocalizedError {
        case alreadyRunning
        public var errorDescription: String? { "The MCP server is already running." }
    }

    public static let endpoint = "/mcp"

    private let toolbox: MCPToolbox
    private var token = ""
    private var group: MultiThreadedEventLoopGroup?
    private var channel: Channel?
    private var sessions: [String: Session] = [:]

    private struct Session {
        let server: Server
        let transport: StatefulHTTPServerTransport
        var lastAccess: Date
    }

    public init(toolbox: MCPToolbox) { self.toolbox = toolbox }

    public var isRunning: Bool { channel != nil }

    // MARK: Lifecycle

    /// Binds to loopback only. Returns once listening.
    public func start(port: Int, token: String) async throws {
        guard channel == nil else { throw ServerError.alreadyRunning }
        self.token = token
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 64)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline().flatMap {
                    channel.pipeline.addHandler(HTTPHandler(app: self))
                }
            }
            .childChannelOption(ChannelOptions.maxMessagesPerRead, value: 1)
        do {
            channel = try await bootstrap.bind(host: "127.0.0.1", port: port).get()
            self.group = group
        } catch {
            try? await group.shutdownGracefully()
            throw error
        }
    }

    public func stop() async {
        for (_, s) in sessions { await s.transport.disconnect() }
        sessions.removeAll()
        try? await channel?.close()
        channel = nil
        try? await group?.shutdownGracefully()
        group = nil
    }

    // MARK: Routing

    fileprivate func handle(_ request: HTTPRequest) async -> HTTPResponse {
        // Auth first, constant-ish time not needed for a loopback bearer token.
        guard request.header(HTTPHeaderName.authorization) == "Bearer \(token)" else {
            return .error(
                statusCode: 401, .invalidRequest("Unauthorized"), extraHeaders: [HTTPHeaderName.wwwAuthenticate: "Bearer"])
        }
        // DNS-rebinding defence: only accept loopback Host headers.
        if let host = request.header(HTTPHeaderName.host)?.lowercased() {
            let name = host.split(separator: ":").first.map(String.init) ?? host
            guard ["127.0.0.1", "localhost", "[::1]"].contains(name) else {
                return .error(statusCode: 403, .invalidRequest("Forbidden host"))
            }
        }

        let sid = request.header(HTTPHeaderName.sessionID)
        if let sid, var s = sessions[sid] {
            s.lastAccess = Date()
            sessions[sid] = s
            let response = await s.transport.handleRequest(request)
            if request.method.uppercased() == "DELETE", response.statusCode == 200 {
                sessions[sid] = nil
            }
            return response
        }

        if request.method.uppercased() == "POST", let body = request.body,
            Self.isInitialize(body)
        {
            return await newSession(for: request)
        }
        if sid != nil { return .error(statusCode: 404, .invalidRequest("Session not found or expired")) }
        return .error(statusCode: 400, .invalidRequest("Missing \(HTTPHeaderName.sessionID) header"))
    }

    /// True for a single JSON-RPC request whose method is `initialize` (JSONRPCMessageKind is package-private in the SDK).
    static func isInitialize(_ body: Data) -> Bool {
        guard let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return false }
        return obj["method"] as? String == "initialize" && obj["id"] != nil
    }

    private struct FixedID: SessionIDGenerator {
        let id: String
        func generateSessionID() -> String { id }
    }

    private func newSession(for request: HTTPRequest) async -> HTTPResponse {
        let id = UUID().uuidString
        let transport = StatefulHTTPServerTransport(sessionIDGenerator: FixedID(id: id))
        let server = Server(
            name: "DT MCP Client", version: "0.1.0",
            instructions: "Generate images with a Draw Things server. Call get_server_status first.",
            capabilities: .init(tools: .init(listChanged: false)))
        let toolbox = self.toolbox
        await server.withMethodHandler(ListTools.self) { _ in .init(tools: MCPToolbox.tools) }
        await server.withMethodHandler(CallTool.self) { params in
            await toolbox.call(params.name, params.arguments)
        }
        do {
            try await server.start(transport: transport)
            sessions[id] = Session(server: server, transport: transport, lastAccess: Date())
            let response = await transport.handleRequest(request)
            if case .error = response { sessions[id] = nil; await transport.disconnect() }
            return response
        } catch {
            await transport.disconnect()
            return .error(statusCode: 500, .internalError("Failed to create session"))
        }
    }
}

// MARK: - NIO adapter

private final class HTTPHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let app: MCPHTTPServer
    private var head: HTTPRequestHead?
    private var body = ByteBuffer()

    init(app: MCPHTTPServer) { self.app = app }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let h):
            head = h
            body.clear()
        case .body(var b):
            // Tool calls are small; refuse anything over 8 MiB.
            if body.readableBytes + b.readableBytes > 8 * 1024 * 1024 { context.close(promise: nil); return }
            body.writeBuffer(&b)
        case .end:
            guard let h = head else { return }
            head = nil
            let bytes = body.readableBytes > 0 ? Data(body.readableBytesView) : nil
            nonisolated(unsafe) let ctx = context
            Task { await self.respond(head: h, body: bytes, context: ctx) }
        }
    }

    private func respond(head h: HTTPRequestHead, body: Data?, context ctx: ChannelHandlerContext) async {
        let path = h.uri.split(separator: "?").first.map(String.init) ?? h.uri
        guard path == MCPHTTPServer.endpoint else {
            return await write(.error(statusCode: 404, .invalidRequest("Not Found")), h.version, ctx)
        }
        var headers: [String: String] = [:]
        for (n, v) in h.headers { headers[n] = headers[n].map { $0 + ", " + v } ?? v }
        let req = HTTPRequest(method: h.method.rawValue, headers: headers, body: body, path: path)
        await write(await app.handle(req), h.version, ctx)
    }

    private func write(_ response: HTTPResponse, _ version: HTTPVersion, _ ctx: ChannelHandlerContext) async {
        nonisolated(unsafe) let ctx = ctx
        let loop = ctx.eventLoop
        let status = HTTPResponseStatus(statusCode: response.statusCode)
        let headers = response.headers

        func makeHead() -> HTTPResponseHead {
            var h = HTTPResponseHead(version: version, status: status)
            for (n, v) in headers { h.headers.add(name: n, value: v) }
            return h
        }

        if case .stream(let stream, _) = response {
            loop.execute {
                ctx.write(self.wrapOutboundOut(.head(makeHead())), promise: nil)
                ctx.flush()
            }
            do {
                for try await chunk in stream {
                    loop.execute {
                        var buf = ctx.channel.allocator.buffer(capacity: chunk.count)
                        buf.writeBytes(chunk)
                        ctx.writeAndFlush(self.wrapOutboundOut(.body(.byteBuffer(buf))), promise: nil)
                    }
                }
            } catch {}
            loop.execute { ctx.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: nil) }
        } else {
            let data = response.bodyData
            loop.execute {
                ctx.write(self.wrapOutboundOut(.head(makeHead())), promise: nil)
                if let data {
                    var buf = ctx.channel.allocator.buffer(capacity: data.count)
                    buf.writeBytes(data)
                    ctx.write(self.wrapOutboundOut(.body(.byteBuffer(buf))), promise: nil)
                }
                ctx.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: nil)
            }
        }
    }
}
