//
//  ContentView.swift
//  TCPServer
//
//  Created by Siarhei Yakushevich on 16/04/2026.
//

import SwiftUI
internal import AVFoundation

struct ConnectView: View {
    @Environment(\.colorScheme) private var colorScheme
    @State private var viewModel = ConnectViewModel()

    private var palette: ConnectViewPalette {
        ConnectViewPalette(colorScheme: colorScheme)
    }
    
    var body: some View {
        GeometryReader { proxy in
            let availableWidth = max(proxy.size.width - (ConnectViewLayout.outerPadding * 2), ConnectViewLayout.minimumWindowSize.width)
            let availableHeight = max(proxy.size.height - (ConnectViewLayout.outerPadding * 2), ConnectViewLayout.minimumWindowSize.height)
            let sidebarWidth = ConnectViewLayout.sidebarWidth(for: availableWidth)
            let previewHeight = ConnectViewLayout.previewHeight(for: availableHeight)

            ZStack {
                LinearGradient(
                    colors: palette.backgroundGradient,
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()

                Circle()
                    .fill(.white.opacity(colorScheme == .dark ? 0.08 : 0.26))
                    .frame(width: ConnectViewLayout.heroOrbSize, height: ConnectViewLayout.heroOrbSize)
                    .blur(radius: ConnectViewLayout.heroOrbBlur)
                    .offset(ConnectViewLayout.heroOrbOffset)

                Circle()
                    .fill(Color.cyan.opacity(colorScheme == .dark ? 0.16 : 0.22))
                    .frame(width: ConnectViewLayout.accentOrbSize, height: ConnectViewLayout.accentOrbSize)
                    .blur(radius: ConnectViewLayout.accentOrbBlur)
                    .offset(ConnectViewLayout.accentOrbOffset)

                ScrollView(showsIndicators: false) {
                    VStack(spacing: ConnectViewLayout.sectionSpacing) {
                        headerCard

                        HStack(alignment: .top, spacing: ConnectViewLayout.columnSpacing) {
                            VStack(spacing: ConnectViewLayout.sectionSpacing) {
                                controlCard
                                statusCard
                            }
                            .frame(width: sidebarWidth)

                            previewCard(height: previewHeight)
                                .frame(minWidth: ConnectViewLayout.previewMinWidth)
                        }
                    }
                    .padding(ConnectViewLayout.outerPadding)
                }
            }
        }
        .onAppear {
            viewModel.refreshNetworkAddresses()
        }
        .frame(minWidth: ConnectViewLayout.minimumWindowSize.width, minHeight: ConnectViewLayout.minimumWindowSize.height)
    }

    private var headerCard: some View {
        HStack(alignment: .top, spacing: ConnectViewLayout.headerSpacing) {
            VStack(alignment: .leading, spacing: ConnectViewLayout.textStackSpacing) {
                Text("Remote Camera Receiver")
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .foregroundStyle(palette.primaryText)

                Text("Receive your iPhone camera feed, preview it live on your Mac, and publish it as a virtual camera for Zoom, Meet, and QuickTime.")
                    .font(.title3.weight(.medium))
                    .foregroundStyle(palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: ConnectViewLayout.textStackSpacing) {
                    infoPill(
                        title: viewModel.isRunning ? "Listening on \(viewModel.listenPort)" : "Listener stopped",
                        systemImage: viewModel.isRunning ? "dot.radiowaves.left.and.right" : "pause.circle",
                        accent: viewModel.isRunning ? palette.successColor : palette.cautionColor
                    )

                    infoPill(
                        title: viewModel.primaryAddressText,
                        systemImage: "network",
                        accent: palette.primaryText.opacity(0.7)
                    )
                }
            }

            Spacer(minLength: 20)

            overallStatusCard
                .frame(width: ConnectViewLayout.statusCardWidth)
        }
        .padding(ConnectViewLayout.outerPadding)
        .background(palette.panelBackground, in: RoundedRectangle(cornerRadius: ConnectViewLayout.headerCornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: ConnectViewLayout.headerCornerRadius, style: .continuous)
                .stroke(palette.panelBorder, lineWidth: 1)
        }
    }

    private var controlCard: some View {
        VStack(alignment: .leading, spacing: ConnectViewLayout.headerSpacing) {
            Text("Controls")
                .font(.title2.weight(.bold))
                .foregroundStyle(palette.primaryText)

            VStack(alignment: .leading, spacing: ConnectViewLayout.actionSpacing) {
                Text("1. Start the Mac receiver")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(palette.primaryText)

                Text("Keep the receiver running before you open the iPhone app. The listener uses port \(viewModel.listenPort) by default.")
                    .font(.subheadline)
                    .foregroundStyle(palette.secondaryText)

                actionButton(
                    title: viewModel.isRunning ? "Stop Receiver" : "Start Receiver",
                    subtitle: viewModel.isRunning ? "Stop accepting incoming frames from the iPhone." : "Open the listener so the iPhone can connect.",
                    systemImage: viewModel.isRunning ? "stop.fill" : "play.fill",
                    gradient: viewModel.isRunning ? palette.destructiveGradient : palette.activeGradient,
                    action: viewModel.toggleServer
                )
            }

            Divider()
                .overlay(palette.panelBorder)

            VStack(alignment: .leading, spacing: ConnectViewLayout.actionSpacing) {
                Text("2. Prepare the virtual camera")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(palette.primaryText)

                Text("Install the system extension after moving the app to `/Applications`. You can remove it again later from the same screen.")
                    .font(.subheadline)
                    .foregroundStyle(palette.secondaryText)

                HStack(spacing: ConnectViewLayout.actionSpacing) {
                    secondaryActionButton(
                        title: "Install Camera",
                        systemImage: "arrow.down.circle.fill",
                        action: viewModel.installCamera
                    )

                    secondaryActionButton(
                        title: "Remove Camera",
                        systemImage: "trash.circle.fill",
                        action: viewModel.uninstallCamera
                    )
                }
            }

            if viewModel.installerNeedsApplicationsMove {
                Label("Open the copy in `/Applications` before installing the system extension.", systemImage: "arrow.up.right.square")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(palette.cautionColor)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(palette.secondaryPanelBackground, in: RoundedRectangle(cornerRadius: ConnectViewLayout.infoBannerCornerRadius, style: .continuous))
            }

            connectionHint
        }
        .padding(ConnectViewLayout.cardPadding)
        .background(palette.panelBackground, in: RoundedRectangle(cornerRadius: ConnectViewLayout.cardCornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: ConnectViewLayout.cardCornerRadius, style: .continuous)
                .stroke(palette.panelBorder, lineWidth: 1)
        }
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: ConnectViewLayout.contentSpacing) {
            Text("Status")
                .font(.title2.weight(.bold))
                .foregroundStyle(palette.primaryText)

            LazyVGrid(columns: [
                GridItem(.flexible(), spacing: ConnectViewLayout.actionSpacing),
                GridItem(.flexible(), spacing: ConnectViewLayout.actionSpacing)
            ], spacing: ConnectViewLayout.actionSpacing) {
                metricCard(
                    title: "Listener",
                    value: viewModel.listenerStatus,
                    systemImage: "dot.radiowaves.left.and.right",
                    tint: listenerTint
                )

                metricCard(
                    title: "Connection",
                    value: viewModel.connectionStatus,
                    systemImage: "cable.connector",
                    tint: connectionTint
                )

                metricCard(
                    title: "Virtual Camera",
                    value: viewModel.installer.status,
                    systemImage: "camera.badge.ellipsis",
                    tint: installerTint
                )

                metricCard(
                    title: "Stream",
                    value: viewModel.streamSummary,
                    systemImage: "video.badge.waveform",
                    tint: viewModel.connectionReady ? palette.successColor : palette.cautionColor
                )
            }
        }
        .padding(ConnectViewLayout.cardPadding)
        .background(palette.panelBackground, in: RoundedRectangle(cornerRadius: ConnectViewLayout.cardCornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: ConnectViewLayout.cardCornerRadius, style: .continuous)
                .stroke(palette.panelBorder, lineWidth: 1)
        }
    }

