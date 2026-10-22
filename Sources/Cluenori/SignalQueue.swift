import CluenoriIngest
import Foundation
import os

/// The signals recorded and not yet sent, on disk, in the order they were recorded, within a budget:
/// over it, the oldest are dropped. A batch is always the oldest signals of one release and
/// environment, and leaves the queue only once the deployment has them, so a batch sent again after
/// a failure carries the same signals, with the same IDs.
///
/// On disk it is a folder of segments, each a JSON Lines file: a header line with the release and
/// environment its signals were recorded in, then one signal per line. Appending writes a line;
/// sending removes whole segments, or rewrites the one partly sent.
actor SignalQueue {
    /// The most the queue keeps on disk unless told otherwise; past it, the oldest signals go.
    static let budgetBytes = 4_000_000
    /// A segment's most signals and bytes, past which the next signal starts another.
    static let segmentSignals = 100
    static let segmentBytes = 256_000
    /// A signal bigger than this can't be sent in a body of 1 MB, so it is never kept.
    static let largestSignalBytes = 900_000

    private struct Header: Codable, Equatable {
        let release: String
        let environment: String
    }

    private struct Segment {
        let number: Int
        let header: Header
        var bytes: Int
        /// Its signals' count, when this process wrote or read all of it.
        var signals: Int?
    }

    /// The oldest signals of one release and environment, and which lines of which segments they
    /// came from, which includes any that couldn't be read and are dropped with them.
    struct Batch: Sendable {
        let release: String
        let environment: String
        let signals: [AppSignal]
        let spans: [Span]

        /// The first `lines` signals of segment `segment`.
        struct Span: Sendable {
            let segment: Int
            let lines: Int
        }

        /// How many lines of the queue the batch takes.
        var lines: Int { spans.reduce(0) { $0 + $1.lines } }
    }

    private let folder: URL
    private let budgetBytes: Int
    private var segments: [Segment] = []
    /// The next segment's number: never reused in a process, so a batch taken before the queue was
    /// emptied can't remove what came after.
    private var nextNumber = 1
    private var loaded = false
    private let logger = Logger(subsystem: "com.cluenori.sdk", category: "queue")

    init(folder: URL, budgetBytes: Int = SignalQueue.budgetBytes) {
        self.folder = folder
        self.budgetBytes = budgetBytes
    }

    /// Whether anything is waiting to be sent.
    var isEmpty: Bool {
        load()
        return segments.isEmpty
    }

    /// Adds `signal`, recorded in `release` and `environment`, after every other. Over the budget,
    /// the oldest signals are dropped first. A failure to write loses this signal alone.
    func append(_ signal: AppSignal, release: String, environment: String) {
        load()
        guard let line = try? Coding.encoder().encode(signal) else {
            logger.error("A signal couldn't be written, and is dropped.")
            return
        }
        guard line.count <= Self.largestSignalBytes else {
            logger.error("A signal of \(line.count) bytes is too big to send, and is dropped.")
            return
        }
        let header = Header(release: release, environment: environment)
        do {
            if let last = segments.last, last.header == header, let count = last.signals, count < Self.segmentSignals,
                last.bytes + line.count + 1 <= Self.segmentBytes
            {
                let handle = try FileHandle(forWritingTo: file(last.number))
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: line + Data([0x0a]))
                segments[segments.count - 1].bytes += line.count + 1
                segments[segments.count - 1].signals = count + 1
            } else {
                let number = nextNumber
                nextNumber += 1
                var contents = try Coding.encoder().encode(header)
                contents.append(0x0a)
                contents.append(line)
                contents.append(0x0a)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try contents.write(to: file(number), options: .atomic)
                segments.append(Segment(number: number, header: header, bytes: contents.count, signals: 1))
            }
        } catch {
            logger.error(
                "A signal couldn't be kept on disk, and is dropped: \(error.localizedDescription, privacy: .public)")
            return
        }
        keepWithinBudget()
    }

    /// The oldest signals, at most `limit` of them and about `maxBytes` of JSON, all of one release
    /// and environment; nil when the queue is empty. One signal comes alone when it is bigger.
    func head(limit: Int, maxBytes: Int) -> Batch? {
        load()
        var signals: [AppSignal] = []
        var spans: [Batch.Span] = []
        var lines = 0
        var bytes = 0
        var header: Header?
        let decoder = Coding.decoder()
        segmentsLoop: for segment in segments {
            if let header, header != segment.header { break }
            header = segment.header
            guard let contents = try? Data(contentsOf: file(segment.number)) else {
                // Unreadable: its lines can't be counted, so the segment is dropped whole when it is first.
                if signals.isEmpty && lines == 0 { dropFirstSegment() }
                break
            }
            var taken = 0
            defer { if taken > 0 { spans.append(Batch.Span(segment: segment.number, lines: taken)) } }
            for line in contents.split(separator: 0x0a, omittingEmptySubsequences: true).dropFirst() {
                if signals.count >= limit || (bytes + line.count > maxBytes && !signals.isEmpty) { break segmentsLoop }
                taken += 1
                lines += 1
                bytes += line.count
                switch try? decoder.decode(AppSignal.self, from: Data(line)) {
                case .some(.unknown), .none:
                    logger.error("A signal on disk couldn't be read, and is dropped.")
                case .some(let signal):
                    signals.append(signal)
                }
            }
        }
        guard let header, lines > 0 else { return nil }
        return Batch(release: header.release, environment: header.environment, signals: signals, spans: spans)
    }

    /// Removes `batch`'s signals: those the deployment now has, or one it refused. What left the
    /// queue meanwhile, over the budget or emptied, stays gone, and nothing after it is touched.
    func remove(_ batch: Batch) {
        load()
        for span in batch.spans {
            guard let index = segments.firstIndex(where: { $0.number == span.segment }) else { continue }
            let count = segments[index].signals ?? signalCount(span.segment)
            if count <= span.lines {
                try? FileManager.default.removeItem(at: file(span.segment))
                segments.remove(at: index)
            } else {
                rewrite(at: index, dropping: span.lines)
            }
        }
    }

    /// Drops every signal, as when the person withdraws consent or the key is refused.
    func removeAll() {
        load()
        try? FileManager.default.removeItem(at: folder)
        segments = []
    }

    /// How many signals wait, read from disk: for tests and diagnostics.
    func count() -> Int {
        load()
        return segments.reduce(0) { $0 + ($1.signals ?? signalCount($1.number)) }
    }

    // MARK: - Segments

    private func file(_ number: Int) -> URL {
        folder.appending(path: String(format: "%010d.jsonl", number))
    }

    /// Reads which segments there are, once: their names, headers and sizes, not their signals.
    private func load() {
        guard !loaded else { return }
        loaded = true
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false))) ?? []
        let numbers = names.compactMap { name -> Int? in
            guard name.hasSuffix(".jsonl") else { return nil }
            return Int(name.dropLast(".jsonl".count))
        }
        for number in numbers.sorted() {
            // One that can't be read now, as before the first unlock, is left for a later process.
            guard let contents = try? Data(contentsOf: file(number)) else { continue }
            guard let headerLine = contents.split(separator: 0x0a, maxSplits: 1).first,
                let header = try? Coding.decoder().decode(Header.self, from: Data(headerLine))
            else {
                try? FileManager.default.removeItem(at: file(number))
                continue
            }
            segments.append(Segment(number: number, header: header, bytes: contents.count, signals: nil))
        }
        // After every segment there, read or not, so a new one never takes a number in use.
        nextNumber = (numbers.max() ?? 0) + 1
        keepWithinBudget()
    }

    private func signalCount(_ number: Int) -> Int {
        guard let contents = try? Data(contentsOf: file(number)) else { return 0 }
        return max(0, contents.split(separator: 0x0a, omittingEmptySubsequences: true).count - 1)
    }

    private func dropFirstSegment() {
        guard let first = segments.first else { return }
        try? FileManager.default.removeItem(at: file(first.number))
        segments.removeFirst()
    }

    /// Rewrites a segment without its first `lines` signals.
    private func rewrite(at index: Int, dropping lines: Int) {
        let number = segments[index].number
        guard let contents = try? Data(contentsOf: file(number)) else {
            try? FileManager.default.removeItem(at: file(number))
            segments.remove(at: index)
            return
        }
        let all = contents.split(separator: 0x0a, omittingEmptySubsequences: true)
        let kept = [all[0]] + all.dropFirst(1 + lines)
        var rewritten = Data()
        for line in kept {
            rewritten.append(contentsOf: line)
            rewritten.append(0x0a)
        }
        do {
            try rewritten.write(to: file(number), options: .atomic)
            segments[index].bytes = rewritten.count
            segments[index].signals = kept.count - 1
        } catch {
            // Not rewritten, it would send its first signals again; dropping it loses the rest instead.
            try? FileManager.default.removeItem(at: file(number))
            segments.remove(at: index)
        }
    }

    private func keepWithinBudget() {
        var total = segments.reduce(0) { $0 + $1.bytes }
        var dropped = 0
        while total > budgetBytes, segments.count > 1 {
            total -= segments[0].bytes
            dropped += segments[0].signals ?? signalCount(segments[0].number)
            dropFirstSegment()
        }
        if dropped > 0 {
            logger.notice("Over its budget, the queue dropped its \(dropped) oldest signals.")
        }
    }
}
