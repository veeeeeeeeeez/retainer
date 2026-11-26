import SwiftUI

/// The settings, opened from the gear at the bottom left of the window:
/// light or dark, tidy on or off, sample days on or off, which mini map,
/// and which speech engine to use.
///
/// Tidy and the speech engine are the same switches as in the menu bar
/// item; they are repeated here so everything that can be set is in one
/// place.
struct SettingsPanel: View {

    let app: AppModel
    var onClose: () -> Void

    /// What is typed into the key's field. The key itself is never shown.
    @State private var typedKey = ""
    @State private var hasKey = SearchKey.read() != nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("settings")
                    .font(Theme.mono(11, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                // Escape closes the panel, unless a card is open: then it is the card's.
                Button("done", action: onClose)
                    .buttonStyle(QuietButtonStyle())
                    .keyboardShortcut(escapeCloses ? .cancelAction : nil)
            }
            .padding(.horizontal, Theme.Space.l)
            .frame(height: 36)

            rule

            row("Account", detail: app.account.email ?? "Not signed in.") {
                if app.account.isSignedIn {
                    Button("sign out") { app.account.signOut() }
                        .buttonStyle(QuietButtonStyle())
                }
            }

            rule

            switchRow(
                "Cloud mode",
                detail: cloudDetail,
                isOn: Binding(get: { app.cloud.isOn }, set: { app.cloud.isOn = $0 }))

            rule

            switchRow(
                "Light mode",
                detail: "The capture overlay stays dark either way.",
                isOn: Binding(get: { app.settings.lightMode }, set: { app.settings.lightMode = $0 }))

            rule

            switchRow(
                "Tidy transcripts",
                detail: tidyDetail,
                isOn: Binding(get: { app.settings.tidyEnabled }, set: { app.settings.tidyEnabled = $0 }))

            rule

            switchRow(
                "Sample days",
                detail: "Fills the timeline with made-up past days while there are few real ones. Nothing done to them is saved.",
                isOn: Binding(get: { app.settings.sampleDays }, set: { app.settings.sampleDays = $0 }))

            rule

            row("Mini map") {
                SegmentedPill(
                    options: MiniMapStyle.allCases, selection: app.settings.miniMapStyle, title: \.title
                ) { style in
                    app.settings.miniMapStyle = style
                }
            }

            rule

            row(
                "Search by meaning",
                detail: hasKey
                    ? "On. When you search, your notes' words and the text in their pictures go to Anthropic."
                    : "Paste an Anthropic key to search by meaning as well as by words. Until then nothing leaves this Mac."
            ) {
                if hasKey {
                    Button("remove key") {
                        SearchKey.save("")
                        hasKey = false
                    }
                    .buttonStyle(QuietButtonStyle())
                } else {
                    SecureField("sk-ant-…", text: $typedKey)
                        .textFieldStyle(.plain)
                        .font(Theme.mono(11))
                        .padding(.horizontal, 8)
                        .frame(width: 130, height: 24)
                        .background(Theme.panelRaised, in: RoundedRectangle(cornerRadius: Theme.radiusSmall))
                        .onSubmit {
                            if SearchKey.save(typedKey) { hasKey = SearchKey.read() != nil }
                            typedKey = ""
                        }
                }
            }

            rule

            VStack(alignment: .leading, spacing: Theme.Space.s) {
                Text("Speech engine")
                    .font(Theme.mono(12, weight: .medium))
                    .foregroundStyle(Theme.text)
                ForEach(EngineID.allCases, id: \.self) { engine in
                    engineRow(engine)
                }
            }
            .padding(.horizontal, Theme.Space.l)
            .padding(.vertical, Theme.Space.m)
        }
        .frame(width: 420)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.radius))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.radius)
                .strokeBorder(Theme.hairlineStrong, lineWidth: Theme.hairlineWidth)
        }
        // Clicks on the panel itself must not fall through and close it.
        .contentShape(Rectangle())
        .onTapGesture {}
    }

    private var rule: some View {
        Rectangle().fill(Theme.hairline).frame(height: Theme.hairlineWidth)
    }

    private var escapeCloses: Bool {
        app.canvas.expandedNoteID == nil && app.canvas.viewingNoteID == nil
    }

    private var cloudDetail: String {
        switch app.cloud.status {
        case .off: "Off. Your notes and their pictures stay on this Mac."
        case .idle:
            app.cloud.lastSynced == nil
                ? "On. Your notes and their pictures are kept in your account too."
                : "Up to date. Your notes and their pictures are in your account too."
        case .syncing: "Syncing…"
        case .sending(let done, let total): "Sending pictures: \(done) of \(total)."
        case .failed(let why): "Not synced (\(why)). Trying again shortly."
        }
    }

    private var tidyDetail: String {
        if case .unavailable(let reason) = app.tidyAvailability {
            return "Unavailable: \(reason)."
        }
        return "Removes fillers and fixes punctuation, on this Mac."
    }

    private func switchRow(_ title: String, detail: String, isOn: Binding<Bool>) -> some View {
        row(title, detail: detail) {
            Toggle(title, isOn: isOn)
                .toggleStyle(FlatSwitchStyle())
                .labelsHidden()
        }
    }

    /// One setting: its name and a line about it, and the control on the right.
    private func row(_ title: String, detail: String? = nil, @ViewBuilder control: () -> some View) -> some View {
        HStack(alignment: .center, spacing: Theme.Space.m) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(Theme.mono(12, weight: .medium))
                    .foregroundStyle(Theme.text)
                if let detail {
                    Text(detail)
                        .font(Theme.mono(11))
                        .foregroundStyle(Theme.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            control()
        }
        .padding(.horizontal, Theme.Space.l)
        .padding(.vertical, Theme.Space.m)
    }

    private func engineRow(_ engine: EngineID) -> some View {
        let selected = app.engines.selected == engine
        let selectable = app.engines.isSelectable(engine)
        return Button {
            app.engines.select(engine)
        } label: {
            HStack(spacing: Theme.Space.s) {
                // Filled when chosen, hollow when not: state by shape, not colour.
                Circle()
                    .fill(selected ? Theme.text : Color.clear)
                    .overlay { Circle().strokeBorder(selected ? Theme.text : Theme.textMuted, lineWidth: 1) }
                    .frame(width: 8, height: 8)
                Text(engine.displayName)
                    .foregroundStyle(selected ? Theme.text : Theme.textSecondary)
                    .lineLimit(1)
                    .fixedSize()
                Spacer(minLength: Theme.Space.s)
                Text(app.engines.state(of: engine).summary)
                    .foregroundStyle(Theme.textMuted)
                    .lineLimit(1)
            }
            .font(Theme.mono(11))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!selectable)
        .opacity(selectable ? 1 : 0.5)
    }
}

/// A flat on/off switch in the app's own colours: a track and a knob, no
/// tint. On is the bright one.
struct FlatSwitchStyle: ToggleStyle {

    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                Capsule()
                    .fill(configuration.isOn ? Theme.text : Theme.hairlineStrong)
                    .frame(width: 32, height: 18)
                Circle()
                    .fill(configuration.isOn ? Theme.background : Theme.textSecondary)
                    .frame(width: 14, height: 14)
                    .padding(.horizontal, 2)
            }
            .animation(.easeOut(duration: 0.12), value: configuration.isOn)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(.isToggle)
        .accessibilityValue(configuration.isOn ? "on" : "off")
    }
}
