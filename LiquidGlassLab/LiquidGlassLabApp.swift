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
            List(selection: sectionSelection) {
                ForEach(GlassLabSection.allCases) { section in
                    Label(section.navigationTitle, systemImage: section.navigationIcon)
                        .tag(section)
                }
            }
            .navigationTitle("Liquid Glass Lab")
            .navigationSplitViewColumnWidth(min: 160, ideal: 180, max: 220)
        } detail: {
            GlassLabView(state: state)
        }
    }

    private var sectionSelection: Binding<GlassLabSection?> {
        Binding {
            state.selectedSection
        } set: { section in
            guard let section else { return }
            state.selectedSection = section
            if let mode = section.requiredRendererMode {
                state.rendererMode = mode
            }
        }
    }
}
