//
//  StockroomApp.swift
//  Stockroom
//
//  Created by Christopher Reiter on 10/16/26.
//

import SwiftUI

@main
struct StockroomApp: App {
    @State private var store = BoxStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
        }
    }
}
