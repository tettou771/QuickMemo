import SwiftUI

struct ContentView: View {
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            RecordingView()
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            showSettings = true
                        } label: {
                            Image(systemName: "gearshape")
                        }
                    }
                }
                .sheet(isPresented: $showSettings) {
                    NavigationStack {
                        SettingsView()
                            .toolbar {
                                ToolbarItem(placement: .topBarTrailing) {
                                    Button("完了") { showSettings = false }
                                }
                            }
                    }
                }
                .onAppear {
                    if !WebDAVService.shared.isConfigured {
                        showSettings = true
                    }
                }
        }
    }
}

#Preview {
    ContentView()
}
