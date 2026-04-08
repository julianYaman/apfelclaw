import Darwin.Mach
import Foundation
import IOKit.ps

public final class MacStatusTools: Sendable {
    public enum Section: String, CaseIterable, Sendable {
        case battery
        case power
        case thermal
        case memory
        case storage
        case uptime

        static let overview: [Section] = [.battery, .power, .thermal, .memory, .storage, .uptime]
    }

    struct BatterySnapshot: Sendable {
        let percentage: Int?
        let isCharging: Bool?
        let timeRemainingMinutes: Int?
        let timeToFullChargeMinutes: Int?
        let source: String?
    }

    struct PowerSnapshot: Sendable {
        let source: String?
        let battery: BatterySnapshot?
    }

    public init() {}

    public func readStatus(sections: [Section]) throws -> String {
        let resolvedSections = sections.isEmpty ? Section.overview : sections
        let powerSnapshot = readPowerSnapshot()

        var payload: [String: JSONValue] = [
            "requested_sections": .array(resolvedSections.map { .string($0.rawValue) })
        ]

        for section in resolvedSections {
            switch section {
            case .battery:
                payload[section.rawValue] = .object(makeBatteryPayload(from: powerSnapshot))
            case .power:
                payload[section.rawValue] = .object(makePowerPayload(from: powerSnapshot))
            case .thermal:
                payload[section.rawValue] = .object(makeThermalPayload())
            case .memory:
                payload[section.rawValue] = .object(try makeMemoryPayload())
            case .storage:
                payload[section.rawValue] = .object(try makeStoragePayload())
            case .uptime:
                payload[section.rawValue] = .object(makeUptimePayload())
            }
        }

        let data = try JSONEncoder().encode(payload)
        return String(decoding: data, as: UTF8.self)
    }

    private func readPowerSnapshot() -> PowerSnapshot {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else {
            return PowerSnapshot(source: nil, battery: nil)
        }

        let list = IOPSCopyPowerSourcesList(info).takeRetainedValue() as Array
        let currentSource = IOPSGetProvidingPowerSourceType(info).map { $0.takeUnretainedValue() as String }

        let batteryDescription = list.compactMap { source -> [String: Any]? in
            guard let descriptionReference = IOPSGetPowerSourceDescription(info, source) else {
                return nil
            }
            guard let description = descriptionReference.takeUnretainedValue() as? [String: Any] else {
                return nil
            }

            guard (description[kIOPSTypeKey as String] as? String) == (kIOPSInternalBatteryType as String) else {
                return nil
            }

            guard (description[kIOPSIsPresentKey as String] as? Bool) != false else {
                return nil
            }

            return description
        }.first

        guard let batteryDescription else {
            return PowerSnapshot(source: normalizePowerSource(currentSource), battery: nil)
        }

        let currentCapacity = batteryDescription[kIOPSCurrentCapacityKey as String] as? Int
        let maxCapacity = batteryDescription[kIOPSMaxCapacityKey as String] as? Int
        let percentage: Int?
        if let currentCapacity, let maxCapacity, maxCapacity > 0 {
            percentage = Int((Double(currentCapacity) / Double(maxCapacity) * 100).rounded())
        } else {
            percentage = nil
        }

        let batterySource = normalizePowerSource(
            batteryDescription[kIOPSPowerSourceStateKey as String] as? String ?? currentSource
        )

        let battery = BatterySnapshot(
            percentage: percentage,
            isCharging: batteryDescription[kIOPSIsChargingKey as String] as? Bool,
            timeRemainingMinutes: sanitizeTimeValue(batteryDescription[kIOPSTimeToEmptyKey as String] as? Int),
            timeToFullChargeMinutes: sanitizeTimeValue(batteryDescription[kIOPSTimeToFullChargeKey as String] as? Int),
            source: batterySource
        )

        return PowerSnapshot(source: normalizePowerSource(currentSource) ?? batterySource, battery: battery)
    }

    private func makeBatteryPayload(from powerSnapshot: PowerSnapshot) -> [String: JSONValue] {
        guard let battery = powerSnapshot.battery else {
            var payload: [String: JSONValue] = [
                "has_battery": .bool(false)
            ]
            if let source = powerSnapshot.source {
                payload["power_source"] = .string(source)
            }
            return payload
        }

        var payload: [String: JSONValue] = [
            "has_battery": .bool(true)
        ]
        if let percentage = battery.percentage {
            payload["percentage"] = .number(Double(percentage))
        }
        if let isCharging = battery.isCharging {
            payload["is_charging"] = .bool(isCharging)
        }
        if let source = battery.source {
            payload["power_source"] = .string(source)
        }
        if let timeRemainingMinutes = battery.timeRemainingMinutes {
            payload["time_remaining_minutes"] = .number(Double(timeRemainingMinutes))
        }
        if let timeToFullChargeMinutes = battery.timeToFullChargeMinutes {
            payload["time_to_full_charge_minutes"] = .number(Double(timeToFullChargeMinutes))
        }
        return payload
    }

