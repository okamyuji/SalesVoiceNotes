//
//  Item.swift
//  SalesVoiceNotes
//
//  Created by systemi on 2025/12/12.
//

import Foundation
import SwiftData

@Model
final class Item {
    var timestamp: Date
    
    init(timestamp: Date) {
        self.timestamp = timestamp
    }
}
