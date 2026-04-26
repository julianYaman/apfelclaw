import EventKit
import Foundation

public final class CalendarTools: Sendable {
    struct ResolvedTimeframe: Sendable {
        let label: String
        let start: Date
        let end: Date
    }

    struct ResolvedEventTiming: Sendable {
        let start: Date
        let end: Date
    }

    private struct ResolvedDateTime: Sendable {
        let date: Date
        let includesExplicitTime: Bool
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

    public func createEvent(
        title: String,
        startsAt: String,
        endsAt: String?,
        durationMinutes: Int?,
        location: String?,
        notes: String?,
        referenceDate: Date,
        timeZone: TimeZone
    ) async throws -> String {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedTitle.isEmpty == false else {
            throw AppError.message("Tool argument 'title' is required.")
        }

        let timing = try resolveEventTiming(
            startsAt: startsAt,
            endsAt: endsAt,
            durationMinutes: durationMinutes,
            referenceDate: referenceDate,
            timeZone: timeZone
        )

        let eventStore = EKEventStore()
        try await requestAccess(store: eventStore)
        let calendar = try defaultWritableCalendar(store: eventStore)

        let event = EKEvent(eventStore: eventStore)
        event.calendar = calendar
        event.title = trimmedTitle
        event.startDate = timing.start
        event.endDate = timing.end

        if let location = trimmedOptional(location) {
            event.location = location
        }
        if let notes = trimmedOptional(notes) {
            event.notes = notes
        }

        try eventStore.save(event, span: .thisEvent)

        let formatter = ISO8601DateFormatter()
        formatter.timeZone = timeZone

        var result: [String: JSONValue] = [
            "title": .string(trimmedTitle),
            "calendar": .string(calendar.title),
            "start": .string(formatter.string(from: timing.start)),
            "end": .string(formatter.string(from: timing.end)),
        ]
        if let eventIdentifier = event.eventIdentifier {
            result["event_identifier"] = .string(eventIdentifier)
        }
        if let location = event.location, location.isEmpty == false {
            result["location"] = .string(location)
        }

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

    func resolveEventTiming(
        startsAt: String,
        endsAt: String?,
        durationMinutes: Int?,
        referenceDate: Date,
        timeZone: TimeZone
    ) throws -> ResolvedEventTiming {
        let start = try resolveDateTime(startsAt, referenceDate: referenceDate, timeZone: timeZone)
        guard start.includesExplicitTime else {
            throw AppError.message("Tool argument 'starts_at' must include a specific time.")
        }

        let trimmedEnd = trimmedOptional(endsAt)
        let resolvedDuration = durationMinutes

        if trimmedEnd == nil, resolvedDuration == nil {
            throw AppError.message(
                "Tool arguments for 'add_calendar_event' must include either 'ends_at' or 'duration_minutes'."
            )
        }

        if let resolvedDuration, resolvedDuration <= 0 {
            throw AppError.message("Tool argument 'duration_minutes' must be a positive integer.")
        }

        let endFromDuration = resolvedDuration.map { start.date.addingTimeInterval(Double($0) * 60) }
        let endFromInput = try trimmedEnd.map {
            try resolveDateTime($0, referenceDate: referenceDate, timeZone: timeZone, fallbackDay: start.date)
        }

        if let endFromInput, endFromInput.includesExplicitTime == false {
            throw AppError.message("Tool argument 'ends_at' must include a specific time.")
        }

        if let endFromInput, let endFromDuration {
            guard abs(endFromInput.date.timeIntervalSince(endFromDuration)) < 60 else {
                throw AppError.message(
                    "Tool arguments 'ends_at' and 'duration_minutes' do not agree on the event end time. Use one or make them consistent."
                )
            }
        }

        let endDate = endFromInput?.date ?? endFromDuration
        guard let endDate else {
            throw AppError.message("Unable to resolve the event end time.")
        }
        guard endDate > start.date else {
            throw AppError.message("The event end time must be later than the start time.")
        }

        return ResolvedEventTiming(start: start.date, end: endDate)
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

    private func defaultWritableCalendar(store: EKEventStore) throws -> EKCalendar {
        let writableCalendars = store.calendars(for: .event).filter(\.allowsContentModifications)

        if let defaultCalendar = store.defaultCalendarForNewEvents, defaultCalendar.allowsContentModifications {
            return defaultCalendar
        }
        if let firstWritable = writableCalendars.first {
            return firstWritable
        }

        throw AppError.message("No writable calendar is available for creating new events.")
    }

    private func resolveDateTime(
        _ value: String,
        referenceDate: Date,
        timeZone: TimeZone,
        fallbackDay: Date? = nil
    ) throws -> ResolvedDateTime {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            throw AppError.message("Calendar date and time values cannot be empty.")
        }

        if let isoDate = ISO8601DateFormatter().date(from: trimmed) {
            return ResolvedDateTime(date: isoDate, includesExplicitTime: true)
        }

        let detector = try NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue)
        let range = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
        guard let match = detector.firstMatch(in: trimmed, options: [], range: range),
              let detectedDate = match.date else {
            throw AppError.message(
                "Tool arguments 'starts_at' and 'ends_at' must be recognizable dates or times, for example 'today at 14:00' or '2026-04-12T14:00:00+02:00'."
            )
        }

        let includesExplicitTime = containsExplicitTime(in: trimmed)
        if let fallbackDay, looksLikeTimeOnly(trimmed) {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = timeZone

            let timeComponents = calendar.dateComponents([.hour, .minute, .second], from: detectedDate)
            var dayComponents = calendar.dateComponents([.year, .month, .day], from: fallbackDay)
            dayComponents.hour = timeComponents.hour
            dayComponents.minute = timeComponents.minute
            dayComponents.second = timeComponents.second

            if let anchored = calendar.date(from: dayComponents) {
                return ResolvedDateTime(date: anchored, includesExplicitTime: includesExplicitTime)
            }
        }

        return ResolvedDateTime(date: detectedDate, includesExplicitTime: includesExplicitTime)
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

    private func trimmedOptional(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), trimmed.isEmpty == false else {
            return nil
        }
        return trimmed
    }

    private func containsExplicitTime(in value: String) -> Bool {
        value.range(
            of: #"(?ix)\b\d{1,2}:\d{2}\b|\b\d{1,2}\s?(am|pm)\b|\bnoon\b|\bmidnight\b"#,
            options: .regularExpression
        ) != nil
    }

    private func looksLikeTimeOnly(_ value: String) -> Bool {
        value.range(
            of: #"(?ix)^\s*(\d{1,2}:\d{2}|\d{1,2}\s?(am|pm)|noon|midnight)\s*$"#,
            options: .regularExpression
        ) != nil
    }
}
