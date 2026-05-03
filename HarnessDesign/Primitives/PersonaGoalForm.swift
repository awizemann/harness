//
//  PersonaGoalForm.swift
//

import SwiftUI

/// The persona + goal pair from GoalInputView, exposed as a reusable primitive.
struct PersonaGoalForm: View {
    @Binding var persona: String
    @Binding var goal: String

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spacing.l) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text("Persona").font(.system(size: 11, weight: .medium)).foregroundStyle(Color.harnessText2)
                    Text("single line").font(HFont.mono).foregroundStyle(Color.harnessText4)
                }
                TextField("e.g. first-time user, never seen this app", text: $persona)
                    .textFieldStyle(.plain)
                    .font(HFont.body)
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: Theme.radius.input).fill(Color.harnessPanel))
                    .overlay(RoundedRectangle(cornerRadius: Theme.radius.input).stroke(Color.harnessLineStrong, lineWidth: 0.5))
                    .accessibilityLabel("Persona")
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text("Goal").font(.system(size: 11, weight: .medium)).foregroundStyle(Color.harnessText2)
                    Text("describe outcome, not path").font(HFont.mono).foregroundStyle(Color.harnessText4)
                }
                TextEditor(text: $goal)
                    .font(HFont.body)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 84)
                    .padding(.horizontal, 6).padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: Theme.radius.input).fill(Color.harnessPanel))
                    .overlay(RoundedRectangle(cornerRadius: Theme.radius.input).stroke(Color.harnessLineStrong, lineWidth: 0.5))
                    .accessibilityLabel("Goal")
                Text("Avoid naming buttons, screens, or specific UI. The agent will explore the way a person would.")
                    .font(HFont.caption)
                    .foregroundStyle(Color.harnessText3)
            }
        }
    }
}

#Preview {
    @Previewable @State var p = "First-time user"
    @Previewable @State var g = "I'm a first-time user. Try to add 'milk' to my list and mark it done."
    return PersonaGoalForm(persona: $p, goal: $g)
        .padding().frame(width: 480).background(Color.harnessBg)
}
