import SwiftUI
import WatchConnectivity

struct SettingsView: View {
    @State private var serverURL: String
    @State private var username: String
    @State private var password: String
    @State private var savePath: String
    @State private var testResult: String?
    @State private var testing = false

    init() {
        let cfg = WebDAVService.shared.config
        _serverURL = State(initialValue: cfg.serverURL)
        _username = State(initialValue: cfg.username)
        _password = State(initialValue: cfg.password)
        _savePath = State(initialValue: cfg.savePath.isEmpty ? "/QuickMemo" : cfg.savePath)
    }

    var body: some View {
        Form {
            Section("Nextcloud サーバー") {
                TextField("https://cloud.example.com", text: $serverURL)
                    .textContentType(.URL)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)

                TextField("ユーザー名", text: $username)
                    .textContentType(.username)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)

                SecureField("アプリパスワード", text: $password)
                    .textContentType(.password)
            }

            Section("保存先パス") {
                TextField("/QuickMemo", text: $savePath)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            }

            Section {
                Button("保存") {
                    save()
                }
                .disabled(serverURL.isEmpty || username.isEmpty || password.isEmpty)

                Button("接続テスト") {
                    Task { await testConnection() }
                }
                .disabled(testing || serverURL.isEmpty || username.isEmpty || password.isEmpty)
            }

            if let testResult {
                Section {
                    Text(testResult)
                        .foregroundStyle(testResult.contains("OK") ? .green : .red)
                }
            }
        }
        .navigationTitle("設定")
    }

    private func save() {
        WebDAVService.shared.config = WebDAVConfig(
            serverURL: serverURL,
            username: username,
            password: password,
            savePath: savePath
        )

        // Transfer config to Watch
        if WCSession.default.isPaired {
            let config: [String: Any] = [
                "type": "webdav_config",
                "server": serverURL,
                "user": username,
                "pass": password,
                "path": savePath,
            ]
            WCSession.default.transferUserInfo(config)
        }

        testResult = "保存しました（Watchにも転送中）"
    }

    private func testConnection() async {
        save()
        testing = true
        defer { testing = false }

        let cfg = WebDAVService.shared.config
        let base = cfg.serverURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(base)/remote.php/dav/files/\(cfg.username)/") else {
            testResult = "URLが不正です"
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "PROPFIND"
        request.setValue("0", forHTTPHeaderField: "Depth")
        let credentials = "\(cfg.username):\(cfg.password)"
        let encoded = Data(credentials.utf8).base64EncodedString()
        request.setValue("Basic \(encoded)", forHTTPHeaderField: "Authorization")

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if (200...299).contains(status) || status == 207 {
                testResult = "OK — 接続成功"
            } else if status == 401 {
                testResult = "認証エラー (401) — ユーザー名/パスワードを確認"
            } else {
                testResult = "エラー (HTTP \(status))"
            }
        } catch {
            testResult = "接続失敗: \(error.localizedDescription)"
        }
    }
}
