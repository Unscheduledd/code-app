#!/usr/bin/env python3
"""GTU Code App build-time source patches, pinned to upstream 9b8475e.
Changes are applied to the downloaded upstream tree; no production server edits.
"""
import json
import sys
from pathlib import Path

root = Path(sys.argv[1] if len(sys.argv) > 1 else "source").resolve()

def edit(name, old, new):
    path = root / name
    data = path.read_text()
    hits = data.count(old)
    if hits != 1:
        raise RuntimeError(f"{name}: expected exactly one patch anchor; found {hits}: {old[:75]!r}")
    path.write_text(data.replace(old, new, 1))
    print("Patched:", name)

ui = "CodeApp/Views/RemoteCreateSection.swift"
edit(ui, "import SwiftUI\n", "import SwiftUI\nimport UniformTypeIdentifiers\nimport Network\n")
edit(ui, "    @State var showFileImporter: Bool = false\n", "    @State var showFileImporter: Bool = false\n    @State private var keyImportNotice: String? = nil\n    @State private var sshPortCheck: String? = nil\n")
edit(ui,
    "    func connect() {\n",
    """    // Never display or log private-key material. Validate only the envelope.
    private func usePrivateKeyText(_ value: String) {
        let normalized = value.replacingOccurrences(of: "\\r\\n", with: "\\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let firstLine = normalized.components(separatedBy: "\\n").first ?? ""
        guard firstLine.hasPrefix("-----BEGIN "),
              firstLine.hasSuffix("PRIVATE KEY-----"),
              normalized.contains("-----END "),
              !normalized.contains("-----BEGIN PUBLIC KEY-----")
        else {
            keyImportNotice = "This is not a PEM/OpenSSH private key. Select the file without .pub."
            return
        }
        privateKeyContent = normalized + "\\n"
        keyImportNotice = "Private key ready. Enter its passphrase below, if set."
    }

    func connect() {
""")

# TCP-only probe: separates a Tailscale/router failure from an SSH handshake
# failure without ever transmitting or examining the private key.
edit(ui,
    "    func connect() {\n",
    """    private func testSSHPort() {
        let host = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty, let p = UInt16(port), p > 0,
              let endpointPort = NWEndpoint.Port(rawValue: p) else {
            sshPortCheck = "Enter a valid SSH address and port first."
            return
        }
        sshPortCheck = "Checking TCP connectivity..."
        let connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: endpointPort,
            using: .tcp
        )
        let queue = DispatchQueue(label: "codeapp.remote.ssh-port-check")
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                DispatchQueue.main.async {
                    sshPortCheck = "TCP port reachable. If SSH login still fails, check SSH handshake algorithms or key format."
                }
                connection.cancel()
            case .failed(let error):
                DispatchQueue.main.async {
                    sshPortCheck = "TCP connection failed: \\(error.localizedDescription). Check Tailscale and firewall access."
                }
                connection.cancel()
            default:
                break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 8) {
            connection.cancel()
            DispatchQueue.main.async {
                if sshPortCheck == "Checking TCP connectivity..." {
                    sshPortCheck = "TCP check timed out. Confirm Tailscale is connected, then retry."
                }
            }
        }
    }

    func connect() {
""")

edit(ui,
    """                Toggle("Use Key Authentication", isOn: $usesPrivateKey)
""",
    """                Button(action: { testSSHPort() }) {
                    Label("Test SSH port", systemImage: "network")
                }
                if let result = sshPortCheck {
                    Text(result)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Toggle("Use Key Authentication", isOn: $usesPrivateKey)
""")

