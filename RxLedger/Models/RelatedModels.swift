import Foundation
import SwiftData

/// One per distinct drug. Keyed (in code, not with a unique constraint) by normalized NDC,
/// falling back to normalized drug name + strength/form.
@Model
final class Medication {
    var matchKey: String = ""
    var ndc: String?
    var displayName: String = ""
    var drugName: String = ""
    var strengthForm: String?
    var commonBrands: String?
    var manufacturer: String?
    var isActive: Bool = true
    var createdAt: Date = Date()

    @Relationship(deleteRule: .nullify, inverse: \Fill.medication)
    var fills: [Fill]? = []

    init(matchKey: String, drugName: String, strengthForm: String?) {
        self.matchKey = matchKey
        self.drugName = drugName
        self.strengthForm = strengthForm
        self.displayName = Fill.makeDisplayName(drugName: drugName, strengthForm: strengthForm)
        self.createdAt = Date()
    }

    /// Fills newest first.
    var sortedFills: [Fill] {
        (fills ?? []).sorted { $0.sortDate > $1.sortDate }
    }

    var lastFill: Fill? { sortedFills.first }

    var totalCopayPaid: Decimal {
        (fills ?? []).reduce(Decimal(0)) { $0 + ($1.amountDue ?? 0) }
    }

    var totalRetail: Decimal {
        (fills ?? []).reduce(Decimal(0)) { $0 + ($1.retailPrice ?? 0) }
    }

    var fillCount: Int { fills?.count ?? 0 }

    /// lastFill.dateFilled + lastFill.daysSupply
    var nextRefillEstimate: Date? { lastFill?.nextRefillEstimate }
}

@Model
final class Pharmacy {
    var matchKey: String = ""
    var storeNumber: String?
    var name: String?
    var street: String?
    var city: String?
    var state: String?
    var zip: String?
    var phone: String?

    @Relationship(deleteRule: .nullify, inverse: \Fill.pharmacy)
    var fills: [Fill]? = []

    init(matchKey: String) { self.matchKey = matchKey }

    var summary: String {
        var parts: [String] = []
        if let name { parts.append(name) }
        if let storeNumber { parts.append("Store #\(storeNumber)") }
        if let city { parts.append(city) }
        return parts.isEmpty ? "Pharmacy" : parts.joined(separator: " · ")
    }
}

@Model
final class Prescriber {
    var matchKey: String = ""
    var name: String = ""

    @Relationship(deleteRule: .nullify, inverse: \Fill.prescriber)
    var fills: [Fill]? = []

    init(matchKey: String, name: String) {
        self.matchKey = matchKey
        self.name = name
    }
}

@Model
final class InsurancePlan {
    var matchKey: String = ""
    var planName: String?
    var bin: String?
    var tp: String?
    var gr: String?

    @Relationship(deleteRule: .nullify, inverse: \Fill.insurance)
    var fills: [Fill]? = []

    init(matchKey: String) { self.matchKey = matchKey }

    var summary: String {
        var parts: [String] = []
        if let planName { parts.append(planName) }
        if let bin { parts.append("BIN \(bin)") }
        if let gr { parts.append("GR \(gr)") }
        return parts.isEmpty ? "Insurance plan" : parts.joined(separator: " · ")
    }
}

@Model
final class Patient {
    var matchKey: String = ""
    var name: String = ""
    var street: String?
    var city: String?
    var state: String?
    var zip: String?
    var dobMonthYear: String?
    var phone: String?

    @Relationship(deleteRule: .nullify, inverse: \Fill.patient)
    var fills: [Fill]? = []

    init(matchKey: String, name: String) {
        self.matchKey = matchKey
        self.name = name
    }
}
