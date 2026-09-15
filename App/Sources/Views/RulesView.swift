import SwiftUI
import PlsInputCore

/// 规则速查，对局中和首页都能打开。
struct RulesView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    section(String(localized: "Goal"), String(localized: "Build the biggest number you can with today's keyboard. Your peak value is your score."))
                    section(String(localized: "Slots and keys"), String(localized: "Press a key to fill the next empty slot. Tap a filled slot, then press a key to overwrite it. Long-press to clear. Adjacent digits join into one number."))
                    section(String(localized: "Rot"), String(localized: "Every digit you place ticks down over time until it reaches 0. Overwrite it to refresh. Operators never rot."))
                    section(String(localized: "Durability"), String(localized: "Each key has a limited number of presses. At 0 it breaks. Repair kits restore it, up to its original durability. Filling a Rotten slot is free."))
                    section(String(localized: "Rewards"), String(localized: "Cross a threshold for the first time to earn a reward: new keys, new slots, slot conversions, repair kits, or a freeze that pauses rot. The bag holds three items."))
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Slot types")
                            .font(.headline)
                            .foregroundStyle(Palette.text)
                        ForEach(SlotKind.allCases, id: \.self) { kind in
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: SlotKindInfo.symbol(kind))
                                    .foregroundStyle(Palette.color(for: kind))
                                    .frame(width: 22)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(SlotKindInfo.name(kind))
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(Palette.text)
                                    Text(SlotKindInfo.detail(kind))
                                        .font(.footnote)
                                        .foregroundStyle(Palette.dim)
                                }
                            }
                        }
                    }
                    section(String(localized: "Operators"), String(localized: "+ adds, × multiplies, ^ raises to a power (right to left: 2^3^2 = 2^9), ! is factorial and binds tightest, ( ) group."))
                    section(String(localized: "Ending"), String(localized: "The run ends when every key is broken with no repair kit left, when you tap End, or after five minutes."))
                }
                .padding(20)
            }
            .background(Palette.background.ignoresSafeArea())
            .navigationTitle(String(localized: "How to play"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Done")) { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func section(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.headline)
                .foregroundStyle(Palette.text)
            Text(body)
                .font(.subheadline)
                .foregroundStyle(Palette.dim)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
