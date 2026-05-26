//
//  CancellablePropertyWrapper.swift
//  FrontCameraContinuation
//
//  Created by Siarhei Yakushevich on 14/05/2026.
//

import Combine
import Dispatch

/// A property wrapper that stores an optional `Cancellable` and
/// automatically cancels the previously stored subscription when a new
/// value is assigned.
///
/// Usage:
/// ```swift
/// @Cancelling var token: AnyCancellable?
/// token = publisher.sink { _ in }
/// // assigning a new token cancels the old one automatically
/// $token.cancel()
/// ```
@propertyWrapper
public final class Cancelling<Value> {
    private var storage: Value?

    public init(wrappedValue: Value? = nil) {
        storage = wrappedValue
    }

    public var wrappedValue: Value? {
        get { storage }
        set {
            if !Self.isSameInstance(storage, newValue) {
                cancelCore()
            }
            storage = newValue
        }
    }
    
    private func cancelCore() {
        if let storage = storage as? Cancellable {
            storage.cancel()
        } else if let storage = storage as? DispatchWorkItem {
            storage.cancel()
        } else if let storage = storage as? Task<Void, Never> {
            storage.cancel()
        } else if let storage = storage as? Task<Void, Error> {
            storage.cancel()
        }
    }

    /// Access to the live wrapper to allow manual cancellation when needed.
    public var projectedValue: Cancelling<Value> { self }

    /// Cancel the currently stored cancellable and clear the storage.
    public func cancel() {
        cancelCore()
        storage = nil
    }

    private static func isSameInstance(_ lhs: Value?, _ rhs: Value?) -> Bool {
        if let lhs = lhs as? AnyCancellable, let rhs = rhs as? AnyCancellable {
            return lhs == rhs
        } else if let lhs = lhs as? AnyObject, let rhs = rhs as? AnyObject {
            return lhs === rhs
        }

        return false
    }

    isolated
    deinit {
        cancelCore()
    }
}

/// Convenience typealias for the common `AnyCancellable` case.
public typealias AutoCancel = Cancelling<AnyCancellable>
