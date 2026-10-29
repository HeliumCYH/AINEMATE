import Foundation
import Testing
@testable import AimateCore

@Suite("OpenCode approval wire shape")
struct OpenCodePermissionTests {
    private func request(
        action: String = "bash",
        resources: [String] = ["git push origin main"],
        message: String? = nil
    ) -> OpenCodePermission.Request {
        OpenCodePermission.Request(
            id: "r1", sessionID: "8a1f2c3d-0000-4000-8000-000000000000",
            action: action, resources: resources, message: message)
    }

    @Test("the discovery file wins over every guess")
    func discovery() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("oc-service-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("service.json")
        // The real file carries `id` and `version` too; extra keys must not matter.
        try Data(#"{"id":"x","version":"2.2.1","url":"http://127.0.0.1:49374","pid":90044,"password":"pw"}"#.utf8)
            .write(to: file)
        let service = try #require(OpenCodePermission.service(from: file))
        #expect(service.url == "http://127.0.0.1:49374")
        #expect(service.pid == 90044)
        #expect(OpenCodePermission.authorization(service) == "Basic b3BlbmNvZGU6cHc=")
    }

    @Test("a missing discovery file is not a crash")
    func noDiscovery() {
        let file = URL(fileURLWithPath: "/nonexistent/aimate/service.json")
        #expect(OpenCodePermission.service(from: file) == nil)
    }

    @Test("locations ride in a deepObject query and stay escaped")
    func pendingURL() throws {
        let service = OpenCodePermission.Service(url: "http://127.0.0.1:1", password: "x")
        #expect(try #require(OpenCodePermission.pendingURL(service, directory: nil)).absoluteString
            == "http://127.0.0.1:1/api/permission/request")
        let url = try #require(
            OpenCodePermission.pendingURL(service, directory: "/Users/x/My Project & co"))
        #expect(url.absoluteString
            == "http://127.0.0.1:1/api/permission/request?location%5Bdirectory%5D=/Users/x/My%20Project%20%26%20co")
    }

    @Test("the reply goes to the session that asked")
    func replyURL() throws {
        let service = OpenCodePermission.Service(url: "http://127.0.0.1:1", password: "x")
        let url = try #require(OpenCodePermission.replyURL(service, request: request()))
        #expect(url.path
            == "/api/session/8a1f2c3d-0000-4000-8000-000000000000/permission/r1/reply")
    }

    @Test("only the card labels ever become a decision")
    func decisions() throws {
        func decision(_ option: String) -> String? {
            guard let body = OpenCodePermission.replyBody(forOption: option),
                  let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
            else { return nil }
            return object["decision"] as? String
        }
        // The labels are drawn in this order, and a two-call card reads the same
        // whether or not the third exists — the wire values are OpenCode's own.
        #expect(OpenCodePermission.options
            == ["允许一次", "始终允许", "拒绝"])
        #expect(decision(OpenCodePermission.allowOption) == "once")
        #expect(decision(OpenCodePermission.alwaysOption) == "always")
        #expect(decision(OpenCodePermission.denyOption) == "reject")
        #expect(decision("允许") == nil)
        #expect(decision("always") == nil)
    }

    @Test("the headline is the action's own words")
    func titles() {
        #expect(OpenCodePermission.title(for: request()) == "git push origin main")
        #expect(OpenCodePermission.title(for: request(resources: [], message: "需要读取 .env"))
            == "需要读取 .env")
        #expect(OpenCodePermission.title(for: request(resources: [], message: nil))
            == "bash 请求批准")
        let long = String(repeating: "a", count: 100)
        #expect(OpenCodePermission.title(for: request(resources: [long])).count == 73)
        #expect(OpenCodePermission.title(for: request(resources: ["rm -rf /\nnow"])) == "rm -rf / now")
    }

    @Test("the footnote does not repeat the headline")
    func details() {
        #expect(OpenCodePermission.detail(for: request()) == "bash")
        #expect(OpenCodePermission.detail(for: request(resources: [], message: "需要读取 .env"))
            == "bash")
        #expect(OpenCodePermission.detail(for: request(message: "需要读取 .env"))
            == "bash · 需要读取 .env")
    }

    @Test("the card id is stable and outside every adapter namespace")
    func actorIDs() {
        let id = OpenCodePermission.actorID(for: request())
        #expect(id == "ask:opencode:8a1f2c3d:r1")
        #expect(id == OpenCodePermission.actorID(for: request(message: "different details")))
    }

    @Test("a stale server pid reads as not running")
    func liveness() {
        #expect(OpenCodePermission.isRunning(.init(url: "u", pid: 0, password: "p")))
        #expect(!OpenCodePermission.isRunning(.init(url: "u", pid: 99_999_999, password: "p")))
    }
}
