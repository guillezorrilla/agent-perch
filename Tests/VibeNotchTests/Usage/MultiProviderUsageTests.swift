import Foundation
import XCTest
@testable import VibeNotch

/// Nothing here touches the network or spawns a process: every source takes its transport or its
/// subprocess runner by injection, exactly as the Claude and Codex sources already did.
///
/// The Antigravity and Kiro fixtures are REAL captured output from this machine, with tokens
/// replaced by placeholders (#18).

// MARK: - Shared doubles

private final class StubLoader: UsageLoading, @unchecked Sendable {
    /// Keyed by the request URL's port, so one loader can stand in for a whole candidate list.
    private let lock = NSLock()
    private var responses: [Int: (status: Int, body: Data)]
    private var recorded: [(port: Int, csrf: String?)] = []

    init(responses: [Int: (status: Int, body: Data)]) { self.responses = responses }

    var calls: [(port: Int, csrf: String?)] { lock.withLock { recorded } }

    func stopAnswering(port: Int) { lock.withLock { responses[port] = nil } }
    func answer(port: Int, with body: Data) { lock.withLock { responses[port] = (200, body) } }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        // `URL.port` is nil unless the URL spells one out, and every URL here is https.
        let port = request.url?.port ?? 443
        lock.withLock {
            recorded.append((port, request.value(forHTTPHeaderField: "X-Codeium-Csrf-Token")))
        }
        guard let response = lock.withLock({ responses[port] }) else {
            throw URLError(.cannotConnectToHost)
        }
        let http = HTTPURLResponse(
            url: request.url!,
            statusCode: response.status,
            httpVersion: nil,
            headerFields: nil
        )!
        return (response.body, http)
    }
}

// MARK: - Model (#18)

final class UsageWindowModelTests: XCTestCase {
    /// The two new fields default away, so every Claude and Codex construction site is untouched.
    func testANewWindowIsNeitherAnEstimateNorHasAReserveUnlessItSaysSo() {
        let window = UsageWindow(label: "5h", utilization: 12, resetsAt: Date())
        XCTAssertNil(window.reserve)
        XCTAssertFalse(window.isEstimate)
        XCTAssertNil(ProviderUsage(provider: "Claude", windows: [window]).detail)
    }

    func testAProviderMayCarryAnyNumberOfWindows() {
        let windows = (0..<4).map { UsageWindow(label: "w\($0)", utilization: Double($0), resetsAt: Date()) }
        XCTAssertEqual(ProviderUsage(provider: "Antigravity", windows: windows).windows.count, 4)
    }
}

// MARK: - Antigravity: parsing

