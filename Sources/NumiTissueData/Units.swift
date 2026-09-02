import Foundation

public enum UnitDimension: String, Codable, Sendable, CaseIterable {
    case dimensionless
    case length
    case area
    case volume
    case time
    case frequency
    case voltage
    case current
    case conductance
    case resistance
    case capacitance
    case concentration
    case temperature
    case numberDensity
    case diffusion
    case velocity
}

public enum BiologicalUnit: String, Codable, Sendable, CaseIterable {
    case dimensionless

    case meter
    case millimeter
    case micrometer
    case nanometer

    case squareMeter
    case squareMillimeter
    case squareMicrometer

    case cubicMeter
    case cubicMillimeter
    case cubicMicrometer

    case second
    case millisecond
    case microsecond
    case minute
    case hour
    case day
    case week

    case hertz
    case kilohertz

    case volt
    case millivolt
    case microvolt

    case ampere
    case milliampere
    case microampere
    case nanoampere
    case picoampere

    case siemens
    case millisiemens
    case microsiemens
    case nanosiemens
    case picosiemens

    case ohm
    case kiloohm
    case megaohm
    case gigaohm

    case farad
    case microfarad
    case nanofarad
    case picofarad

    case molar
    case millimolar
    case micromolar
    case nanomolar

    case kelvin
    case celsius

    case perCubicMeter
    case perCubicMillimeter
    case perCubicMicrometer

    case squareMeterPerSecond
    case squareMicrometerPerMillisecond

    case meterPerSecond
    case millimeterPerSecond
    case micrometerPerSecond
    case micrometerPerMillisecond

    public var dimension: UnitDimension {
        switch self {
        case .dimensionless:
            return .dimensionless
        case .meter, .millimeter, .micrometer, .nanometer:
            return .length
        case .squareMeter, .squareMillimeter, .squareMicrometer:
            return .area
        case .cubicMeter, .cubicMillimeter, .cubicMicrometer:
            return .volume
        case .second, .millisecond, .microsecond, .minute, .hour, .day, .week:
            return .time
        case .hertz, .kilohertz:
            return .frequency
        case .volt, .millivolt, .microvolt:
            return .voltage
        case .ampere, .milliampere, .microampere, .nanoampere, .picoampere:
            return .current
        case .siemens, .millisiemens, .microsiemens, .nanosiemens, .picosiemens:
            return .conductance
        case .ohm, .kiloohm, .megaohm, .gigaohm:
            return .resistance
        case .farad, .microfarad, .nanofarad, .picofarad:
            return .capacitance
        case .molar, .millimolar, .micromolar, .nanomolar:
            return .concentration
        case .kelvin, .celsius:
            return .temperature
        case .perCubicMeter, .perCubicMillimeter, .perCubicMicrometer:
            return .numberDensity
        case .squareMeterPerSecond, .squareMicrometerPerMillisecond:
            return .diffusion
        case .meterPerSecond, .millimeterPerSecond, .micrometerPerSecond,
             .micrometerPerMillisecond:
            return .velocity
        }
    }

    /// Multiplicative term for conversion into the SI representative of `dimension`.
    public var scaleToSI: Double {
        switch self {
        case .dimensionless:
            return 1

        case .meter:
            return 1
        case .millimeter:
            return 1e-3
        case .micrometer:
            return 1e-6
        case .nanometer:
            return 1e-9

        case .squareMeter:
            return 1
        case .squareMillimeter:
            return 1e-6
        case .squareMicrometer:
            return 1e-12

        case .cubicMeter:
            return 1
        case .cubicMillimeter:
            return 1e-9
        case .cubicMicrometer:
            return 1e-18

        case .second:
            return 1
        case .millisecond:
            return 1e-3
        case .microsecond:
            return 1e-6
        case .minute:
            return 60
        case .hour:
            return 3_600
        case .day:
            return 86_400
        case .week:
            return 604_800

        case .hertz:
            return 1
        case .kilohertz:
            return 1e3

        case .volt:
            return 1
        case .millivolt:
            return 1e-3
        case .microvolt:
            return 1e-6

        case .ampere:
            return 1
        case .milliampere:
            return 1e-3
        case .microampere:
            return 1e-6
        case .nanoampere:
            return 1e-9
        case .picoampere:
            return 1e-12

        case .siemens:
            return 1
        case .millisiemens:
            return 1e-3
        case .microsiemens:
            return 1e-6
        case .nanosiemens:
            return 1e-9
        case .picosiemens:
            return 1e-12

        case .ohm:
            return 1
        case .kiloohm:
            return 1e3
        case .megaohm:
            return 1e6
        case .gigaohm:
            return 1e9

        case .farad:
            return 1
        case .microfarad:
            return 1e-6
        case .nanofarad:
            return 1e-9
        case .picofarad:
            return 1e-12

        case .molar:
            return 1
        case .millimolar:
            return 1e-3
        case .micromolar:
            return 1e-6
        case .nanomolar:
            return 1e-9

        case .kelvin, .celsius:
            return 1

        case .perCubicMeter:
            return 1
        case .perCubicMillimeter:
            return 1e9
        case .perCubicMicrometer:
            return 1e18

        case .squareMeterPerSecond:
            return 1
        case .squareMicrometerPerMillisecond:
            return 1e-9

        case .meterPerSecond:
            return 1
        case .millimeterPerSecond:
            return 1e-3
        case .micrometerPerSecond:
            return 1e-6
        case .micrometerPerMillisecond:
            return 1e-3
        }
    }