    private func makePowerPayload(from powerSnapshot: PowerSnapshot) -> [String: JSONValue] {
        var payload: [String: JSONValue] = [
            "has_battery": .bool(powerSnapshot.battery != nil)
        ]
        if let source = powerSnapshot.source {
            payload["source"] = .string(source)
            payload["is_on_ac_power"] = .bool(source == "ac")
        }
        if let isCharging = powerSnapshot.battery?.isCharging {
            payload["is_charging"] = .bool(isCharging)
        }
        return payload
    }

    private func makeThermalPayload() -> [String: JSONValue] {
        [
            "state": .string(renderThermalState(ProcessInfo.processInfo.thermalState))
        ]
    }

    private func makeMemoryPayload() throws -> [String: JSONValue] {
        let physicalMemory = ProcessInfo.processInfo.physicalMemory
        var payload: [String: JSONValue] = [
            "physical_memory_bytes": .number(Double(physicalMemory))
        ]

        if let availableBytes = try availableMemoryBytes() {
            payload["available_memory_bytes"] = .number(Double(availableBytes))
        }

        return payload
    }

    private func availableMemoryBytes() throws -> UInt64? {
        var pageSize: vm_size_t = 0
        let pageSizeResult = host_page_size(mach_host_self(), &pageSize)
        guard pageSizeResult == KERN_SUCCESS else {
            throw AppError.message("Unable to read memory page size.")
        }

        var statistics = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)

        let result = withUnsafeMutablePointer(to: &statistics) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, rebound, &count)
            }
        }

        guard result == KERN_SUCCESS else {
            throw AppError.message("Unable to read memory statistics.")
        }

        let availablePages = UInt64(statistics.free_count) + UInt64(statistics.inactive_count) + UInt64(statistics.speculative_count)
        return availablePages * UInt64(pageSize)
    }

    private func makeStoragePayload() throws -> [String: JSONValue] {
        let attributes = try FileManager.default.attributesOfFileSystem(forPath: "/")
        let totalBytes = attributes[.systemSize] as? NSNumber
        let freeBytes = attributes[.systemFreeSize] as? NSNumber

        var payload: [String: JSONValue] = [
            "path": .string("/")
        ]
        if let totalBytes {
            payload["total_bytes"] = .number(totalBytes.doubleValue)
        }
        if let freeBytes {
            payload["free_bytes"] = .number(freeBytes.doubleValue)
        }
        return payload
    }

    private func makeUptimePayload() -> [String: JSONValue] {
        let uptime = ProcessInfo.processInfo.systemUptime
        return [
            "seconds": .number(uptime),
            "human_readable": .string(renderDuration(seconds: uptime))
        ]
    }

    private func sanitizeTimeValue(_ value: Int?) -> Int? {
        guard let value, value >= 0 else {
            return nil
        }
        return value
    }

    private func normalizePowerSource(_ value: String?) -> String? {
        guard let value else {
            return nil
        }

        switch value {
        case kIOPSACPowerValue as String:
            return "ac"
        case kIOPSBatteryPowerValue as String:
            return "battery"
        default:
            return value.lowercased()
        }
    }

    private func renderThermalState(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal:
            return "nominal"
        case .fair:
            return "fair"
        case .serious:
            return "serious"
        case .critical:
            return "critical"
        @unknown default:
            return "unknown"
        }
    }

    private func renderDuration(seconds: TimeInterval) -> String {
        let totalSeconds = Int(seconds.rounded())
        let days = totalSeconds / 86_400
        let hours = (totalSeconds % 86_400) / 3_600
        let minutes = (totalSeconds % 3_600) / 60

        var components: [String] = []
        if days > 0 {
            components.append("\(days) day\(days == 1 ? "" : "s")")
        }
        if hours > 0 {
            components.append("\(hours) hour\(hours == 1 ? "" : "s")")
        }
        if minutes > 0 || components.isEmpty {
            components.append("\(minutes) minute\(minutes == 1 ? "" : "s")")
        }

        return components.prefix(2).joined(separator: ", ")
    }
}
