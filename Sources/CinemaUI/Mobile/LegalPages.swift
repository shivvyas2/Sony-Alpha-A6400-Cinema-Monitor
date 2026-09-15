import SwiftUI

/// Privacy Policy and Terms of Use, as plain text with `# ` headings. Shown in Settings and reusable for a store listing.
public enum LegalText {
    public static let developer = "Shiv Vyas"
    public static let contact = "shivvyas0209@gmail.com"
    public static let effectiveDate = "15 September 2026"

    public struct Paragraph: Identifiable, Equatable {
        public let id: Int
        public let text: String
        public let isHeading: Bool
    }

    public static func paragraphs(_ text: String) -> [Paragraph] {
        text.components(separatedBy: "\n\n").enumerated().map { i, p in
            let t = p.trimmingCharacters(in: .whitespacesAndNewlines)
            return Paragraph(id: i, text: t.hasPrefix("# ") ? String(t.dropFirst(2)) : t, isHeading: t.hasPrefix("# "))
        }
    }

    public static let privacyPolicy = """
    # Privacy Policy

    Effective \(effectiveDate). CinemaHUD is developed by \(developer) ("we", "us").

    # What we collect

    CinemaHUD does not collect, store or transmit any personal data. There are no accounts, no analytics, no advertising identifiers, no crash reporting services and no third-party SDKs that collect data.

    # Local network

    The app talks only to your Sony camera (over the camera's own Wi-Fi network) or to a Mac running CinemaHUD on the same local network. iOS asks for Local Network permission for this reason alone. Nothing is sent to the Internet by the app.

    # Photos and recordings

    Images the camera hands over during a session are saved on this device, in the app's own folder (visible in the Files app under CinemaHUD). They stay on the device until you delete them. The app does not read your photo library and does not upload anything.

    # Settings

    Monitor preferences (guides, peaking, LUTs, last connection address) are stored on the device only.

    # Children

    CinemaHUD is a camera tool and is not directed at children. Because it collects no data, no data about anyone is processed.

    # Changes

    If this policy changes, the new version will appear here with a new effective date.

    # Contact

    Questions about privacy: \(contact).
    """

    public static let termsOfUse = """
    # Terms of Use

    Effective \(effectiveDate). By using CinemaHUD ("the app") you agree to these terms.

    # The app

    CinemaHUD is a remote monitor and controller for compatible Sony cameras, provided by \(developer). It is offered for personal and professional use with your own equipment.

    # No affiliation

    CinemaHUD is an independent product. It is not affiliated with, endorsed by or sponsored by Sony Group Corporation or its subsidiaries. Sony, Alpha and α are trademarks of Sony Group Corporation and are used only to describe compatibility.

    # Provided as is

    THE APP IS PROVIDED "AS IS" AND "AS AVAILABLE", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NON-INFRINGEMENT. Camera behaviour, connection reliability and image quality depend on your camera, lens, firmware and network.

    # Your responsibility

    You control the camera through the app at your own risk. You are responsible for your camera settings, your recordings, backing up your files, and for complying with the laws that apply to your filming and photography.

    # Limitation of liability

    To the fullest extent permitted by law, \(developer) is not liable for any lost footage, missed shots, equipment damage, or indirect or consequential loss arising from use of the app.

    # Changes to the app or these terms

    Features may change between versions as camera protocols evolve. Updated terms will appear here with a new effective date; continued use after an update means you accept the new terms.

    # Contact

    Questions about these terms: \(contact).
    """
}

#if !os(macOS)
/// Renders a legal text: headings in the monitor's tracked caps, body in readable type.
struct LegalPageView: View {
    let title: String
    let text: String
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(LegalText.paragraphs(text)) { p in
                    if p.isHeading {
                        Text(p.text.uppercased()).font(Theme.label(12)).tracking(2).foregroundStyle(Theme.accent).padding(.top, p.id == 0 ? 0 : 10)
                    } else {
                        Text(p.text).font(.system(size: 15)).foregroundStyle(Theme.text).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: 700, alignment: .leading)
        }
        .background(Theme.field)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}
#endif