    /// Additive term applied after `scaleToSI`.
    public var offsetToSI: Double {
        switch self {
        case .celsius:
            return 273.15
        default:
            return 0
        }
    }

    public var symbol: String {
        switch self {
        case .dimensionless: return "1"
        case .meter: return "m"
        case .millimeter: return "mm"
        case .micrometer: return "µm"
        case .nanometer: return "nm"
        case .squareMeter: return "m²"
        case .squareMillimeter: return "mm²"
        case .squareMicrometer: return "µm²"
        case .cubicMeter: return "m³"
        case .cubicMillimeter: return "mm³"
        case .cubicMicrometer: return "µm³"
        case .second: return "s"
        case .millisecond: return "ms"
        case .microsecond: return "µs"
        case .minute: return "min"
        case .hour: return "h"
        case .day: return "d"
        case .week: return "wk"
        case .hertz: return "Hz"
        case .kilohertz: return "kHz"
        case .volt: return "V"
        case .millivolt: return "mV"
        case .microvolt: return "µV"
        case .ampere: return "A"
        case .milliampere: return "mA"
        case .microampere: return "µA"
        case .nanoampere: return "nA"
        case .picoampere: return "pA"
        case .siemens: return "S"
        case .millisiemens: return "mS"
        case .microsiemens: return "µS"
        case .nanosiemens: return "nS"
        case .picosiemens: return "pS"
        case .ohm: return "Ω"
        case .kiloohm: return "kΩ"
        case .megaohm: return "MΩ"
        case .gigaohm: return "GΩ"
        case .farad: return "F"
        case .microfarad: return "µF"
        case .nanofarad: return "nF"
        case .picofarad: return "pF"
        case .molar: return "mol/L"
        case .millimolar: return "mM"
        case .micromolar: return "µM"
        case .nanomolar: return "nM"
        case .kelvin: return "K"
        case .celsius: return "°C"
        case .perCubicMeter: return "m⁻³"
        case .perCubicMillimeter: return "mm⁻³"
        case .perCubicMicrometer: return "µm⁻³"
        case .squareMeterPerSecond: return "m²/s"
        case .squareMicrometerPerMillisecond: return "µm²/ms"
        case .meterPerSecond: return "m/s"
        case .millimeterPerSecond: return "mm/s"
        case .micrometerPerSecond: return "µm/s"
        case .micrometerPerMillisecond: return "µm/ms"
        }
    }

public static func parse(_ source: String) -> BiologicalUnit? {
    let trimmed = source
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .replacingOccurrences(of: "μ", with: "µ")

    let caseSensitiveSymbols: [String: BiologicalUnit] = [
        "S": .siemens,
        "mS": .millisiemens,
        "µS": .microsiemens,
        "uS": .microsiemens,
        "nS": .nanosiemens,
        "pS": .picosiemens,
        "M": .molar,
        "mM": .millimolar,
        "µM": .micromolar,
        "uM": .micromolar,
        "nM": .nanomolar
    ]
    if let symbol = caseSensitiveSymbols[trimmed] { return symbol }

    let normalized = trimmed.lowercased()
    let aliases: [String: BiologicalUnit] = [
        "1": .dimensionless,
        "dimensionless": .dimensionless,
        "m": .meter,
        "meter": .meter,
        "metre": .meter,
        "mm": .millimeter,
        "millimeter": .millimeter,
        "millimetre": .millimeter,
        "um": .micrometer,
        "µm": .micrometer,
        "micrometer": .micrometer,
        "micrometre": .micrometer,
        "nm": .nanometer,
        "nanometer": .nanometer,
        "nanometre": .nanometer,
        "s": .second,
        "sec": .second,
        "second": .second,
        "ms": .millisecond,
        "millisecond": .millisecond,
        "us": .microsecond,
        "µs": .microsecond,
        "microsecond": .microsecond,
        "hz": .hertz,
        "khz": .kilohertz,
        "v": .volt,
        "mv": .millivolt,
        "uv": .microvolt,
        "µv": .microvolt,
        "a": .ampere,
        "ma": .milliampere,
        "ua": .microampere,
        "µa": .microampere,
        "na": .nanoampere,
        "pa": .picoampere,
        "siemens": .siemens,
        "msiemens": .millisiemens,
        "usiemens": .microsiemens,
        "nsiemens": .nanosiemens,
        "psiemens": .picosiemens,
        "ohm": .ohm,
        "ω": .ohm,
        "kohm": .kiloohm,
        "mohm": .megaohm,
        "gohm": .gigaohm,
        "f": .farad,
        "uf": .microfarad,
        "µf": .microfarad,
        "nf": .nanofarad,
        "pf": .picofarad,
        "molar": .molar,
        "mol/l": .molar,
        "millimolar": .millimolar,
        "mmol/l": .millimolar,
        "micromolar": .micromolar,
        "umol/l": .micromolar,
        "µmol/l": .micromolar,
        "nanomolar": .nanomolar,
        "nmol/l": .nanomolar,
        "k": .kelvin,
        "kelvin": .kelvin,
        "c": .celsius,
        "°c": .celsius,
        "celsius": .celsius,
        "cells/mm3": .perCubicMillimeter,
        "cells/mm³": .perCubicMillimeter,
        "1/mm3": .perCubicMillimeter,
        "1/mm³": .perCubicMillimeter,
        "cells/um3": .perCubicMicrometer,
        "cells/µm³": .perCubicMicrometer,
        "um2/ms": .squareMicrometerPerMillisecond,
        "µm²/ms": .squareMicrometerPerMillisecond,
        "m2/s": .squareMeterPerSecond,
        "m²/s": .squareMeterPerSecond
    ]
    if let alias = aliases[normalized] { return alias }
    return Self.allCases.first {
        $0.rawValue.lowercased() == normalized || $0.symbol == trimmed
    }
}
}

