import SwiftUI

/// What the window shows until someone is signed in: the app's name and one
/// button, which opens the website's sign-in page in the browser.
struct SignInView: View {

    let account: Account

    var body: some View {
        VStack(spacing: 0) {
            Text("Retainer")
                .font(Theme.noteFont(size: 30))
                .foregroundStyle(Theme.text)
            Text("Sign in to start.")
                .font(Theme.noteFont(size: 15))
                .foregroundStyle(Theme.textSecondary)
                .padding(.top, 10)

            Button(action: account.beginSignIn) {
                Text(account.phase == .finishing ? "Signing in…" : "Sign in")
                    .font(Theme.mono(12, weight: .medium))
                    .foregroundStyle(Theme.background)
                    .frame(width: 168, height: 34)
                    .background(Theme.text, in: RoundedRectangle(cornerRadius: Theme.radius))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)
            .disabled(account.phase == .finishing)
            .opacity(account.phase == .finishing ? 0.5 : 1)
            .padding(.top, 34)

            Text(line)
                .font(Theme.mono(11))
                .foregroundStyle(Theme.textMuted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320, minHeight: 32, alignment: .top)
                .padding(.top, 18)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
        .animation(.easeOut(duration: 0.12), value: account.phase)
    }

    /// One quiet line under the button: what is happening, or what went wrong.
    private var line: String {
        switch account.phase {
        case .idle: "With Google or your email, in the browser."
        case .waiting: "Finish in the browser. It brings you back here."
        case .finishing: " "
        case .failed(let why): why
        }
    }
}

/// The window's content: the board, once someone is signed in.
struct GateView: View {

    let app: AppModel

    var body: some View {
        Group {
            if app.account.isSignedIn {
                RootView(app: app)
            } else {
                SignInView(account: app.account)
                    .preferredColorScheme(app.settings.lightMode ? .light : .dark)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.2), value: app.account.isSignedIn)
    }
}
