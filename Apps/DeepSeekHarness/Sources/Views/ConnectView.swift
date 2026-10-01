import SwiftUI

/// Connects to a Harness host by pasting the URL printed by `dsh web`.
struct ConnectView: View {
    @Environment(AppState.self) private var state
    @State private var urlText = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("http://127.0.0.1:3080/?token=…", text: $urlText, axis: .vertical)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.system(.footnote, design: .monospaced))
                        .lineLimit(2...4)
                } header: {
                    Text("Harness URL")
                } footer: {
                    Text("Run `dsh web` on your computer and paste the printed URL. The token in it signs you in once; the app stores the session from then on.")
                }

                Section {
                    Button {
                        Task { await state.connect(printedURL: urlText) }
                    } label: {
                        HStack {
                            Spacer()
                            if state.phase.isBusy {
                                ProgressView().controlSize(.small)
                            } else {
                                Text("Connect")
                            }
                            Spacer()
                        }
                    }
                    .disabled(urlText.trimmingCharacters(in: .whitespaces).isEmpty || state.phase.isBusy)
                }

                if case .failed(let message) = state.phase {
                    Section("Connection failed") {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }

                if !state.rememberedHostURL.isEmpty {
                    Section {
                        Button("Use last host") {
                            urlText = state.rememberedHostURL
                        }
                        .font(.footnote)
                    }
                }
            }
            .navigationTitle("DeepSeek Harness")
        }
        .onAppear {
            if urlText.isEmpty { urlText = state.rememberedHostURL }
        }
    }
}
