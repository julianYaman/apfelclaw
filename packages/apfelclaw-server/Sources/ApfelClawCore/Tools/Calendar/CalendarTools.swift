import EventKit
import Foundation

public final class CalendarTools: Sendable {
    struct ResolvedTimeframe: Sendable {
        let label: String
        let start: Date
        let end: Date
    }

    public init() {}

    public func listEvents(
        timeframe: String,
        limit: Int,
        referenceDate: Date,
        timeZone: TimeZone
    ) async throws -> String {
        let eventStore = EKEventStore()
        try await requestAccess(store: eventStore)

        let resolved = try resolveTimeframe(timeframe, referenceDate: referenceDate, timeZone: timeZone)
        let predicate = eventStore.predicateForEvents(withStart: resolved.start, end: resolved.end, calendars: nil)
        let events = eventStore.events(matching: predicate)
            .sorted { $0.startDate < $1.startDate }
            .prefix(limit)

        let formatter = ISO8601DateFormatter()
        formatter.timeZone = timeZone
        let payload: [JSONValue] = events.map { event in
            var object: [String: JSONValue] = [
                "title": .string(event.title),
                "start": .string(formatter.string(from: event.startDate)),
                "end": .string(formatter.string(from: event.endDate)),
                "calendar": .string(event.calendar.title),
            ]
            if let location = event.location, location.isEmpty == false {
                object["location"] = .string(location)
            }
            if let notes = event.notes, notes.isEmpty == false {
                object["notes"] = .string(String(notes.prefix(200)))
            }
            return .object(object)
        }

        let result: [String: JSONValue] = [
            "timeframe": .string(resolved.label),
            "range_start": .string(formatter.string(from: resolved.start)),
            "range_end": .string(formatter.string(from: resolved.end)),
            "results": .array(payload),
        ]

        let data = try JSONEncoder().encode(result)
        return String(decoding: data, as: UTF8.self)
    }

    private func requestAccess(store: EKEventStore) async throws {
        if #available(macOS 14.0, *) {
            let granted = try await store.requestFullAccessToEvents()
            guard granted else {
                throw AppError.message("Calendar access was denied.")
            }
        } else {
            let granted: Bool = try await withCheckedThrowingContinuation { continuation in
                store.requestAccess(to: .event) { granted, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: granted)
                    }
                }
            }
            guard granted else {
                throw AppError.message("Calendar access was denied.")
            }
        }
    }

    func resolveTimeframe(_ timeframe: String, referenceDate: Date, timeZone: TimeZone) throws -> ResolvedTimeframe {
        let trimmed = timeframe.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            throw AppError.message("Tool argument 'timeframe' is required.")
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone

        switch trimmed.lowercased() {
        case "today":
            let interval = dayInterval(for: referenceDate, calendar: calendar)
            return ResolvedTimeframe(label: trimmed, start: interval.start, end: interval.end)
        case "tomorrow":
            let date = calendar.date(byAdding: .day, value: 1, to: referenceDate) ?? referenceDate.addingTimeInterval(86_400)
            let interval = dayInterval(for: date, calendar: calendar)
            return ResolvedTimeframe(label: trimmed, start: interval.start, end: interval.end)
        case "next_7_days":
            let start = referenceDate
            let end = calendar.date(byAdding: .day, value: 7, to: referenceDate) ?? referenceDate.addingTimeInterval(604_800)
            return ResolvedTimeframe(label: trimmed, start: start, end: end)
        case "this week":
            if let interval = calendar.dateInterval(of: .weekOfYear, for: referenceDate) {
                return ResolvedTimeframe(label: trimmed, start: interval.start, end: interval.end)
            }
        case "next week":
            if let nextWeekDate = calendar.date(byAdding: .weekOfYear, value: 1, to: referenceDate),
               let interval = calendar.dateInterval(of: .weekOfYear, for: nextWeekDate) {
                return ResolvedTimeframe(label: trimmed, start: interval.start, end: interval.end)
            }
        default:
            break
        }

        if let interval = try detectedRange(in: trimmed, timeZone: timeZone) {
            return ResolvedTimeframe(label: trimmed, start: interval.start, end: interval.end)
        }

        throw AppError.message(
            "Tool argument 'timeframe' must describe a calendar range, for example 'today', 'tomorrow', 'next week', or a specific date."
        )
    }

    private func detectedRange(in value: String, timeZone: TimeZone) throws -> DateInterval? {
        if let date = ISO8601DateFormatter().date(from: value) {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = timeZone
            return dayInterval(for: date, calendar: calendar)
        }

        let detector = try NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue)
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        let matches = detector.matches(in: value, options: [], range: range)

        guard matches.isEmpty == false else {
            return nil
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone

        let intervals = matches.compactMap { match -> DateInterval? in
            guard let date = match.date else {
                return nil
            }

            if match.duration > 0 {
                return DateInterval(start: date, end: date.addingTimeInterval(match.duration))
            }

            return dayInterval(for: date, calendar: calendar)
        }

        guard let start = intervals.map(\.start).min(), let end = intervals.map(\.end).max() else {
            return nil
        }

        return DateInterval(start: start, end: end)
    }

    private func dayInterval(for date: Date, calendar: Calendar) -> DateInterval {
        let start = calendar.startOfDay(for: date)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        return DateInterval(start: start, end: end)
    }
}
