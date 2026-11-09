import QRCodeGenerator
import SwiftUI

/// Typing a Cursor login on a watch is miserable, so the watch shows a QR code and the phone does the login.
struct LoginView: View {
    @Environment(AppSession.self) private var session
    @State private var attempt = Auth.newLoginAttempt()
    @State private var problem: String?

    var body: some View {
        // No ScrollView: the code must fit on one screen to be scannable.
        VStack(spacing: 4) {
            if let problem {
                Text(problem).font(.footnote).foregroundStyle(.red)
                Button("New code") {
                    self.problem = nil
                    attempt = Auth.newLoginAttempt()
                }
            } else {
                QRCodeView(text: attempt.url.absoluteString)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Text("Scan to sign in to Cursor").font(.footnote)
            }
        }
        .task(id: attempt.uuid) {
            do {
                try await session.auth.completeLogin(attempt)
                session.isSignedIn = true
            } catch is CancellationError {
            } catch {
                problem = error.localizedDescription
            }
        }
    }
}

private struct QRCodeView: View {
    let text: String
    private let quietZone = 2

    var body: some View {
        if let code = try? QRCode.encode(text: text, ecl: .low) {
            Canvas { context, size in
                let cell = size.width / CGFloat(code.size + quietZone * 2)
                context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.white))
                var modules = Path()
                for y in 0..<code.size {
                    for x in 0..<code.size where code.getModule(x: x, y: y) {
                        modules.addRect(CGRect(
                            x: CGFloat(x + quietZone) * cell, y: CGFloat(y + quietZone) * cell, width: cell, height: cell
                        ))
                    }
                }
                context.fill(modules, with: .color(.black))
            }
            .aspectRatio(1, contentMode: .fit)
        }
    }
}
