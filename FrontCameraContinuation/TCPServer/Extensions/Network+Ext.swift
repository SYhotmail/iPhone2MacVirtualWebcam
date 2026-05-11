//
//  NW+Ext.swift
//  FrontCameraContinuation
//
//  Created by Siarhei Yakushevich on 11/05/2026.
//
import Network

protocol NetworkConnectionStateProvable {
    var error: NWError? { get }
    var isConnected: Bool { get }
}

extension NWConnection.State : NetworkConnectionStateProvable, @retroactive CustomDebugStringConvertible {
    var error: NWError? {
        switch self {
        case .failed(let error):
            return error
        case .waiting(let error):
            return error
        default:
            return nil
        }
    }
    
    var isConnected: Bool {
        if case .ready = self {
            return true
        }
        
        return false
    }
    
    public var debugDescription: String {
        switch self {
        case .ready:
            return "Ready"
        case .cancelled:
            return "Cancelled"
        case .failed(let error):
            return "Failed: \(error)"
        case .waiting(let error):
            return "Waiting: \(error)"
        case .setup:
            return "Setup"
        case .preparing:
            return "Preparing"
        @unknown default:
            return "Unknown"
        }
    }
}

extension NWListener.State: NetworkConnectionStateProvable, @retroactive CustomDebugStringConvertible {
    var error: NWError? {
        switch self {
        case .failed(let error):
            return error
        case .waiting(let error):
            return error
        default:
            return nil
        }
    }
    
    var isConnected: Bool {
        if case .ready = self {
            return true
        }
        
        return false
    }
    
    public var debugDescription: String {
        switch self {
        case .ready:
            return "Ready"
        case .cancelled:
            return "Cancelled"
        case .failed(let error):
            return "Failed: \(error)"
        case .waiting(let error):
            return "Waiting: \(error)"
        case .setup:
            return "Setup"
        @unknown default:
            return "Unknown"
        }
    }
}
