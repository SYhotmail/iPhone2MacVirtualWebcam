import SwiftUI

struct ContentView: View {
    @StateObject private var manager = StreamManager()
    @State private var host = "192.168.1.10"
    @State private var port = "9999"
    @State private var streamSize: StreamSize = .full
    @State private var previewExpanded = false
    @FocusState private var focusedField: Field?

    private enum Field {
        case host
        case port
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.97, green: 0.55, blue: 0.29),
                    Color(red: 0.71, green: 0.18, blue: 0.32),
                    Color(red: 0.14, green: 0.16, blue: 0.33)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
            
            ScrollView(.vertical) {
                LazyVStack(spacing: 20) {
                    headerSection
                    /*DisclosureGroup(isExpanded: $previewExpanded.animation()) {
                        previewSection
                            .transition(.slide)
                    } label: {
                        Text("Preview")
                    }.tint(.white) */
                    // TODO: improve preview...
                    previewSection
                    controlsSection
                }
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 28)
            }
        }
        .onAppear {
            manager.preparePreview(streamSize: streamSize)
        }
        .onTapGesture {
            focusedField = nil
        }
        .onChange(of: streamSize) { newValue in
            guard !manager.isStreaming else { return }
            manager.preparePreview(streamSize: newValue)
        }
    }

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Front Camera Studio")
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)

                    Text("Preview your iPhone feed, fine-tune the stream target, then go live in one tap.")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.82))
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()

                statusBadge
            }

            HStack(spacing: 10) {
                featureChip(title: "Front Camera", systemImage: "camera.fill")
                featureChip(title: streamSize.title, systemImage: "dial.medium")
            }
        }
    }

    private var previewSection: some View {
        ZStack(alignment: .bottomLeading) {
            CameraPreviewView(session: manager.previewSession)
                .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
                .overlay(alignment: .topTrailing) {
                    Text(manager.isStreaming ? "LIVE" : "READY")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(manager.isStreaming ? Color.red : Color.black.opacity(0.55), in: Capsule())
                        .padding(16)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 30, style: .continuous)
                        .stroke(.white.opacity(0.22), lineWidth: 1)
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
                Text(manager.isStreaming ? "Streaming to your Mac right now." : "Camera is warmed up so you can frame the shot before going live.")
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
                        .foregroundStyle(.white.opacity(0.82))

                    Picker("Video Resolution", selection: $streamSize) {
                        ForEach(manager.supportedCameraSessionPresets()) { size in
                            Text(size.title).tag(size)
                        }
                    }
                    .pickerStyle(.menu)
                    .tint(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(.white.opacity(0.12), lineWidth: 1)
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
                            ? [Color(red: 0.87, green: 0.21, blue: 0.28), Color(red: 0.60, green: 0.11, blue: 0.16)]
                            : [Color(red: 0.16, green: 0.77, blue: 0.63), Color(red: 0.11, green: 0.54, blue: 0.72)],
                        startPoint: .leading,
                        endPoint: .trailing
                    ),
                    in: RoundedRectangle(cornerRadius: 20, style: .continuous)
                )
                .shadow(color: .black.opacity(0.22), radius: 20, y: 10)
            }

            Text("Tip: keep this preview open while you adjust framing. The stream will reconnect automatically after minor interruptions.")
                .lineLimit(nil)
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.72))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(20)
        .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(.white.opacity(0.14), lineWidth: 1)
        }
    }

    private var statusBadge: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(manager.isStreaming ? Color.green : Color.yellow)
                .frame(width: 10, height: 10)
            Text(manager.isStreaming ? "Connected" : "Standby")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.white.opacity(0.14), in: Capsule())
    }

    private func featureChip(title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.white.opacity(0.92))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.white.opacity(0.14), in: Capsule())
    }

    private func settingField(title: String, systemImage: String, prompt: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white.opacity(0.82))

            TextField(prompt, text: text)
                .font(.body.weight(.medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(.white.opacity(0.12), lineWidth: 1)
                }
        }
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