public struct UnitValue: Codable, Sendable, Hashable {
    public var value: Double
    public var unit: BiologicalUnit

    public init(_ value: Double, unit: BiologicalUnit) {
        self.value = value
        self.unit = unit
    }

    public func validated() throws -> Self {
        guard value.isFinite else { throw UnitConversionError.nonFiniteValue }
        return self
    }

    public func converted(to target: BiologicalUnit) throws -> Self {
        Self(try UnitConverter.convert(value, from: unit, to: target), unit: target)
    }
}

public struct UnitInterval: Codable, Sendable, Hashable {
    public var lower: Double
    public var upper: Double
    public var unit: BiologicalUnit

    public init(lower: Double, upper: Double, unit: BiologicalUnit) {
        self.lower = lower
        self.upper = upper
        self.unit = unit
    }

    public func validated() throws -> Self {
        guard lower.isFinite, upper.isFinite, lower <= upper else {
            throw UnitConversionError.invalidInterval
        }
        return self
    }

    public func converted(to target: BiologicalUnit) throws -> Self {
        let convertedLower = try UnitConverter.convert(lower, from: unit, to: target)
        let convertedUpper = try UnitConverter.convert(upper, from: unit, to: target)
        return Self(
            lower: min(convertedLower, convertedUpper),
            upper: max(convertedLower, convertedUpper),
            unit: target
        )
    }
}

public enum UnitConverter {
    public static func convert(
        _ value: Double,
        from source: BiologicalUnit,
        to target: BiologicalUnit
    ) throws -> Double {
        guard value.isFinite else { throw UnitConversionError.nonFiniteValue }
        guard source.dimension == target.dimension else {
            throw UnitConversionError.incompatibleDimensions(
                source: source.dimension,
                target: target.dimension
            )
        }
        let si = value * source.scaleToSI + source.offsetToSI
        let converted = (si - target.offsetToSI) / target.scaleToSI
        guard converted.isFinite else { throw UnitConversionError.nonFiniteResult }
        return converted
    }

    public static func multiplier(
        from source: BiologicalUnit,
        to target: BiologicalUnit
    ) throws -> Double {
        guard source.dimension == target.dimension else {
            throw UnitConversionError.incompatibleDimensions(
                source: source.dimension,
                target: target.dimension
            )
        }
        guard source.offsetToSI == 0, target.offsetToSI == 0 else {
            throw UnitConversionError.affineConversionHasNoMultiplier
        }
        let result = source.scaleToSI / target.scaleToSI
        guard result.isFinite else { throw UnitConversionError.nonFiniteResult }
        return result
    }
}

public enum UnitConversionError: Error, Sendable, CustomStringConvertible {
    case nonFiniteValue
    case nonFiniteResult
    case incompatibleDimensions(source: UnitDimension, target: UnitDimension)
    case affineConversionHasNoMultiplier
    case invalidInterval

    public var description: String {
        switch self {
        case .nonFiniteValue:
            return "A biological measurement is non-finite."
        case .nonFiniteResult:
            return "Unit conversion produced a non-finite result."
        case .incompatibleDimensions(let source, let target):
            return "Cannot convert \(source.rawValue) to \(target.rawValue)."
        case .affineConversionHasNoMultiplier:
            return "An affine unit conversion cannot be represented by one multiplier."
        case .invalidInterval:
            return "Measurement interval is invalid."
        }
    }
}
