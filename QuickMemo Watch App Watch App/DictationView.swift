import SwiftUI

struct DictationView: View {
    @Binding var text: String
    @Environment(\.dismiss) private var dismiss

    @State private var input = ""

    var body: some View {
        VStack {
            TextField("メモを入力", text: $input)
                .multilineTextAlignment(.leading)

            Button("完了") {
                text = input
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .disabled(input.isEmpty)
        }
    }
}