edit(ui,
    "        guard !password.isEmpty || usesPrivateKey else {\n",
    """        if usesPrivateKey {
            usePrivateKeyText(privateKeyContent)
            guard !privateKeyContent.isEmpty,
                keyImportNotice?.hasPrefix("Private key ready") == true
            else {
                App.notificationManager.showErrorMessage(
                    "Import a private key (not a .pub file) before connecting.")
                return
            }
        }

        guard !password.isEmpty || usesPrivateKey else {
""")
# Replace the whole original importer with a broad file type and explicit validation.
old = """                        Button(action: {
                            showFileImporter.toggle()
                        }) {
                            Text("remote.import_from_file")
                                .font(.footnote)
                                .foregroundColor(.blue)
                        }
                        .fileImporter(
                            isPresented: $showFileImporter, allowedContentTypes: [.data]
                        ) { result in
                            guard let url = try? result.get(),
                                url.startAccessingSecurityScopedResource(),
                                let keyFileContent = try? String(contentsOfFile: url.path)
                            else {
                                App.notificationManager.showErrorMessage(
                                    "errors.failed_to_import_key")
                                return
                            }
                            url.stopAccessingSecurityScopedResource()
                            privateKeyContent = keyFileContent
                        }
                        .frame(maxWidth: .infinity)
"""
new = """                        HStack(spacing: 16) {
                            Button(action: { showFileImporter.toggle() }) {
                                Label("Import private key", systemImage: "folder")
                                    .font(.footnote)
                            }
                            Button(action: {
                                if let pasted = UIPasteboard.general.string {
                                    usePrivateKeyText(pasted)
                                } else {
                                    keyImportNotice = "Nothing to paste. Copy the private key text first."
                                }
                            }) {
                                Label("Paste key", systemImage: "doc.on.clipboard")
                                    .font(.footnote)
                            }
                        }
                        .fileImporter(
                            isPresented: $showFileImporter,
                            allowedContentTypes: [UTType.item]
                        ) { result in
                            do {
                                let url = try result.get()
                                let accessed = url.startAccessingSecurityScopedResource()
                                defer {
                                    if accessed { url.stopAccessingSecurityScopedResource() }
                                }
                                let content = try String(contentsOf: url, encoding: .utf8)
                                usePrivateKeyText(content)
                            } catch {
                                keyImportNotice = "Cannot read this key file. Move it to On My iPhone or paste its contents."
                            }
                        }
                        .frame(maxWidth: .infinity)
                        if let message = keyImportNotice {
                            Text(message)
                                .font(.footnote)
                                .foregroundColor(
                                    message.hasPrefix("Private key ready") ? .green : .orange
                                )
                                .fixedSize(horizontal: false, vertical: true)
                        }
"""
edit(ui, old, new)
edit(ui,
    """                Toggle("Use Key Authentication", isOn: $usesPrivateKey)
""",
    """                Toggle("Use Key Authentication", isOn: $usesPrivateKey)
                Text("SSH includes encrypted SFTP browsing and editing. Import a private key, not its .pub companion.")
                    .font(.caption)
                    .foregroundColor(.secondary)
""")
edit(ui, '                        Text("SSH")', '                        Text("SSH / SFTP")')
edit(ui,
    '        privateKeyContent = ""\n        usesPrivateKey = false',
    '        privateKeyContent = ""\n        keyImportNotice = nil\n        usesPrivateKey = false')

# Distinguish SSH handshake/network failures from actual rejected SSH credentials.
fs = "CodeApp/Managers/FileSystem/SFTP/SFTPFileSystemProvider.swift"
edit(fs,
    '    case AuthFailure = "errors.sftp.auth_failure"\n',
    '    case AuthFailure = "errors.sftp.auth_failure"\n'
    '    case ConnectionFailure = "errors.sftp.connection_failure"\n')
edit(fs,
    '        NSLocalizedString(self.rawValue, comment: "")\n',
    '''        switch self {
        case .AuthFailure:
            return "SSH authentication failed. Verify the private key (not .pub), its passphrase, and the server authorization."
        case .ConnectionFailure:
            return "SSH connection could not be established. Verify network access, Tailscale, host, port, and SSH algorithms."
        default:
            return NSLocalizedString(self.rawValue, comment: "")
        }
''')
edit(fs,
    '                guard self.session.isConnected && self.session.isAuthorized else {\n                    continuation.resume(throwing: SFTPError.AuthFailure)\n                    return\n                }\n',
    '''                guard self.session.isConnected else {
                    continuation.resume(throwing: SFTPError.ConnectionFailure)
                    return
                }
                guard self.session.isAuthorized else {
                    continuation.resume(throwing: SFTPError.AuthFailure)
                    return
                }
''')
term = "CodeApp/Managers/FileSystem/SFTP/SFTPTerminalServiceProvider.swift"
edit(term,
    '                guard self.session.isConnected && self.session.isAuthorized else {\n                    continuation.resume(throwing: SFTPError.AuthFailure)\n                    return\n                }\n',
    '''                guard self.session.isConnected else {
                    continuation.resume(throwing: SFTPError.ConnectionFailure)
                    return
                }
                guard self.session.isAuthorized else {
                    continuation.resume(throwing: SFTPError.AuthFailure)
                    return
                }
''')
edit(term,
    '                    continuation.resume(throwing: SFTPError.UnableToStartShell)\n                }\n\n                continuation.resume()',
    '                    continuation.resume(throwing: SFTPError.UnableToStartShell)\n                    return\n                }\n\n                continuation.resume()')

