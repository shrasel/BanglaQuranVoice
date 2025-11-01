//
//  BanglaQuranApp.swift
//  BanglaQuran
//
//  Created by Shahjahan Rasel on 10/31/25.
//

import SwiftUI

@main
struct QuranBanglaPlayerApp: App {
    @StateObject private var environment = AppEnvironment()

    var body: some Scene {
        WindowGroup {
            SurahListView()
                .environmentObject(environment)
                .environmentObject(environment.surahListViewModel)
                .environmentObject(environment.playbackViewModel)
                .environmentObject(environment.preferencesViewModel)
                .environmentObject(environment.progressViewModel)
        }
    }
}
