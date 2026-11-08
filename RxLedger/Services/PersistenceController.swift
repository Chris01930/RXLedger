import Foundation
import SwiftData

/// Owns the SwiftData container.
@MainActor
enum PersistenceController {
    static let schema = Schema([Fill.self, Medication.self, Pharmacy.self, Prescriber.self, InsurancePlan.self, Patient.self])

    /// The on-device store. CloudKit is intentionally off (`cloudKitDatabase: .none`);
    /// the model is CloudKit-compatible if sync is enabled later.
    static let shared: ModelContainer = {
        let inMemory = ProcessInfo.processInfo.arguments.contains("-inMemoryStore")
        let config = ModelConfiguration("RxLedger", schema: schema, isStoredInMemoryOnly: inMemory, cloudKitDatabase: .none)
        do {
            let container = try ModelContainer(for: schema, configurations: [config])
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-seedSampleData") {
                SampleData.seedIfEmpty(container.mainContext)
            }
            #endif
            return container
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    /// In-memory container pre-filled with sample data, for SwiftUI previews.
    static let preview: ModelContainer = {
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try! ModelContainer(for: schema, configurations: [config])
        SampleData.seedIfEmpty(container.mainContext)
        return container
    }()

    /// Removes every record of every type.
    static func deleteAllData(in context: ModelContext) throws {
        try context.delete(model: Fill.self)
        try context.delete(model: Medication.self)
        try context.delete(model: Pharmacy.self)
        try context.delete(model: Prescriber.self)
        try context.delete(model: InsurancePlan.self)
        try context.delete(model: Patient.self)
        try context.save()
    }
}
