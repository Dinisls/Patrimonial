import SwiftUI
import SwiftData

struct ContentView: View {
    var body: some View {
        PBRootView()
    }
}

#Preview {
    ContentView()
        .modelContainer(for: [
            Account.self,
            FinancialTransaction.self,
            CustomCategory.self
        ], inMemory: true)
}
