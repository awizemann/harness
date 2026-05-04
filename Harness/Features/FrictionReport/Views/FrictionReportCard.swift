//
//  FrictionReportCard.swift
//  Harness
//
//  One row in the friction report — screenshot on the left, agent
//  metadata + detail + observation quote on the right. Extracted from the
//  parent so the SwiftUI type-checker stays inside its window.
//

import SwiftUI
import AppKit

struct FrictionReportCard: View {

    let entry: FrictionReportEntry
    let onJumpToStep: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: Theme.spacing.xl) {
            screenshot
            VStack(alignment: .leading, spacing: Theme.spacing.s) {
                metaRow
                Text(detailHeadline)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.harnessText)
                Text(entry.detail)
                    .font(HFont.body)
                    .foregroundStyle(Color.harnessText2)
                    .lineSpacing(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if !entry.agentObservation.isEmpty {
                    agentQuote
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(Theme.spacing.l)
        .background(
            RoundedRectangle(cornerRadius: Theme.radius.card)
                .fill(Color.harnessPanel)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radius.card)
                .stroke(Color.harnessLine, lineWidth: 0.5)
        )
    }

    // MARK: Sections

    private var screenshot: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.harnessBg2)
            if let image = NSImage(contentsOf: entry.screenshotURL) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "photo")
                        .font(.system(size: 22))
                        .foregroundStyle(Color.harnessText4)
                    Text("Screenshot missing")
                        .font(HFont.micro)
                        .foregroundStyle(Color.harnessText4)
                }
            }
        }
        .frame(width: 240)
        .aspectRatio(9.0 / 19.5, contentMode: .fit)
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.harnessLineStrong, lineWidth: 0.5)
        )
    }

    private var metaRow: some View {
        HStack(spacing: Theme.spacing.s) {
            Text(entry.timestampLabel)
                .font(HFont.mono)
                .foregroundStyle(Color.harnessText4)
            Text("· step \(entry.step)")
                .font(HFont.mono)
                .foregroundStyle(Color.harnessText4)
            FrictionTag(kind: PreviewFrictionKind(entry.kind))
            Spacer()
            Button(action: onJumpToStep) {
                Label("Jump to step", systemImage: "arrow.uturn.backward")
            }
            .buttonStyle(SecondaryButtonStyle())
        }
    }

    private var agentQuote: some View {
        HStack(alignment: .top, spacing: Theme.spacing.s) {
            Text("agent")
                .font(HFont.mono)
                .foregroundStyle(Color.harnessWarning)
            Text(entry.agentObservation)
                .font(HFont.mono)
                .foregroundStyle(Color.harnessText3)
                .lineSpacing(2)
        }
        .padding(Theme.spacing.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.radius.button)
                .fill(Color.harnessBg2)
        )
        .overlay(alignment: .leading) {
            Rectangle().fill(Color.harnessWarning).frame(width: 2)
        }
    }

    // MARK: Computed copy

    /// The first sentence of the agent's friction `detail` makes a clean
    /// headline; fall back to the kind label if the detail is empty.
    private var detailHeadline: String {
        let firstSentence = entry.detail
            .split(whereSeparator: { ".!?\n".contains($0) })
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespaces)
        if let firstSentence, !firstSentence.isEmpty {
            return firstSentence
        }
        return entry.kind.rawValue.replacingOccurrences(of: "_", with: " ").capitalized
    }
}
