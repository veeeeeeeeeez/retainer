import SwiftUI

/// Everything drawn over the screen during a capture: the selection, then the
/// lifted screenshot with its prompt, recording pill and editor.
///
/// One view for the whole sequence, in one window, so the hand-off from
/// selection to card has no seam: the screenshot first appears exactly where
/// it was taken, over the same dim, and only then moves.
struct OverlayRootView: View {

    let model: CaptureSessionModel
    /// A fixed waveform level for static renders; `nil` follows the microphone.
    var staticLevel: Float?

    private var liftAnimation: Animation { .easeOut(duration: model.config.liftDuration) }

    var body: some View {
        ZStack(alignment: .topLeading) {
            backdrop
            capturedImage
            glass
            selectionReadout
            belowImage
            pill
        }
        .frame(width: model.screenSize.width, height: model.screenSize.height, alignment: .topLeading)
        .opacity(model.phase == .closing ? 0 : 1)
        .scaleEffect(model.phase == .closing ? 0.985 : 1)
        .animation(.easeOut(duration: 0.16), value: model.phase == .closing)
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
    }

    // MARK: Backdrop

    @ViewBuilder
    private var backdrop: some View {
        if model.image == nil {
            // Light dim everywhere except the rectangle being selected.
            SelectionDim(hole: model.selection, cornerRadius: GlassStyle.capture.cornerRadius)
                .fill(Color.black.opacity(Theme.selectionDim), style: FillStyle(eoFill: true))
        } else {
            // With the screenshot covering the hole the dim can be uniform,
            // and deepen as the capture lifts.
            Color.black
                .opacity(model.lifted ? Theme.cardBackdrop : Theme.selectionDim)
                .animation(liftAnimation, value: model.lifted)
        }
    }

    // MARK: Selection

    /// The glass. One instance for the whole capture: it covers the
    /// selection while it is dragged, then travels with the screenshot to the
    /// centre and stays on the card.
    private var glass: some View {
        GlassPanel(rect: model.imageFrame)
            .animation(liftAnimation, value: model.lifted)
    }

    @ViewBuilder
    private var selectionReadout: some View {
        if !model.lifted && model.phase == .selecting {
            readout
        }
    }

    private var readout: some View {
        let rect = model.selection
        let size = CGSize(width: 84, height: 20)
        // Below the bottom-right corner; tucked inside when there is no room.
        var x = rect.maxX - size.width
        var y = rect.maxY + 10
        if y + size.height > model.screenSize.height - 4 { y = rect.maxY - size.height - 6 }
        x = min(max(x, 4), model.screenSize.width - size.width - 4)
        y = max(y, 4)

        return Text(model.dimensionsLabel)
            .font(Theme.mono(11))
            .foregroundStyle(Theme.text)
            .monospacedDigit()
            .frame(width: size.width, height: size.height)
            .background(Theme.background.opacity(0.9), in: RoundedRectangle(cornerRadius: 3))
            .offset(x: x, y: y)
    }

    // MARK: Screenshot

    @ViewBuilder
    private var capturedImage: some View {
        if let image = model.image {
            let frame = model.imageFrame
            Image(decorative: image.cgImage, scale: image.scale)
                .resizable()
                .interpolation(.high)
                .frame(width: frame.width, height: frame.height)
                // The same rounded shape as the glass that covers it. The saved image keeps its corners.
                .clipShape(RoundedRectangle(cornerRadius: GlassStyle.capture.cornerRadius, style: .circular))
                .position(x: frame.midX, y: frame.midY)
                .animation(liftAnimation, value: model.lifted)
        }
    }

    // MARK: Under the image

    @ViewBuilder
    private var belowImage: some View {
        if model.lifted {
            let origin = model.contentOrigin
            VStack(spacing: 0) {
                switch model.phase {
                case .speaking, .processing:
                    speakingContent
                case .editing, .closing:
                    EditorCard(model: model, staticLevel: staticLevel)
                case .selecting, .capturing:
                    EmptyView()
                }
            }
            .frame(width: model.contentWidth, alignment: .top)
            .offset(x: origin.x, y: origin.y)
            .transition(.opacity.animation(.easeOut(duration: 0.18).delay(0.12)))
            .animation(.easeOut(duration: 0.16), value: model.phase)
        }
    }

