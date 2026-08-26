// ───────────────────────────────────────────────────────────
// PBScaffold.swift — Estruturas de ecrã (mantidas para compatibilidade)
// ───────────────────────────────────────────────────────────
import SwiftUI

struct RootScaffold<Actions: View, Content: View>: View {
    let title: String
    var kicker: String? = nil
    @ViewBuilder var actions: () -> Actions
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                content()
            }
            .padding(.bottom, 100)
        }
        .background(PB.bg)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 10) { actions() }
            }
        }
    }
}

struct DetailScaffold<Actions: View, Content: View>: View {
    let title: String
    @ViewBuilder var actions: () -> Actions
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollView {
            content().padding(.bottom, 100)
        }
        .background(PB.bg)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 8) { actions() }
            }
        }
    }
}
