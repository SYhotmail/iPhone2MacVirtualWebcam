import SwiftUI

struct ContentView: View {
    @Environment(\.colorScheme) private var colorScheme
    @StateObject private var manager = StreamManager()
    @AppStorage("host") private var host = "192.168.1.10"
    @AppStorage("port") private var port = "9999"
    @State private var streamSize: StreamSize = .full
    @State private var isPreviewVisible = true
    @FocusState private var focusedField: Field?

    private enum Field {
        case host
        case port
    }

    private var palette: ViewPalette {
        ViewPalette(colorScheme: colorScheme)
    }

    var body: some View {
        ZStack {
            backgroundGradient
                .ignoresSafeArea()

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 20) {
                    headerSection
                    if isPreviewVisible {
                        previewSection
                            .transition(.slide.combined(with: .opacity))
                    } else {
                        collapsedPreviewButton
                    }
                    controlsSection
                }
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 28)
            }
        }
        .animation(.spring(response: 0.38, dampingFraction: 0.88), value: isPreviewVisible)
        .onAppear {
            manager.preparePreview(streamSize: streamSize)
        }
        .onTapGesture {
            focusedField = nil
        }
        .onChange(of: streamSize) {
            guard !manager.isStreaming else { return }
            manager.preparePreview(streamSize: streamSize)
        }
    }

    private var backgroundGradient: LinearGradient {
        LinearGradient(
            colors: palette.backgroundGradient,
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Send Camera to Mac")
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                        .foregroundStyle(primaryTextColor)

                    Text("Frame your shot on iPhone, then send the front camera feed straight to your Mac in one tap.")
                        .font(.subheadline)
                        .foregroundStyle(secondaryTextColor)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity)
                }

                Spacer()

                statusBadge
            }

            HStack(spacing: 10) {
                featureChip(title: "Front Camera", systemImage: "camera.fill")
                featureChip(title: streamSize.title, systemImage: "dial.medium")
                /*featureChip(title: isPreviewVisible ? "Preview On" : "Preview Off", systemImage: isPreviewVisible ? "eye.fill" : "eye.slash.fill") */
            }
        }
    }

    private var previewSection: some View {
        ZStack(alignment: .bottomLeading) {
            CameraPreviewView(session: manager.previewSession)
                .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
                .overlay(alignment: .topTrailing) {
                    HStack(spacing: 10) {
                        Button {
                            isPreviewVisible.toggle()
                        } label: {
                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(.white)
                                .frame(width: 38, height: 38)
                                .background(.black.opacity(0.42), in: Circle())
                        }
                        .accessibilityLabel("Hide preview")

                        Text(manager.isStreaming ? "LIVE" : "READY")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(manager.isStreaming ? Color.red : Color.black.opacity(0.55), in: Capsule())
                    }
                    .onTapGesture {
                        isPreviewVisible.toggle()
                    }
                    .padding(16)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 30, style: .continuous)
                        .stroke(.white.opacity(0.22), lineWidth: 1)
                        .allowsHitTesting(false)
                }
                .shadow(color: .black.opacity(0.22), radius: 28, y: 16)

            LinearGradient(
                colors: [.clear, .black.opacity(0.5)],
                startPoint: .center,
                endPoint: .bottom
            )
            .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))

            VStack(alignment: .leading, spacing: 6) {
                Text("Preview")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.white)
                Text(manager.isStreaming ? "Sending the front camera feed to your Mac right now." : "Camera is warmed up so you can frame the shot before sending it to your Mac.")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.82))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 360)
    }

    private var controlsSection: some View {
        VStack(spacing: 16) {
            VStack(spacing: 14) {
                settingField(
                    title: "Mac Address",
                    systemImage: "desktopcomputer",
                    prompt: "192.168.1.10",
                    text: $host
                )
                .focused($focusedField, equals: .host)
                .textContentType(.URL)
                .keyboardType(.numbersAndPunctuation)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.next)

                settingField(
                    title: "Port",
                    systemImage: "network",
                    prompt: "9999",
                    text: $port
                )
                .focused($focusedField, equals: .port)
                .keyboardType(.numberPad)
                .submitLabel(.done)

                VStack(alignment: .leading, spacing: 10) {
                    Label("Video Resolution", systemImage: "viewfinder")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(secondaryTextColor)

                    Picker("Video Resolution", selection: $streamSize) {
                        ForEach(manager.supportedCameraSessionPresets()) { size in
                            Text(size.title).tag(size)
                        }
                    }
                    .pickerStyle(.menu)
                    .tint(primaryTextColor)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(fieldBackgroundColor, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(fieldBorderColor, lineWidth: 1)
                    }
                    .disabled(manager.isStreaming)
                }
            }

            Button(action: toggleStreaming) {
                HStack(spacing: 10) {
                    Image(systemName: manager.isStreaming ? "stop.fill" : "bolt.fill")
                        .font(.headline)
                    Text(manager.isStreaming ? "Stop Stream" : "Start Stream")
                        .font(.headline.weight(.semibold))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
                .background(
                    LinearGradient(
                        colors: manager.isStreaming
                            ? palette.stopActionColors
                            : palette.startActionColors,
                        startPoint: .leading,
                        endPoint: .trailing
                    ),
                    in: RoundedRectangle(cornerRadius: 20, style: .continuous)
                )
                .shadow(color: .black.opacity(0.22), radius: 20, y: 10)
            }

            Text("Tip: keep this preview open while you adjust framing. The stream will reconnect automatically after minor interruptions.")
                .font(.footnote)
                .foregroundStyle(secondaryTextColor)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(20)
        .background(cardBackgroundColor, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(cardBorderColor, lineWidth: 1)
        }
    }

    private var statusBadge: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(manager.isStreaming ? Color.green : Color.yellow)
                .frame(width: 10, height: 10)
            Text(manager.isStreaming ? "Connected" : "Standby")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(primaryTextColor)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(cardBackgroundColor, in: Capsule())
    }

    private func featureChip(title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(primaryTextColor)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(cardBackgroundColor, in: Capsule())
    }

    private func settingField(title: String, systemImage: String, prompt: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(secondaryTextColor)

            TextField(prompt, text: text)
                .font(.body.weight(.medium))
                .foregroundStyle(primaryTextColor)
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .background(fieldBackgroundColor, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(fieldBorderColor, lineWidth: 1)
                }
        }
    }

    private var collapsedPreviewButton: some View {
        HStack {
            Spacer()

            Button {
                isPreviewVisible.toggle()
            } label: {
                Label("Show Preview", systemImage: "arrow.down.right.and.arrow.up.left")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(primaryTextColor)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(cardBackgroundColor, in: Capsule())
                    .overlay {
                        Capsule()
                            .stroke(cardBorderColor, lineWidth: 1)
                    }
            }
        }
    }

    private var primaryTextColor: Color {
        palette.primaryText
    }

    private var secondaryTextColor: Color {
        palette.secondaryText
    }

    private var cardBackgroundColor: Color {
        palette.cardBackground
    }

    private var cardBorderColor: Color {
        palette.cardBorder
    }

    private var fieldBackgroundColor: Color {
        palette.fieldBackground
    }

    private var fieldBorderColor: Color {
        palette.fieldBorder
    }

    private func toggleStreaming() {
        focusedField = nil

        if manager.isStreaming {
            manager.stopStreaming()
        } else {
            manager.startStreaming(
                host: host.trimmingCharacters(in: .whitespacesAndNewlines),
                port: UInt16(port) ?? 9999,
                streamSize: streamSize
            )
        }
    }
}

#Preview {
    ContentView()
}
