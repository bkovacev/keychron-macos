import Foundation

/// Persists readings and derives a drain estimate.
///
/// The keyboard only volunteers a level while it is being used, so history is
/// sparse and irregular. Estimation therefore works on the discharge slope
/// between samples rather than assuming a fixed polling interval.
final class BatteryStore {
    private(set) var readings: [Reading] = []

    private let url: URL
    private let maxReadings = 4000

    /// Ignore steps smaller than this when deciding to append, so a long idle
    /// stretch does not fill the file with identical rows.
    private let minInterval: TimeInterval = 5 * 60

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = support.appendingPathComponent("K10ProBattery", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        url = directory.appendingPathComponent("history.json")
        load()
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: url) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        readings = (try? decoder.decode([Reading].self, from: data)) ?? []
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted
        guard let data = try? encoder.encode(readings) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// Append a reading, collapsing runs that carry no new information.
    func append(_ reading: Reading) {
        if let last = readings.last,
           last.percent == reading.percent,
           last.charging == reading.charging,
           reading.date.timeIntervalSince(last.date) < minInterval {
            readings[readings.count - 1] = reading   // keep the newest timestamp
        } else {
            readings.append(reading)
        }

        if readings.count > maxReadings {
            readings.removeFirst(readings.count - maxReadings)
        }
        save()
    }

    // MARK: - Estimation

    /// Percent per hour lost while discharging, from the most recent unbroken
    /// discharge run. Nil when there is not enough evidence.
    var drainPercentPerHour: Double? {
        // Walk back over the tail while the keyboard was discharging and the
        // level was non-increasing; a rise means a charge happened.
        var run: [Reading] = []
        for reading in readings.reversed() {
            if reading.charging { break }
            if let previous = run.last, reading.percent < previous.percent { break }
            run.append(reading)
        }
        let samples = Array(run.reversed())

        guard let first = samples.first, let last = samples.last else { return nil }
        let hours = last.date.timeIntervalSince(first.date) / 3600
        let drop = Double(first.percent - last.percent)

        guard hours >= 1, drop > 0 else { return nil }
        return drop / hours
    }

    /// Wall-clock estimate until the battery reaches zero.
    func timeRemaining(from percent: Int) -> TimeInterval? {
        guard let rate = drainPercentPerHour, rate > 0 else { return nil }
        return Double(percent) / rate * 3600
    }

    /// Same estimate in whole minutes, the unit the power-source registry wants.
    func minutesRemaining(from percent: Int) -> Int? {
        timeRemaining(from: percent).map { Int($0 / 60) }
    }
}