final class AntigravityQuotaParserTests: XCTestCase {
    /// Byte-for-byte the payload the running language server returned on this machine, via
    /// `POST https://127.0.0.1:50354/exa.language_server_pb.LanguageServerService/RetrieveUserQuotaSummary`.
    static let liveSummary = Data(#"""
    {"response":{"groups":[
      {"displayName":"Gemini Models","description":"Models within this group: Gemini Flash, Gemini Pro",
       "buckets":[
         {"bucketId":"gemini-weekly","displayName":"Weekly Limit Remaining","window":"weekly","remainingFraction":1,"resetTime":"2026-08-18T01:25:07Z"},
         {"bucketId":"gemini-5h","displayName":"Five Hour Limit Remaining","window":"5h","remainingFraction":1,"resetTime":"2026-08-11T09:17:58Z"}]},
      {"displayName":"Claude and GPT models","description":"Models within this group: Claude Opus, Claude Sonnet, GPT-OSS",
       "buckets":[
         {"bucketId":"3p-weekly","displayName":"Weekly Limit Remaining","window":"weekly","remainingFraction":1,"resetTime":"2026-08-18T04:17:58Z"},
         {"bucketId":"3p-5h","displayName":"Five Hour Limit Remaining","window":"5h","remainingFraction":1,"resetTime":"2026-08-11T09:17:58Z"}]}],
     "description":"Within each group, models share a weekly limit and a 5-hour limit."}}
    """#.utf8)

    func testParsesEveryBucketOfTheRealLivePayload() throws {
        let usage = try AntigravityQuotaParser.parse(Self.liveSummary)

        XCTAssertEqual(usage.provider, "Antigravity")
        XCTAssertEqual(usage.windows.map(\.label), ["Gem 7d", "Gem 5h", "C/GPT 7d", "C/GPT 5h"])
        // The summary carries no tier or plan field at all — so the row claims none.
        XCTAssertNil(usage.detail)
        XCTAssertEqual(
            usage.windows[0].resetsAt,
            ISO8601DateFormatter().date(from: "2026-08-18T01:25:07Z")
        )
    }

    /// `remainingFraction` is what is LEFT; the strip everywhere else means what is SPENT. Getting
    /// this backwards would have shown a full quota as an exhausted one.
    func testRemainingFractionIsInvertedIntoUtilization() throws {
        let usage = try AntigravityQuotaParser.parse(Self.liveSummary)
        XCTAssertEqual(usage.windows.map(\.utilization), [0, 0, 0, 0])

        let partial = try AntigravityQuotaParser.parse(Data(#"""
        {"response":{"groups":[{"displayName":"Gemini Models","buckets":[
          {"bucketId":"gemini-weekly","window":"weekly","remainingFraction":0.88,"resetTime":"2026-08-18T01:25:07Z"}]}]}}
        """#.utf8))
        XCTAssertEqual(partial.windows[0].utilization, 12, accuracy: 0.0001)
    }

    /// The recipe this was built from described a bare `groups[]`; the live server wraps it in
    /// `response`. Both work, so neither shape can break the row.
    func testAcceptsBothTheWrappedAndTheBareShape() throws {
        let bare = try AntigravityQuotaParser.parse(Data(#"""
        {"groups":[{"displayName":"Gemini Models","buckets":[
          {"bucketId":"gemini-5h","window":"5h","remainingFraction":0.5,"resetTime":"2026-08-11T09:17:58Z"}]}]}
        """#.utf8))
        XCTAssertEqual(bare.windows.map(\.label), ["Gem 5h"])
        XCTAssertEqual(bare.windows[0].utilization, 50, accuracy: 0.0001)
    }

    func testDisabledBucketsAreLeftOut() throws {
        let usage = try AntigravityQuotaParser.parse(Data(#"""
        {"response":{"groups":[{"displayName":"Gemini Models","buckets":[
          {"bucketId":"gemini-5h","window":"5h","remainingFraction":0.5,"resetTime":"2026-08-11T09:17:58Z"},
          {"bucketId":"gemini-weekly","window":"weekly","remainingFraction":0.9,"resetTime":"2026-08-18T01:25:07Z","disabled":true}]}]}}
        """#.utf8))
        XCTAssertEqual(usage.windows.map(\.label), ["Gem 5h"])
    }

    /// Antigravity IDE 1.107.0 never sends a reserve, but a bucket that did must render one rather
    /// than need a model change.
    func testAReserveFractionIsCarriedThroughWhenAServerSendsOne() throws {
        let usage = try AntigravityQuotaParser.parse(Data(#"""
        {"response":{"groups":[{"displayName":"Gemini Models","buckets":[
          {"bucketId":"gemini-weekly","window":"weekly","remainingFraction":0.88,"reserveFraction":0.75,"resetTime":"2026-08-18T01:25:07Z"}]}]}}
        """#.utf8))
        XCTAssertEqual(usage.windows[0].reserve ?? 0, 75, accuracy: 0.0001)
    }

    /// No usable bucket is not "0% used". Inventing a number here is the one thing #18 forbids.
    func testAnAnswerWithNoUsableBucketsThrowsRatherThanReportingZero() {
        XCTAssertThrowsError(try AntigravityQuotaParser.parse(Data(#"{"response":{"groups":[]}}"#.utf8)))
        XCTAssertThrowsError(try AntigravityQuotaParser.parse(Data(#"""
        {"response":{"groups":[{"displayName":"Gemini Models","buckets":[
          {"bucketId":"gemini-5h","window":"5h","resetTime":"2026-08-11T09:17:58Z"}]}]}}
        """#.utf8)), "a bucket with no remainingFraction has no number to show")
        XCTAssertThrowsError(try AntigravityQuotaParser.parse(Data("not json".utf8)))
    }

    func testLabelsAbbreviateKnownFamiliesAndStillNameUnknownOnes() {
        XCTAssertEqual(AntigravityQuotaParser.label(group: "Gemini Models", bucketId: "gemini-5h", window: "5h"), "Gem 5h")
        XCTAssertEqual(
            AntigravityQuotaParser.label(group: "Claude and GPT models", bucketId: "3p-weekly", window: "weekly"),
            "C/GPT 7d"
        )
        // A family Antigravity has not shipped yet still gets a label, never an empty one.
        XCTAssertEqual(AntigravityQuotaParser.groupLabel(group: "Grok Models", bucketId: "grok-5h"), "Grok")
        XCTAssertEqual(AntigravityQuotaParser.windowLabel("daily"), "1d")
        XCTAssertEqual(AntigravityQuotaParser.windowLabel("3h"), "3h")
        XCTAssertEqual(AntigravityQuotaParser.windowLabel(nil), "")
    }
}

// MARK: - Antigravity: discovery

final class AntigravityProcessScanTests: XCTestCase {
    /// Real `ps -Aww -o pid=,args=` lines from this machine, UUIDs replaced.
    static let psOutput = """
     6867 /Applications/Antigravity IDE.app/Contents/Frameworks/Electron Framework.framework/Helpers/chrome_crashpad_handler --no-rate-limit
    14365 /Applications/Antigravity IDE.app/Contents/MacOS/Electron
    14732 /Applications/Antigravity IDE.app/Contents/Resources/app/extensions/antigravity/bin/language_server_macos_arm --csrf_token 00000000-aaaa-4000-8000-000000000001 --extension_server_port 50345 --extension_server_csrf_token 00000000-bbbb-4000-8000-000000000002 --app_data_dir antigravity-ide --subclient_type ide
    14986 /Applications/Antigravity IDE.app/Contents/Resources/app/extensions/antigravity/bin/language_server_macos_arm --enable_lsp --csrf_token 00000000-cccc-4000-8000-000000000003 --extension_server_port 50409 --extension_server_csrf_token 00000000-dddd-4000-8000-000000000004
    23001 /Applications/Claude.app/Contents/MacOS/Electron --csrf_token 00000000-eeee-4000-8000-000000000005
    """

    /// Real `lsof -nP -iTCP -sTCP:LISTEN` rows.
    static let lsofOutput = """
    language_ 14732 gzorrilla    6u  IPv4 0xe9b557ef125b253b      0t0  TCP 127.0.0.1:50354 (LISTEN)
    language_ 14732 gzorrilla    7u  IPv4 0xc8b448e2468edfa0      0t0  TCP 127.0.0.1:50355 (LISTEN)
    Antigravi 14733 gzorrilla   35u  IPv6 0x7023b970ffd3a464      0t0  TCP *:50591 (LISTEN)
    language_ 14986 gzorrilla    6u  IPv4 0x12ae4be4925bf90b      0t0  TCP 127.0.0.1:50479 (LISTEN)
    Company   99999 gzorrilla    5u  IPv4 0x1111111111111111      0t0  TCP 127.0.0.1:8080 (ESTABLISHED)
    """

    func testPairsEveryAntigravityProcessWithItsLoopbackPorts() {
        let endpoints = AntigravityProcessScan.endpointCandidates(
            psOutput: Self.psOutput,
            lsofOutput: Self.lsofOutput
        )
        XCTAssertEqual(endpoints, [
            AntigravityEndpoint(port: 50354, csrfToken: "00000000-aaaa-4000-8000-000000000001"),
            AntigravityEndpoint(port: 50355, csrfToken: "00000000-aaaa-4000-8000-000000000001"),
            AntigravityEndpoint(port: 50479, csrfToken: "00000000-cccc-4000-8000-000000000003")
        ])
    }

    /// The trap this repo already fell into once (#27): matching the process NAME finds nothing,
    /// and a bare `Electron` match sweeps up every other Electron app.
    func testMatchesTheBundlePathAndRefusesAnotherAppsElectron() {
        let pids = AntigravityProcessScan.csrfTokens(psOutput: Self.psOutput).map(\.pid)
        XCTAssertEqual(pids, [14732, 14986], "Claude.app's Electron carries a csrf_token too")
    }

    /// `--csrf_token` must never come back holding `--extension_server_csrf_token`'s value.
    func testFlagLookupIsAWholeFieldMatch() {
        let args = "/x --extension_server_csrf_token EXT --csrf_token MAIN"
        XCTAssertEqual(AntigravityProcessScan.flagValue("--csrf_token", in: args), "MAIN")
        XCTAssertEqual(AntigravityProcessScan.flagValue("--extension_server_csrf_token", in: args), "EXT")
        XCTAssertNil(AntigravityProcessScan.flagValue("--csrf_token", in: "/x --csrf_token --next"))
        XCTAssertNil(AntigravityProcessScan.flagValue("--csrf_token", in: "/x --csrf_token"))
    }

    /// Some launches carry only the extension server's token.
    func testFallsBackToTheExtensionServerToken() {
        let ps = "14732 /Applications/Antigravity IDE.app/x/language_server --extension_server_csrf_token ONLY-ONE"
        let lsof = "language_ 14732 me 6u IPv4 0x1 0t0 TCP 127.0.0.1:1234 (LISTEN)"
        XCTAssertEqual(
            AntigravityProcessScan.endpointCandidates(psOutput: ps, lsofOutput: lsof),
            [AntigravityEndpoint(port: 1234, csrfToken: "ONLY-ONE")]
        )
    }

    /// A CSRF token must never be sent anywhere but loopback, so a wildcard bind is not a
    /// candidate — and neither is a socket that isn't listening.
    func testOnlyLoopbackListenersBecomeCandidates() {
        let ports = AntigravityProcessScan.listeningPorts(lsofOutput: Self.lsofOutput)
        XCTAssertEqual(ports[14732], [50354, 50355])
        XCTAssertNil(ports[14733], "*:50591 is bound on every interface")
        XCTAssertNil(ports[99999], "ESTABLISHED is not LISTEN")
    }

    func testCandidateListIsCapped() {
        let ps = (0..<40).map { "\(1000 + $0) /Applications/Antigravity.app/x --csrf_token T\($0)" }.joined(separator: "\n")
        let lsof = (0..<40).map { "x \(1000 + $0) me 6u IPv4 0x1 0t0 TCP 127.0.0.1:\(2000 + $0) (LISTEN)" }
            .joined(separator: "\n")
        XCTAssertEqual(AntigravityProcessScan.endpointCandidates(psOutput: ps, lsofOutput: lsof).count, 12)
    }
}

// MARK: - Antigravity: source

final class AntigravityUsageSourceTests: XCTestCase {
    private func makeSource(
        installed: Bool = true,
        endpoints: [AntigravityEndpoint],
        loader: UsageLoading
    ) -> AntigravityUsageSource {
        AntigravityUsageSource(loader: loader, isInstalled: { installed }, discover: { endpoints })
    }

    private var goodBody: Data { AntigravityQuotaParserTests.liveSummary }

    func testNotInstalledOmitsTheProviderEntirely() async {
        let source = makeSource(installed: false, endpoints: [], loader: StubLoader(responses: [:]))
        let availability = await source.availability()
        XCTAssertEqual(availability, .notConfigured)
    }

    /// Installed but not running is a provider that exists and cannot answer — a visible,
    /// retryable row, never a silent disappearance (#28).
    func testInstalledButNotRunningStaysOnTheStripAndSaysSo() async {
        let source = makeSource(endpoints: [], loader: StubLoader(responses: [:]))
        let availability = await source.availability()
        XCTAssertEqual(availability, .unavailable("Antigravity not running"))
    }

    func testWalksPastCandidatesThatCannotAnswerAndSendsTheCsrfTokenOfTheOneThatCan() async throws {
        // 50355 refuses the connection outright, exactly as the dead sibling port does live.
        let loader = StubLoader(responses: [50354: (200, goodBody)])
        let source = makeSource(
            endpoints: [
                AntigravityEndpoint(port: 50355, csrfToken: "tok-a"),
                AntigravityEndpoint(port: 50354, csrfToken: "tok-a")
            ],
            loader: loader
        )

        let usage = try await source.fetch()
        XCTAssertEqual(usage.windows.count, 4)
        XCTAssertEqual(loader.calls.map(\.port), [50355, 50354])
        XCTAssertEqual(loader.calls.last?.csrf, "tok-a")
    }

    /// Discovery is a `ps` plus an `lsof`; the endpoint that answered is remembered so the strip's
    /// next hover does neither.
    func testTheWorkingEndpointIsCachedAndSkipsRediscovery() async throws {
        final class CountingDiscovery: @unchecked Sendable {
            private let lock = NSLock()
            private var count = 0
            func next() -> [AntigravityEndpoint] {
                lock.withLock { count += 1 }
                return [AntigravityEndpoint(port: 50354, csrfToken: "tok-a")]
            }
            var calls: Int { lock.withLock { count } }
        }
        let discovery = CountingDiscovery()
        let source = AntigravityUsageSource(
            loader: StubLoader(responses: [50354: (200, goodBody)]),
            isInstalled: { true },
            discover: { discovery.next() }
        )

        let observed1 = await source.availability()
        XCTAssertEqual(observed1, .ready)
        _ = try await source.fetch()
        let observed2 = await source.availability()
        XCTAssertEqual(observed2, .ready)
        _ = try await source.fetch()
        XCTAssertEqual(discovery.calls, 1, "the cached endpoint answers without another ps/lsof")
    }

    /// A relaunched IDE listens on a new port. The stale one must be dropped, not retried forever.
    func testACachedEndpointThatStopsAnsweringIsForgottenSoTheNextPassRediscovers() async throws {
        final class MutableDiscovery: @unchecked Sendable {
            private let lock = NSLock()
            private var endpoints: [AntigravityEndpoint]
            init(_ endpoints: [AntigravityEndpoint]) { self.endpoints = endpoints }
            func current() -> [AntigravityEndpoint] { lock.withLock { endpoints } }
            func set(_ endpoints: [AntigravityEndpoint]) { lock.withLock { self.endpoints = endpoints } }
        }

        let loader = StubLoader(responses: [50354: (200, goodBody)])
        let discovery = MutableDiscovery([AntigravityEndpoint(port: 50354, csrfToken: "tok-a")])
        let source = AntigravityUsageSource(
            loader: loader,
            isInstalled: { true },
            discover: { discovery.current() }
        )
        _ = try await source.fetch()

        // The IDE relaunches: the remembered port goes quiet and a different one comes up.
        loader.stopAnswering(port: 50354)
        loader.answer(port: 60001, with: goodBody)
        do {
            _ = try await source.fetch()
            XCTFail("the stale endpoint cannot answer, so there is nothing to report")
        } catch {}

        discovery.set([AntigravityEndpoint(port: 60001, csrfToken: "tok-b")])
        let readyAgain = await source.availability()
        XCTAssertEqual(readyAgain, .ready)

        let usage = try await source.fetch()
        XCTAssertEqual(usage.windows.count, 4)
        XCTAssertEqual(loader.calls.last?.port, 60001)
        XCTAssertEqual(loader.calls.last?.csrf, "tok-b")
    }

    func testAnHTTPErrorFromEveryCandidateThrowsRatherThanShowingANumber() async {
        let loader = StubLoader(responses: [50354: (401, Data(#"{"code":"unauthenticated"}"#.utf8))])
        let source = makeSource(endpoints: [AntigravityEndpoint(port: 50354, csrfToken: "bad")], loader: loader)
        do {
            _ = try await source.fetch()
            XCTFail("a 401 is not a quota reading")
        } catch {}
    }
}

// MARK: - Kiro

final class KiroUsageParserTests: XCTestCase {
    /// Real `kiro-cli chat --no-interactive "/usage"` output from this machine, escape sequences
    /// intact and the progress bar shortened.
    static let liveUsage = """
    \n\u{1B}[1mEstimated Usage\u{1B}[0m | resets on 2026-09-01 | \u{1B}[38;5;141mKIRO FREE\u{1B}[0m
    \u{1B}[1mCredits\u{1B}[0m (0.00 of 50 covered in plan)
    \u{1B}[38;5;141m\u{1B}[38;5;244m████████\u{1B}[0m 0%

    To manage your plan navigate to \u{1B}[38;5;141mhttps://app.kiro.dev/account/usage\u{1B}[0m

    Tip: to see context window usage, run \u{1B}[38;5;141m/context\u{1B}[0m

    \u{1B}[1G\u{1B}[0m\u{1B}[0m\u{1B}[?25h
    """

    func testStripsEveryFlavourOfEscapeSequence() {
        let stripped = KiroUsageParser.stripANSI(Self.liveUsage)
        XCTAssertFalse(stripped.contains("\u{1B}"))
        XCTAssertTrue(stripped.contains("Estimated Usage | resets on 2026-09-01 | KIRO FREE"))
        // Colour, bold, cursor-column and the private-mode cursor toggle all go.
        XCTAssertEqual(KiroUsageParser.stripANSI("\u{1B}[38;5;141ma\u{1B}[0mb\u{1B}[1Gc\u{1B}[?25hd"), "abcd")
    }

    func testParsesTheRealUsageOutput() throws {
        let usage = try XCTUnwrap(KiroUsageParser.parse(Self.liveUsage, timeZone: TimeZone(identifier: "UTC")!))

        XCTAssertEqual(usage.plan, "KIRO FREE")
        XCTAssertEqual(usage.usedCredits, 0)
        XCTAssertEqual(usage.totalCredits, 50)
        XCTAssertEqual(usage.percentUsed, 0)
        XCTAssertEqual(usage.resetsAt, ISO8601DateFormatter().date(from: "2026-09-01T00:00:00Z"))
        XCTAssertTrue(usage.isEstimate, "Kiro heads its own output 'Estimated Usage'")
    }

    /// The row must carry the estimate marker all the way to the strip, plus the plan Kiro names.
    func testTheProviderRowIsMarkedAsAnEstimate() throws {
        let parsed = try XCTUnwrap(KiroUsageParser.parse(Self.liveUsage))
        let usage = KiroUsageParser.providerUsage(from: parsed)

        XCTAssertEqual(usage.provider, "Kiro")
        XCTAssertEqual(usage.windows.count, 1)
        XCTAssertEqual(usage.windows[0].label, "mo")
        XCTAssertTrue(usage.windows[0].isEstimate)
        XCTAssertEqual(usage.detail, "KIRO FREE 0/50")
    }

    /// The exact ratio beats the bar's rounded percentage.
    func testPercentComesFromTheCreditRatioNotTheRoundedBar() throws {
        let text = """
        Estimated Usage | resets on 2026-09-01 | KIRO PRO
        Credits (137.50 of 1,000 covered in plan)
        ████ 14%
        """
        let usage = try XCTUnwrap(KiroUsageParser.parse(text))
        XCTAssertEqual(usage.percentUsed, 13.75, accuracy: 0.0001)
        XCTAssertEqual(usage.totalCredits, 1_000, "thousands separators must not truncate the total")
        XCTAssertEqual(usage.plan, "KIRO PRO")
    }

    func testFallsBackToThePrintedPercentWhenThereIsNoCreditsLine() throws {
        let usage = try XCTUnwrap(KiroUsageParser.parse("Usage | resets on 2026-09-01\n████ 42%"))
        XCTAssertEqual(usage.percentUsed, 42)
        XCTAssertFalse(usage.isEstimate, "no 'Estimated' in the output, so no hedge on the number")
        XCTAssertNil(usage.plan)
    }

    /// Output that yields no number must yield no row. A missing figure is not zero (#18).
    func testOutputWithoutANumberOrADateIsNotAZeroPercentRow() {
        XCTAssertNil(KiroUsageParser.parse("Estimated Usage | resets on 2026-09-01\nnothing useful here"))
        XCTAssertNil(KiroUsageParser.parse("Credits (0.00 of 50 covered in plan)"), "no reset date")
        XCTAssertNil(KiroUsageParser.parse(""))
        XCTAssertNil(KiroUsageParser.parse("You are not logged in."))
    }
}

private final class StubKiroRunner: KiroCommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var outputs: [String: String?]
    private var recorded: [[String]] = []

    init(outputs: [String: String?]) { self.outputs = outputs }

    var invocations: [[String]] { lock.withLock { recorded } }

    func run(_ arguments: [String], timeout: TimeInterval) -> String? {
        lock.withLock {
            recorded.append(arguments)
            return outputs[arguments.first ?? ""] ?? nil
        }
    }
}

final class KiroUsageSourceTests: XCTestCase {
    private var liveUsage: String { KiroUsageParserTests.liveUsage }

    func testNoCLIInstalledOmitsTheProvider() async {
        let source = KiroUsageSource(runner: nil)
        XCTAssertFalse(source.isAvailable())
        let observed4 = await source.availability()
        XCTAssertEqual(observed4, .notConfigured)
    }

    /// Installed but signed out is credentials that do not exist — omitted, not an error row.
    func testSignedOutOmitsTheProviderRatherThanShowingAnError() async {
        let source = KiroUsageSource(runner: StubKiroRunner(outputs: ["whoami": "You are not logged in."]))
        let observed5 = await source.availability()
        XCTAssertEqual(observed5, .notConfigured)
    }

    /// Not memoized: signing in later brings the row back on its own, like the Claude path.
    func testSignedOutIsRecheckedEveryTime() async {
        let runner = StubKiroRunner(outputs: ["whoami": "not logged in"])
        let source = KiroUsageSource(runner: runner)
        _ = await source.availability()
        _ = await source.availability()
        XCTAssertEqual(runner.invocations.count, 2)
    }

    func testAWhoamiThatNeverAnswersIsAVisibleRowNotADisappearance() async {
        let source = KiroUsageSource(runner: StubKiroRunner(outputs: ["whoami": nil]))
        let observed6 = await source.availability()
        XCTAssertEqual(observed6, .unavailable("kiro-cli not responding"))
    }

    func testASignedInMachineFetchesAndParses() async throws {
        let runner = StubKiroRunner(outputs: [
            "whoami": "Logged in with Builder ID\nEmail: someone@example.com",
            "chat": liveUsage
        ])
        let source = KiroUsageSource(runner: runner)

        let observed7 = await source.availability()
        XCTAssertEqual(observed7, .ready)
        let usage = try await source.fetch()
        XCTAssertEqual(usage.provider, "Kiro")
        XCTAssertTrue(usage.windows[0].isEstimate)
        XCTAssertEqual(runner.invocations.last, ["chat", "--no-interactive", "/usage"])
    }

    /// A confirmed login is remembered, so hovering the notch does not spawn a `whoami` each time.
    func testAConfirmedLoginIsNotRePolled() async {
        let runner = StubKiroRunner(outputs: ["whoami": "Logged in with Builder ID"])
        let source = KiroUsageSource(runner: runner)
        _ = await source.availability()
        _ = await source.availability()
        _ = await source.availability()
        XCTAssertEqual(runner.invocations.count, 1)
    }

    /// Each fetch is a subprocess that can take twenty seconds, so this provider throttles itself
    /// far harder than the HTTP ones (#18).
    func testTheCacheServesRepeatFetchesWithoutSpawningAgain() async throws {
        let runner = StubKiroRunner(outputs: ["whoami": "Logged in", "chat": liveUsage])
        let source = KiroUsageSource(runner: runner, ttl: 10 * 60.0)

        _ = try await source.fetch()
        _ = try await source.fetch()
        _ = try await source.fetch()
        XCTAssertEqual(runner.invocations.filter { $0.first == "chat" }.count, 1)
    }

    /// The user's own refresh is what genuinely re-runs the CLI.
    func testAnExplicitRetryClearsTheCache() async throws {
        let runner = StubKiroRunner(outputs: ["whoami": "Logged in", "chat": liveUsage])
        let source = KiroUsageSource(runner: runner)

        _ = try await source.fetch()
        source.prepareForRetry()
        _ = try await source.fetch()
        XCTAssertEqual(runner.invocations.filter { $0.first == "chat" }.count, 2)
    }

    func testUnparsableOutputThrowsRatherThanInventingANumber() async {
        let source = KiroUsageSource(runner: StubKiroRunner(outputs: ["whoami": "Logged in", "chat": "???"]))
        do {
            _ = try await source.fetch()
            XCTFail("no number could be read, so there is no row to show")
        } catch {}
    }
}

// MARK: - Gemini

final class GeminiUsageTests: XCTestCase {
    /// Placeholders, never a real token — the shape is all this fixture needs to carry.
    private static let credentialsJSON = Data(#"""
    {"access_token":"REDACTED-ACCESS-TOKEN","refresh_token":"REDACTED-REFRESH-TOKEN",
     "id_token":"REDACTED-ID-TOKEN","token_type":"Bearer","expiry_date":1786422855975.986}
    """#.utf8)

    private static let quotaJSON = Data(#"""
    {"buckets":[
      {"modelId":"gemini-2.5-pro","tokenType":"DAILY","remainingFraction":0.4,"resetTime":"2026-08-11T09:17:58Z"},
      {"modelId":"gemini-2.5-flash","tokenType":"DAILY","remainingFraction":1,"resetTime":"2026-08-11T09:17:58Z"}]}
    """#.utf8)

    private struct StubGeminiToken: GeminiTokenSource {
        var value: GeminiCredentials?
        func credentials() -> GeminiCredentials? { value }
    }

    private func geminiLoader(status: Int, body: Data) -> UsageLoading {
        // Gemini's endpoint has no port in its URL, so key the stub on 443.
        StubLoader(responses: [443: (status, body)])
    }

    func testParsesCredentialsWithoutTouchingTheRefreshOrIdToken() throws {
        let credentials = try GeminiCredentialParser.credentials(from: Self.credentialsJSON)
        XCTAssertEqual(credentials.accessToken, "REDACTED-ACCESS-TOKEN")
        XCTAssertEqual(credentials.expiryDate ?? 0, 1_786_422_855_975.986, accuracy: 1)
    }

    func testExpiryIsReadInMilliseconds() {
        let credentials = GeminiCredentials(accessToken: "t", expiryDate: 1_786_422_855_975)
        XCTAssertFalse(credentials.isExpired(at: Date(timeIntervalSince1970: 1_786_422_000)))
        XCTAssertTrue(credentials.isExpired(at: Date(timeIntervalSince1970: 1_786_423_000)))
        XCTAssertFalse(GeminiCredentials(accessToken: "t", expiryDate: nil).isExpired(at: Date()))
    }

    /// The live signals: this machine gets a 403 PERMISSION_DENIED for a perfectly valid token.
    func testGooglesRefusalsAreClassifiedAsIneligibleAndOutagesAsTransient() {
        let denied = Data(#"{"error":{"code":403,"message":"The caller does not have permission","status":"PERMISSION_DENIED"}}"#.utf8)
        XCTAssertEqual(GeminiEligibility.classify(status: 403, body: denied), .ineligible)
        XCTAssertEqual(GeminiEligibility.classify(status: 400, body: Data(#"{"error":"UNSUPPORTED_CLIENT"}"#.utf8)), .ineligible)
        XCTAssertEqual(GeminiEligibility.classify(status: 400, body: Data(#"{"error":"IneligibleTierError"}"#.utf8)), .ineligible)
        XCTAssertEqual(GeminiEligibility.classify(status: 200, body: Data()), .eligible)
        // A rate limit says nothing about eligibility, and neither does a 500.
        XCTAssertEqual(GeminiEligibility.classify(status: 429, body: Data()), .transient)
        XCTAssertEqual(GeminiEligibility.classify(status: 503, body: Data()), .transient)
    }

    func testParsesQuotaBuckets() throws {
        let usage = try GeminiQuotaParser.parse(Self.quotaJSON)
        XCTAssertEqual(usage.provider, "Gemini")
        XCTAssertEqual(usage.windows.map(\.label), ["2.5-pro daily", "2.5-flas daily"])
        XCTAssertEqual(usage.windows[0].utilization, 60, accuracy: 0.0001)
        XCTAssertThrowsError(try GeminiQuotaParser.parse(Data(#"{"buckets":[]}"#.utf8)))
    }

    func testNoCredentialsOmitsTheProvider() async {
        let source = GeminiUsageSource(
            tokenSource: StubGeminiToken(value: nil),
            loader: geminiLoader(status: 200, body: Self.quotaJSON)
        )
        let observed8 = await source.availability()
        XCTAssertEqual(observed8, .notConfigured)
    }

    /// Token refresh is not implemented, so an expired token is a provider we cannot serve — an
    /// omitted row, not a permanently broken one.
    func testAnExpiredTokenOmitsTheProvider() async {
        let source = GeminiUsageSource(
            tokenSource: StubGeminiToken(value: GeminiCredentials(accessToken: "t", expiryDate: 1_000)),
            loader: geminiLoader(status: 200, body: Self.quotaJSON),
            now: { Date(timeIntervalSince1970: 5_000) }
        )
        let observed9 = await source.availability()
        XCTAssertEqual(observed9, .notConfigured)
    }

    /// The behaviour this machine actually exhibits: hide the row, never flash an error first,
    /// because Antigravity already carries this account's numbers.
    func testAForbiddenAccountIsHiddenRatherThanShownAsBroken() async {
        let denied = Data(#"{"error":{"code":403,"status":"PERMISSION_DENIED"}}"#.utf8)
        let source = GeminiUsageSource(
            tokenSource: StubGeminiToken(value: GeminiCredentials(accessToken: "t", expiryDate: nil)),
            loader: geminiLoader(status: 403, body: denied)
        )
        let observed10 = await source.availability()
        XCTAssertEqual(observed10, .notConfigured)
    }

    /// One HTTP call, not two: the eligibility probe hands its payload straight to `fetch()`.
    func testAnEligibleAccountReusesTheProbeResponse() async throws {
        let loader = StubLoader(responses: [443: (200, Self.quotaJSON)])
        let source = GeminiUsageSource(
            tokenSource: StubGeminiToken(value: GeminiCredentials(accessToken: "t", expiryDate: nil)),
            loader: loader
        )

        let observed11 = await source.availability()
        XCTAssertEqual(observed11, .ready)
        let usage = try await source.fetch()
        XCTAssertEqual(usage.windows.count, 2)
        XCTAssertEqual(loader.calls.count, 1)
    }

    /// A 200 whose body cannot be read is not an account with no quota.
    func testAnUnreadableSuccessIsNotAZeroQuotaRow() async {
        let source = GeminiUsageSource(
            tokenSource: StubGeminiToken(value: GeminiCredentials(accessToken: "t", expiryDate: nil)),
            loader: geminiLoader(status: 200, body: Data("{}".utf8))
        )
        let observed12 = await source.availability()
        XCTAssertEqual(observed12, .notConfigured)
    }
}

// MARK: - Aggregator concurrency (#18)

private final class DelayedStubSource: UsageSource, @unchecked Sendable {
    let name: String
    private let delay: TimeInterval
    private let usage: ProviderUsage

    init(name: String, delay: TimeInterval) {
        self.name = name
        self.delay = delay
        usage = ProviderUsage(
            provider: name,
            windows: [UsageWindow(label: "5h", utilization: 10, resetsAt: Date())]
        )
    }

    func isAvailable() -> Bool { true }

    func fetch() async throws -> ProviderUsage {
        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000.0))
        return usage
    }
}

final class UsageAggregatorConcurrencyTests: XCTestCase {
    /// Kiro's `/usage` spawns a subprocess allowed twenty seconds. Serialized, it owned the whole
    /// strip — Claude's and Codex's numbers sat unrendered behind it.
    @MainActor
    func testOneSlowProviderCannotStallTheRest() async {
        let sources = (0..<4).map { DelayedStubSource(name: "P\($0)", delay: 0.25) }
        let provider = UsageProvider(sources: sources, minFetchInterval: 0)

        let start = Date()
        await provider.refresh()
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertEqual(provider.providers.map(\.provider), ["P0", "P1", "P2", "P3"])
        XCTAssertLessThan(elapsed, 0.7, "four 0.25s providers run serially would take a full second")
    }

    /// Completion order must not reorder the strip: rows follow the order the sources were given.
    @MainActor
    func testRowOrderFollowsTheSourceListNotTheCompletionOrder() async {
        let sources = [
            DelayedStubSource(name: "Slow", delay: 0.3),
            DelayedStubSource(name: "Fast", delay: 0)
        ]
        let provider = UsageProvider(sources: sources, minFetchInterval: 0)

        await provider.refresh()
        XCTAssertEqual(provider.providers.map(\.provider), ["Slow", "Fast"])
    }
}
