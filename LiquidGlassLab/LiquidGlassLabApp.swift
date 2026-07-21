import SwiftUI

@main
struct LiquidGlassLabApp: App {
    @State private var glassLabState = GlassLabState()

    var body: some Scene {
        Window("Liquid Glass Lab", id: "main") {
            LiquidGlassLabNavigation(state: glassLabState)
                .frame(minWidth: 860, minHeight: 720)
                .onDisappear {
                    glassLabState.testWindow.tearDown()
                }
        }
        .defaultSize(width: 960, height: 900)
    }
}

private struct LiquidGlassLabNavigation: View {
    let state: GlassLabState

    var body: some View {
        NavigationSplitView {
            List(selection: rendererSelection) {
                ForEach(GlassLabRendererMode.allCases) { mode in
                    Label(mode.navigationTitle, systemImage: mode.navigationIcon)
                        .tag(mode)
                }
            }
            .navigationTitle("Liquid Glass Lab")
            .navigationSplitViewColumnWidth(min: 160, ideal: 180, max: 220)
        } detail: {
            GlassLabView(state: state)
        }
    }

    private var rendererSelection: Binding<GlassLabRendererMode?> {
        Binding {
            state.rendererMode
        } set: { mode in
            guard let mode else { return }
            state.rendererMode = mode
        }
    }
}
