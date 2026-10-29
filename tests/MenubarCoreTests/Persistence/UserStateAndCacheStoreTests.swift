import Foundation
import Testing

@testable import MenubarCore

@Suite("UserStateStore")
struct UserStateStoreTests {
    private static let added = Date(timeIntervalSince1970: 1_800_000_000.5)

    @Test("each project's state round-trips in state.json, and the others are kept")
    func roundTrip() throws {
        let folder = try TemporaryFolder()
        let store = UserStateStore(folder: folder.url, report: { _ in })
        let other = ProjectID(rawValue: "other")!
        let state = UserState(
            watched: [WatchedJob(job: "MR-2", label: "!2", added: Self.added),
                      WatchedJob(job: "feature%252Ffoo", label: "feature/foo", added: Self.added)],
            hidden: ["MR-1": 7, "develop": 120])

        #expect(store.load(.main) == UserState())
        try store.save(state, for: .main)
        try store.save(UserState(hidden: ["MR-9": 1]), for: other)

        #expect(store.load(.main) == state)
        #expect(store.load(other) == UserState(hidden: ["MR-9": 1]))
        #expect(folder.contents() == ["state.json"])
        let json = try #require(try JSONSerialization.jsonObject(with: Data(folder.read("state.json").utf8)) as? [String: Any])
        #expect(json["formatVersion"] as? Int == UserStateStore.formatVersion)
        #expect(Set((json["projects"] as? [String: Any] ?? [:]).keys) == ["main", "other"])
    }

    @Test("update changes the state and saves it")
    func update() throws {
        let folder = try TemporaryFolder()
        let store = UserStateStore(folder: folder.url, report: { _ in })

        let state = try store.update(.main) { $0.hidden["MR-1"] = 7 }
        try store.update(.main) { $0.watched.append(WatchedJob(job: "MR-2", label: "!2", added: Self.added)) }

        #expect(state == UserState(hidden: ["MR-1": 7]))
        #expect(store.load(.main) == UserState(watched: [WatchedJob(job: "MR-2", label: "!2", added: Self.added)],
                                               hidden: ["MR-1": 7]))
    }

    @Test("a corrupt state.json counts as empty and is reported")
    func corrupt() throws {
        let folder = try TemporaryFolder()
        let reports = FileStoreTests.Reports()
        try folder.write(#"{"formatVersion": 1, "projects": {"main": {"watched": "MR-1"}}}"#, to: "state.json")
        let store = UserStateStore(folder: folder.url, report: reports.add)

        #expect(store.load(.main) == UserState())
        #expect(reports.all.count == 1)
        #expect(reports.all.first?.contains("state.json") == true)
    }
}

@Suite("CacheStore")
struct CacheStoreTests {
    private static let fetchedAt = Date(timeIntervalSince1970: 1_800_000_000.25)

    private static let mergeRequests = MergeRequestList(username: "me", mergeRequests: [
        MergeRequest(iid: 1, title: "t", webURL: URL(string: "https://gitlab.example.com/g/p/-/merge_requests/1")!,
                     reference: "g/p!1", author: MergeRequest.Person(username: "me", name: "Me"), updatedAt: fetchedAt,
                     roles: [.authored]),
    ])

    @Test("a cached answer round-trips with when it was fetched and its problem")
    func roundTrip() throws {
        let folder = try TemporaryFolder()
        let store = CacheStore(folder: folder.url, report: { _ in })
        let cached = Cached(value: Self.mergeRequests, fetchedAt: Self.fetchedAt, problem: .unreachable(.gitLab))

        #expect(store.load(.mergeRequestList, for: .main) == nil)
        try store.save(cached, as: .mergeRequestList, for: .main)
        try store.save(Cached(value: [3, 5], fetchedAt: Self.fetchedAt), as: .mergedMergeRequests, for: .main)

        #expect(store.load(.mergeRequestList, for: .main) == cached)
        #expect(store.load(.mergedMergeRequests, for: .main) == Cached(value: [3, 5], fetchedAt: Self.fetchedAt))
        #expect(folder.contents() == ["main/merge-request-list.json", "main/merged-merge-requests.json"])
    }

    @Test("the caches of each project stay apart, and delete removes one file or all of a project")
    func projectsStayApart() throws {
        let folder = try TemporaryFolder()
        let store = CacheStore(folder: folder.url, report: { _ in })
        let other = ProjectID(rawValue: "other")!
        let cached = Cached(value: [1], fetchedAt: Self.fetchedAt)
        try store.save(cached, as: .mergedMergeRequests, for: .main)
        try store.save(Cached(value: Self.mergeRequests, fetchedAt: Self.fetchedAt), as: .mergeRequestList, for: .main)
        try store.save(cached, as: .mergedMergeRequests, for: other)

        try store.delete(.mergeRequestList, for: .main)
        #expect(store.load(.mergeRequestList, for: .main) == nil)
        #expect(store.load(.mergedMergeRequests, for: .main) == cached)

        try store.deleteAll(for: .main)
        try store.deleteAll(for: .main)
        #expect(folder.contents() == ["other/merged-merge-requests.json"])
        #expect(store.url(of: .mergeRequestList, for: other) == folder.url.appending(path: "other/merge-request-list.json"))
    }

    @Test("a corrupt cache file counts as empty and is reported")
    func corrupt() throws {
        let folder = try TemporaryFolder()
        let reports = FileStoreTests.Reports()
        try folder.write(#"{"value": [1], "problem": null}"#, to: "main/merged-merge-requests.json")
        let store = CacheStore(folder: folder.url, report: reports.add)

        #expect(store.load(.mergedMergeRequests, for: .main) == nil)
        #expect(reports.all.count == 1)
        #expect(reports.all.first?.contains("fetchedAt") == true)
    }
}

@Suite("FileLocations")
struct FileLocationsTests {
    @Test("the folders are in the Library folder, named menubar-monitor")
    func standard() {
        let library = URL(filePath: "/Users/someone/Library", directoryHint: .isDirectory)
        let locations = FileLocations.standard(environment: [:], library: library)

        #expect(locations.applicationSupport.path(percentEncoded: false)
            == "/Users/someone/Library/Application Support/menubar-monitor/")
        #expect(locations.caches.path(percentEncoded: false) == "/Users/someone/Library/Caches/menubar-monitor/")
        #expect(locations.logs.path(percentEncoded: false) == "/Users/someone/Library/Logs/menubar-monitor/")
        #expect(locations.caches(for: .main).path(percentEncoded: false)
            == "/Users/someone/Library/Caches/menubar-monitor/main/")
    }

    @Test("MENUBAR_MONITOR_DATA_DIR moves every folder into it, unless it is empty")
    func dataDirectory() {
        let library = URL(filePath: "/Users/someone/Library", directoryHint: .isDirectory)
        let moved = FileLocations.standard(environment: ["MENUBAR_MONITOR_DATA_DIR": "/tmp/smoke/../smoke"], library: library)
        let empty = FileLocations.standard(environment: ["MENUBAR_MONITOR_DATA_DIR": ""], library: library)

        #expect(moved == FileLocations(root: URL(filePath: "/tmp/smoke", directoryHint: .isDirectory)))
        #expect(moved.applicationSupport.path(percentEncoded: false) == "/tmp/smoke/Application Support/")
        #expect(moved.caches.path(percentEncoded: false) == "/tmp/smoke/Caches/")
        #expect(moved.logs.path(percentEncoded: false) == "/tmp/smoke/Logs/")
        #expect(empty == FileLocations.standard(environment: [:], library: library))
    }
}
