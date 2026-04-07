import EventKit
import Foundation

public final class CalendarTools: Sendable {
    public init() {}

    public func listEvents(timeframe: String, limit: Int) async throws -> String {
        let eventStore = EKEventStore()
        try await requestAccess(store: eventStore)

        let now = Date()
        let normalized = normalizeTimeframe(timeframe)
        let range = dateRange(for: normalized, now: now)
        let predicate = eventStore.predicateForEvents(withStart: range.start, end: range.end, calendars: nil)
        let events = eventStore.events(matching: predicate)
            .sorted { $0.startDate < $1.startDate }
            .prefix(limit)

        let formatter = ISO8601DateFormatter()
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
            "timeframe": .string(normalized),
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

    private func normalizeTimeframe(_ timeframe: String) -> String {
        let value = timeframe.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch value {
        case "today", "tomorrow", "next_7_days":
            return value
        default:
            return "today"
        }
    }

    private func dateRange(for timeframe: String, now: Date) -> (start: Date, end: Date) {
        let calendar = Calendar.current
        switch timeframe {
        case "tomorrow":
            let start = calendar.startOfDay(for: calendar.date(byAdding: .day, value: 1, to: now) ?? now)
            let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
            return (start, end)
        case "next_7_days":
            let start = now
            let end = calendar.date(byAdding: .day, value: 7, to: now) ?? now.addingTimeInterval(604_800)
            return (start, end)
        default:
            let start = calendar.startOfDay(for: now)
            let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
            return (start, end)
        }
    }
}
