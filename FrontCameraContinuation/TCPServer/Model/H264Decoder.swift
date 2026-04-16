//
//  H264Decoder.swift
//  FrontCameraContinuation
//
//  Created by Siarhei Yakushevich on 16/04/2026.
//


import VideoToolbox

final class H264Decoder {
    
    func decode(_ data: Data) {
        // For minimal demo: just confirm data arrives
        debugPrint("Frame received:", data.count)
        
        // Full decode requires SPS/PPS parsing (next step)
    }
}