    private func previewCard(height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: ConnectViewLayout.contentSpacing) {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Live Preview")
                        .font(.title2.weight(.bold))
                        .foregroundStyle(palette.primaryText)

                    Text(viewModel.previewSubtitle)
                        .font(.subheadline)
                        .foregroundStyle(palette.secondaryText)
                }

                Spacer()

                infoPill(
                    title: viewModel.connectionReady ? "Receiving Feed" : "Awaiting Stream",
                    systemImage: viewModel.connectionReady ? "dot.circle.and.hand.point.up.left.fill" : "hourglass",
                    accent: viewModel.connectionReady ? palette.successColor : palette.cautionColor
                )
            }

            ZStack {
                VideoViewRepresentable(decoder: viewModel.manager.decoder)
                    .clipShape(RoundedRectangle(cornerRadius: ConnectViewLayout.previewCornerRadius, style: .continuous))

                RoundedRectangle(cornerRadius: ConnectViewLayout.previewCornerRadius, style: .continuous)
                    .fill(.black.opacity(viewModel.connectionReady ? 0.08 : 0.38))

                if !viewModel.connectionReady {
                    VStack(spacing: ConnectViewLayout.emptyStateSpacing) {
                        Image(systemName: viewModel.isRunning ? "iphone.gen3.radiowaves.left.and.right" : "play.square.stack")
                            .font(.system(size: 42, weight: .medium))
                            .foregroundStyle(.white.opacity(0.88))

                        Text(viewModel.isRunning ? "Waiting for iPhone stream" : "Start the receiver to begin")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.white)

                        Text(viewModel.isRunning
                             ? "Open the iPhone app and send video to \(viewModel.primaryAddressForConnection):\(viewModel.listenPort)."
                             : "Turn on the receiver first, then connect from the iPhone app using the same Wi-Fi network.")
                            .font(.subheadline)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.white.opacity(0.8))
                            .frame(maxWidth: ConnectViewLayout.previewTextMaxWidth)
                    }
                    .padding(32)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .overlay {
                RoundedRectangle(cornerRadius: ConnectViewLayout.previewCornerRadius, style: .continuous)
                    .stroke(.white.opacity(0.14), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.18), radius: 30, y: 18)
        }
        .padding(ConnectViewLayout.cardPadding)
        .frame(maxWidth: .infinity)
        .background(palette.panelBackground, in: RoundedRectangle(cornerRadius: ConnectViewLayout.cardCornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: ConnectViewLayout.cardCornerRadius, style: .continuous)
                .stroke(palette.panelBorder, lineWidth: 1)
        }
    }

    private var overallStatusCard: some View {
        VStack(alignment: .leading, spacing: ConnectViewLayout.textStackSpacing) {
            Label(viewModel.overallStatusTitle, systemImage: viewModel.overallStatusIcon)
                .font(.headline.weight(.semibold))
                .foregroundStyle(palette.primaryText)

            Text(viewModel.overallStatusMessage)
                .font(.subheadline)
                .foregroundStyle(palette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(ConnectViewLayout.compactCardPadding)
        .background(palette.secondaryPanelBackground, in: RoundedRectangle(cornerRadius: ConnectViewLayout.nestedCardCornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: ConnectViewLayout.nestedCardCornerRadius, style: .continuous)
                .stroke(overallStatusTint.opacity(0.32), lineWidth: 1)
        }
    }

    private var connectionHint: some View {
        VStack(alignment: .leading, spacing: ConnectViewLayout.textStackSpacing) {
            HStack {
                Label("Connect from iPhone", systemImage: "iphone.gen3")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(palette.primaryText)

                Spacer()

                Button("Copy Address") {
                    viewModel.copyConnectionAddress()
                }
                .buttonStyle(.plain)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(palette.primaryText)
            }

            Text("\(viewModel.primaryAddressForConnection):\(viewModel.listenPort)")
                .font(.system(.title3, design: .monospaced).weight(.semibold))
                .foregroundStyle(palette.primaryText)

            Text("Use this LAN address in the iPhone app. If you have multiple interfaces, pick the one shared with the phone.")
                .font(.footnote)
                .foregroundStyle(palette.secondaryText)

            Text("Need a reminder? Open `Help > Quick Setup` from the menu bar.")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(palette.primaryText.opacity(0.8))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(ConnectViewLayout.inputPadding)
        .background(palette.secondaryPanelBackground, in: RoundedRectangle(cornerRadius: ConnectViewLayout.compactControlCornerRadius, style: .continuous))
    }

    private var listenerReady: Bool {
        viewModel.listenerReady
    }

    private var overallStatusTint: Color {
        if viewModel.connectionReady {
            return palette.successColor
        }

        if listenerReady || viewModel.installerHealthy {
            return palette.cautionColor
        }

        return Color.red.opacity(0.8)
    }

    private var listenerTint: Color {
        listenerReady ? palette.successColor : palette.cautionColor
    }

    private var connectionTint: Color {
        viewModel.connectionReady ? palette.successColor : palette.cautionColor
    }

    private var installerTint: Color {
        viewModel.installerHealthy ? palette.successColor : (viewModel.installerNeedsApplicationsMove ? palette.cautionColor : palette.primaryText.opacity(0.72))
    }

    private func infoPill(title: String, systemImage: String, accent: Color) -> some View {
        Label(title, systemImage: systemImage)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(palette.primaryText)
            .padding(.horizontal, ConnectViewLayout.badgeHorizontalPadding)
            .padding(.vertical, ConnectViewLayout.badgeVerticalPadding)
            .background(palette.secondaryPanelBackground, in: Capsule())
            .overlay {
                Capsule()
                    .stroke(accent.opacity(0.28), lineWidth: 1)
            }
    }

    private func actionButton(title: String,
                              subtitle: String,
                              systemImage: String,
                              gradient: [Color],
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                Label(title, systemImage: systemImage)
                    .font(.headline.weight(.semibold))

                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.82))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
            .background(
                LinearGradient(colors: gradient, startPoint: .leading, endPoint: .trailing),
                in: RoundedRectangle(cornerRadius: ConnectViewLayout.controlCornerRadius, style: .continuous)
            )
        }
        .buttonStyle(.plain)
    }

    private func secondaryActionButton(title: String,
                                       systemImage: String,
                                       action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(palette.primaryText)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(palette.secondaryPanelBackground, in: RoundedRectangle(cornerRadius: ConnectViewLayout.infoBannerCornerRadius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: ConnectViewLayout.infoBannerCornerRadius, style: .continuous)
                        .stroke(palette.panelBorder, lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
    }

    private func metricCard(title: String,
                            value: String,
                            systemImage: String,
                            tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: systemImage)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(palette.secondaryText)

            Text(value)
                .font(.headline.weight(.semibold))
                .foregroundStyle(palette.primaryText)
                .fixedSize(horizontal: false, vertical: true)

            Capsule()
                .fill(tint)
                .frame(width: ConnectViewLayout.statusCapsuleWidth, height: ConnectViewLayout.statusCapsuleHeight)
        }
        .frame(maxWidth: .infinity, minHeight: ConnectViewLayout.metricCardMinHeight, alignment: .topLeading)
        .padding(ConnectViewLayout.inputPadding)
        .background(palette.secondaryPanelBackground, in: RoundedRectangle(cornerRadius: ConnectViewLayout.controlCornerRadius, style: .continuous))
    }
}

#Preview {
    ConnectView()
}
