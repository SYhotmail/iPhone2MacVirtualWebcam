//
//  main.swift
//  VirtualCameraExtension
//
//  Created by Siarhei Yakushevich on 18/04/2026.
//

import Foundation
import CoreMediaIO

let providerSource = VirtualCameraExtensionProviderSource(clientQueue: nil)
CMIOExtensionProvider.startService(provider: providerSource.provider)

CFRunLoopRun()
