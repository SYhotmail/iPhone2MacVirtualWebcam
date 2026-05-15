//
//  ViewRepresentable.swift
//  FrontCameraContinuation
//
//  Created by Siarhei Yakushevich on 15/05/2026.
//

import SwiftUI

#if os(iOS)
import UIKit
typealias PlatformView = UIView
typealias PlatformViewRepresentable = UIViewRepresentable
#elseif os(macOS)
import AppKit
typealias PlatformView = NSView
typealias PlatformViewRepresentable = NSViewRepresentable
#endif

protocol PlatformNativeViewRepresentable: PlatformViewRepresentable {
#if os(iOS)
typealias PlatformViewType = UIViewType
#elseif os(macOS)
typealias PlatformViewType = NSViewType
#endif
    
    func makePlatformView(context: Context) -> PlatformViewType
    func updatePlatformView(_ view: PlatformViewType, context: Context)
    static func dismantleView(_ view: PlatformViewType, coordinator: Coordinator)
}

#if os(iOS)
extension PlatformNativeViewRepresentable {
    func makeUIView(context: Context) -> PlatformViewType {
        makePlatformView(context: context)
    }

    func updateUIView(_ uiView: PlatformViewType, context: Context) {
        updatePlatformView(uiView, context: context)
    }
    
    static func dismantleView(_ view: PlatformViewType, coordinator: Coordinator) {
        dismantleUIView(view, coordinator: coordinator)
    }
}
#elseif os(macOS)
extension PlatformNativeViewRepresentable {
    func makeNSView(context: Context) -> PlatformViewType {
        makePlatformView(context: context)
    }

    func updateNSView(_ nsView: PlatformViewType, context: Context) {
        updatePlatformView(nsView, context: context)
    }
    
    static func dismantleView(_ view: PlatformViewType, coordinator: Coordinator) {
        dismantleNSView(view, coordinator: coordinator)
    }
}
#endif
