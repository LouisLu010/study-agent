import Foundation
import SwiftData
import Testing
@testable import StudyKit

@MainActor @Suite struct InvestigationModelTests {
    @Test func everyInvestigationKindPersistsItsInputsAndRecoverableStatus() throws {
        let container = try ModelContainer(for: Schema(StudyAgentSchema.models), configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        for kind in InvestigationKind.allCases {
            let record = StudyInvestigation(kind: kind, title: kind.title)
            try record.setMaterials([.init(title: "原文", content: "内容", location: "第 2 页", images: [.init(data: Data([1, 2]))])])
            record.inputText = "要求"; record.detailJSON = "details"; record.resultJSON = "result"; record.statusRaw = "stopped"
            context.insert(record)
            #expect(!kind.symbol.isEmpty && kind.id == kind.rawValue)
        }
        try context.save()
        let stored = try ModelContext(container).fetch(FetchDescriptor<StudyInvestigation>())
        #expect(stored.count == InvestigationKind.allCases.count)
        for record in stored {
            #expect(record.kind != nil && record.statusRaw == "stopped")
            #expect(try record.materials().first?.images.first?.data == Data([1, 2]))
            #expect(record.resultJSON == "result" && record.inputText == "要求")
        }
    }

    @Test func missingOrCorruptMaterialDoesNotSilentlyReplaceStoredEvidence() throws {
        let record = StudyInvestigation(kind: .reading, title: "对照")
        #expect(try record.materials().isEmpty)
        record.kindRaw = "future-kind"
        #expect(record.kind == nil)
        record.materialsData = Data("damaged".utf8)
        #expect(throws: (any Error).self) { try record.materials() }
        #expect(record.materialsData == Data("damaged".utf8))
    }
}