    private var speakingContent: some View {
        VStack(spacing: 0) {
            Text("What do you think about this?")
                .font(Theme.noteFont(size: 16))
                .foregroundStyle(Theme.textMuted)
                .frame(height: CaptureSessionModel.promptHeight)

            // Room for the pill, which is positioned separately so it can
            // travel here from the bottom of the screen.
            Color.clear.frame(height: CaptureSessionModel.gapAbovePill + RecordingPill.height)

            // With no key held, what ends the talking has to be said.
            if let hint = model.speakingHint, model.phase == .speaking {
                Text(hint)
                    .font(Theme.mono(10))
                    .foregroundStyle(Theme.textFaint)
                    .padding(.top, 10)
                    .transition(.opacity)
            }

            if !model.interimText.isEmpty {
                Text(model.interimTail)
                    .font(Theme.noteFont(size: 16))
                    .lineSpacing(Theme.noteLineSpacing(size: 16))
                    .foregroundStyle(Theme.text)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity)
                    .padding(.top, Theme.Space.l)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.12), value: model.interimText.isEmpty)
    }

    // MARK: Pill

    @ViewBuilder
    private var pill: some View {
        if showsPill {
            let centre = model.pillCentre
            RecordingPill(
                meter: model.meter,
                mode: model.phase == .processing ? .status(model.processingLabel) : .recording,
                fixedLevel: staticLevel
            )
            // With no key held, a click on the pill ends the talking too.
            .contentShape(Capsule())
            .onTapGesture {
                if model.phase == .speaking { model.onFinishSpeaking?() }
            }
            .position(x: centre.x, y: centre.y)
            .animation(liftAnimation, value: model.lifted)
            .transition(.opacity.animation(.easeOut(duration: 0.12)))
        }
    }

    private var showsPill: Bool {
        switch model.phase {
        case .selecting, .capturing, .speaking, .processing: true
        case .editing, .closing: false
        }
    }
}

/// The note editor shown once recording has stopped: the same pane of
/// frosted glass as the input box in the main window, with the text in it
/// and under the text a quiet row with the two keys, a microphone for
/// saying more, and the save button.
private struct EditorCard: View {

    @Bindable var model: CaptureSessionModel
    /// A fixed waveform level for static renders; `nil` follows the microphone.
    var staticLevel: Float?

    private static let minimumEditorHeight: CGFloat = 72
    private static let cornerRadius: CGFloat = 14

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            if let notice = model.notice {
                Text(notice)
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.text)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 0) {
                MarkdownEditor(
                    text: $model.editorText,
                    fontSize: 16,
                    handle: model.editor,
                    onHeightChange: { model.editorHeight = $0 }
                )
                .frame(height: min(max(model.editorHeight, Self.minimumEditorHeight), model.editorMaxHeight))
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 8)
                .overlay(alignment: .topLeading) {
                    if model.editorText.isEmpty {
                        Text("Type a note")
                            .font(Theme.noteFont(size: 16))
                            .foregroundStyle(Theme.textFaint)
                            .padding(.horizontal, 16)
                            .padding(.top, 14)
                            .allowsHitTesting(false)
                    }
                }

                footer
                    .padding(.horizontal, 14)
                    .padding(.bottom, 12)
            }
            // The screen behind the overlay, frosted: there is nothing of
            // the overlay's own behind the box to frost.
            .floatingGlass(cornerRadius: Self.cornerRadius, tint: 0.78, behindWindow: true)
        }
    }

    @ViewBuilder
    private var footer: some View {
        HStack(spacing: 10) {
            if model.discardArmed {
                Text("esc again to discard  ·  any other key keeps editing")
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Spacer(minLength: Theme.Space.m)
                Button("keep editing") { model.discardArmed = false }
                    .buttonStyle(FlatButtonStyle())
                Button("discard") { model.onDiscard() }
                    .buttonStyle(FlatButtonStyle())
            } else {
                if model.addedVoice == .off {
                    Text("⌘↩ save  ·  esc discard")
                        .font(Theme.mono(10))
                        .foregroundStyle(Theme.textFaint)
                        .fixedSize()
                } else {
                    // More is being said: the same waveform as while the
                    // capture was first spoken about.
                    RecordingPill(
                        meter: model.voiceMeter ?? model.meter,
                        mode: model.addedVoice == .finishing ? .status("transcribing") : .recording,
                        fixedLevel: staticLevel)
                }
                Spacer(minLength: Theme.Space.m)
                // Only when the card is going somewhere the overlay hides.
                if let destination = model.destination {
                    Text(destination)
                        .font(Theme.mono(10))
                        .foregroundStyle(Theme.textMuted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                // The same buttons as the input box in the main window has:
                // a microphone, to say more, and the arrow that sends it.
                voiceButton
                Button {
                    model.onSave()
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.background)
                        .frame(width: 26, height: 26)
                        .background(Theme.text, in: RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
                .help("Save")
                .accessibilityLabel("Save")
            }
        }
        .frame(height: RecordingPill.height)
    }

    /// Switches the microphone back on to add to the note, and off again.
    private var voiceButton: some View {
        let listening = model.addedVoice == .listening
        return Button {
            model.onToggleVoice()
        } label: {
            Image(systemName: listening ? "stop.fill" : "mic")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(listening ? Theme.background : Theme.textSecondary)
                .frame(width: 26, height: 26)
                .background(listening ? Theme.text : Theme.panelRaised, in: RoundedRectangle(cornerRadius: 7))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(model.addedVoice == .finishing)
        .help(listening ? "Stop" : "Say more")
        .accessibilityLabel(listening ? "Stop adding by voice" : "Add more by voice")
    }
}
