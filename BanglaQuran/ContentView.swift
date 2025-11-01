//
//  ContentView.swift
//  BanglaQuran
//
//  Created by Shahjahan Rasel on 10/31/25.
//

import SwiftUI

struct ContentView: View {
    @StateObject private var appEnvironment = AppEnvironment()

    var body: some View {
        SurahListView()
            .environmentObject(appEnvironment)
            .environmentObject(appEnvironment.surahListViewModel)
            .environmentObject(appEnvironment.playbackViewModel)
            .environmentObject(appEnvironment.preferencesViewModel)
            .environmentObject(appEnvironment.progressViewModel)
    }
}

#Preview {
    ContentView()
}
