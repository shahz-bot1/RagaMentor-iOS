import SwiftUI

struct ContentView: View {
    @State private var taps = 0

    var body: some View {
        VStack(spacing: 16) {
            Text(Greeting.message)
                .font(.largeTitle)
                .bold()
            Text("Native build pipeline test")
                .foregroundStyle(.secondary)
            Button("Tap me") { taps += 1 }
                .buttonStyle(.borderedProminent)
            if taps > 0 {
                Text("Taps: \(taps)")
            }
            Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding()
    }
}

#Preview {
    ContentView()
}
