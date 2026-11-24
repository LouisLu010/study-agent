import StudyKit
import SwiftUI

/// 选默认人格：设置和引导里用。每一行是人格名和一句话。
struct PersonaPicker: View {
    let title: String
    @Binding var selection: String

    var body: some View {
        Picker(title, selection: $selection) {
            ForEach(Persona.all) { persona in
                VStack(alignment: .leading, spacing: 2) {
                    Text(persona.name)
                    if !persona.summary.isEmpty {
                        Text(persona.summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .tag(persona.id)
            }
        }
        .pickerStyle(.navigationLink)
    }
}

/// 会话标题菜单里的"人格"子菜单。选"跟随默认"时会话不记自己的人格，以后改默认人格也跟着变。
struct ConversationPersonaMenu: View {
    @Binding var personaID: String
    let defaultPersona: Persona

    var body: some View {
        Menu {
            Picker("人格", selection: $personaID) {
                Text("跟随默认（\(defaultPersona.name)）").tag("")
                ForEach(Persona.all) { persona in
                    Text(persona.name).tag(persona.id)
                }
            }
        } label: {
            Label("人格：\(Persona.find(personaID)?.name ?? defaultPersona.name)", systemImage: "person.crop.circle")
        }
    }
}
