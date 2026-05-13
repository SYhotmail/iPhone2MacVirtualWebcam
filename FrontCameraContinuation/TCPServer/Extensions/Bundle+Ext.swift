//
//  Bundle+Ext.swift
//  Cam2Mac
//
//  Created by Siarhei Yakushevich on 13/05/2026.
//

import Foundation

extension Bundle {
    func stringFromInfoDictionary(forKey key: String) -> String? {
        infoDictionary?[key] as? String
    }
    
    var bundleShortVersionString: String? {
        stringFromInfoDictionary(forKey: "CFBundleShortVersionString")
    }
    
    var buildVersionString: String? {
        stringFromInfoDictionary(forKey: "CFBundleVersion")
    }
}