# First-run upgrade from the old default theme; user-selected custom themes are retained.
theme_manager = "CodeApp/Managers/ThemeManager.swift"
edit(theme_manager,
    '@AppStorage("editorDarkTheme") var selectedTheme: String = "Dark+"',
    '@AppStorage("editorDarkTheme") var selectedTheme: String = "GTU Midnight Purple"')
edit(theme_manager,
    '@AppStorage("preferredColorScheme") var preferredColorScheme: Int = 0',
    '@AppStorage("preferredColorScheme") var preferredColorScheme: Int = 1')
edit(theme_manager,
    '    init() {\n        loadBuiltInThemes()\n    }\n',
    '''    init() {
        let defaults = UserDefaults.standard
        if !defaults.bool(forKey: "gtu.midnightPurple.migrated") {
            if defaults.string(forKey: "editorDarkTheme") == nil
                || defaults.string(forKey: "editorDarkTheme") == "Dark+" {
                selectedTheme = "GTU Midnight Purple"
            }
            if defaults.object(forKey: "preferredColorScheme") == nil {
                preferredColorScheme = 1
            }
            defaults.set(true, forKey: "gtu.midnightPurple.migrated")
        }
        loadBuiltInThemes()
    }
''')
theme_path = root / "Themes/gtu-midnight-purple-color-theme.json"
base = json.loads((root / "Themes/vs-dark-plus-theme.json").read_text())
base["name"] = "GTU Midnight Purple"
base["type"] = "dark"
base["colors"] = {
    "editor.background": "#120D20",
    "editor.foreground": "#EDE6FA",
    "activityBar.background": "#1D1232",
    "activityBar.foreground": "#EDE6FA",
    "activityBar.inactiveForeground": "#A292C0",
    "sideBar.background": "#201332",
    "sideBarSectionHeader.foreground": "#BA9FEC",
    "statusBar.background": "#6133A2",
    "statusBar.foreground": "#F6F0FF",
    "input.background": "#2B1B43",
    "button.background": "#7042B0",
    "dropdown.background": "#291A42",
    "panel.border": "#543771",
    "tab.activeBackground": "#201332",
    "tab.activeForeground": "#F3E9FF",
    "tab.inactiveForeground": "#B19BCF",
    "list.inactiveSelectionBackground": "#42305F",
    "list.inactiveSelectionForeground": "#EDE6FA",
    "panelTitle.activeForeground": "#F3E9FF",
    "panelTitle.inactiveForeground": "#A996C6"
}
color_swap = {
    "#1E1E1E": "#120D20",
    "#D4D4D4": "#EDE6FA",
    "#4EC9B0": "#9FE2D1",
    "#C586C0": "#D2A2FF",
    "#9CDCFE": "#B8A9FF",
    "#DCDCAA": "#D7B6FE",
    "#CE9178": "#E8AECA",
    "#569CD6": "#AE8EFA",
    "#6A9955": "#8EBB9B",
    "#B5CEA8": "#D2BBF0"
}
def recolor(v):
    if isinstance(v, dict):
        return {k: recolor(x) for k, x in v.items()}
    if isinstance(v, list):
        return [recolor(x) for x in v]
    if isinstance(v, str):
        return color_swap.get(v.upper(), v)
    return v
base["tokenColors"] = recolor(base.get("tokenColors", []))
theme_path.write_text(json.dumps(base, indent=2) + "\n")
print("Added:", theme_path.relative_to(root))

# Inform iOS why the app accesses private LAN/VPN peers; allow iOS to show
# the Local Network permission prompt if this network path requires it.
edit("CodeApp/Info.plist",
    "\t<key>NSFaceIDUsageDescription</key>",
    "\t<key>NSLocalNetworkUsageDescription</key>\n"
    "\t<string>Connect to your private SSH and SFTP servers, including Tailscale devices.</string>\n"
    "\t<key>NSFaceIDUsageDescription</key>")

# Build-time accent-color fallback: purple for screens outside theme overrides.
accent = root / "CodeApp/Assets.xcassets/AccentColor.colorset/Contents.json"
accent.write_text(json.dumps({
    "colors": [{
        "idiom": "universal",
        "color": {
            "color-space": "srgb",
            "components": {"alpha": "1.000", "red": "0.604", "green": "0.380", "blue": "0.910"}
        }
    }],
    "info": {"author": "xcode", "version": 1}
}, indent=2) + "\n")
print("Patched accent color.")

# Small, safe cosmetic name change (actual bundle identifiers untouched).
# Info.plist is a source template so only existing display strings are changed at build.
print("GTU Code App source patch complete.")
