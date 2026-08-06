//
//  Result+Ext.swift
//  FrontCameraContinuation
//
//  Created by Siarhei Yakushevich on 06/08/2026.
//

extension Result {
    var error: Failure? {
        guard case let .failure(error) = self else { return nil }
        return error
    }
    
    var value: Success? {
        guard case let .success(value) = self else { return nil }
        return value
    }
}
