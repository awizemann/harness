//
//  FrictionReportView.swift
//

import SwiftUI

@MainActor final class FrictionReportViewModel: ObservableObject {
    @Published var run: PreviewRun
    @Published var filter: String = "all"
    init(run: PreviewRun = .mock) { self.run = run }
}

struct FrictionReportView: View {
    @StateObject var vm = FrictionReportViewModel()

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                summary
                ForEach(vm.run.friction) { event in card(event) }
            }
            .padding(.horizontal, 32).padding(.vertical, 22)
            .frame(maxWidth: 1200)
            .frame(maxWidth: .infinity)
        }
        .background(Color.harnessBg)
    }

    private var summary: some View {
        HStack(spacing: 14) {
            Text("\(vm.run.friction.count)")
                .font(.system(size: 28, weight: .medium, design: .monospaced))
                .foregroundStyle(Color.harnessWarning)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(vm.run.friction.count) friction events flagged in this run.")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.harnessText)
                Text("Friction-only timeline. Share with designers, attach to bug reports.")
                    .font(HFont.caption).foregroundStyle(Color.harnessText2)
            }
            Spacer()
            HStack(spacing: 6) {
                ForEach(uniqueKinds, id: \.self) { k in
                    HStack(spacing: 5) { Circle().fill(Color.harnessWarning).frame(width: 6, height: 6); Text("1 \(k.rawValue)").font(HFont.micro) }
                        .padding(.horizontal, 7).frame(height: 18)
                        .foregroundStyle(Color.harnessWarning)
                        .background(Capsule().fill(Color.harnessWarning.opacity(0.10)))
                        .overlay(Capsule().stroke(Color.harnessWarning.opacity(0.30), lineWidth: 0.5))
                }
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.harnessWarning.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.harnessWarning.opacity(0.30), lineWidth: 0.5))
    }

    private var uniqueKinds: [PreviewFrictionKind] {
        var seen = Set<PreviewFrictionKind>(); var out: [PreviewFrictionKind] = []
        for e in vm.run.friction where !seen.contains(e.kind) { seen.insert(e.kind); out.append(e.kind) }
        return out
    }

    private func card(_ event: PreviewFrictionEvent) -> some View {
        HStack(alignment: .top, spacing: 22) {
            // shot placeholder
            RoundedRectangle(cornerRadius: 14)
                .fill(Color(red: 0.98, green: 0.97, blue: 0.95))
                .frame(width: 240).frame(maxHeight: 480)
                .aspectRatio(9.0 / 19.5, contentMode: .fit)
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.harnessLineStrong, lineWidth: 0.5))

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Text(event.timestamp).font(HFont.mono).foregroundStyle(Color.harnessText4)
                    Text("· step \(event.stepN)").font(HFont.mono).foregroundStyle(Color.harnessText4)
                    FrictionTag(kind: event.kind)
                    Spacer()
                    Button { } label: { Label("Jump to step", systemImage: "arrow.uturn.backward") }
                        .buttonStyle(SecondaryButtonStyle(compact: true))
                }
                Text(event.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(Color.harnessText)
                Text(event.detail).font(HFont.body).foregroundStyle(Color.harnessText2).lineSpacing(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(alignment: .top, spacing: 8) {
                    Text("agent").font(HFont.mono).foregroundStyle(Color.harnessWarning)
                    Text(event.agentQuote).font(HFont.mono).foregroundStyle(Color.harnessText3).lineSpacing(2)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.harnessBg2))
                .overlay(alignment: .leading) { Rectangle().fill(Color.harnessWarning).frame(width: 2) }
            }
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.harnessPanel))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.harnessLine, lineWidth: 0.5))
    }
}

#Preview("FrictionReport") {
    FrictionReportView().frame(width: 1180, height: 800).preferredColorScheme(.dark)
}
