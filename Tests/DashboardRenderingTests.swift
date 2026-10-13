import SwiftUI
import Testing
import RealityKit
@testable import InverterLink

@MainActor struct DashboardRenderingTests {
    @Test func homeKeepsItsModelDuringSceneTransitions() async throws {
        let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
        let model = AppModel(defaults: defaults)
        model.snapshot = try ReadingSnapshot(status: "221.8 49.8 221.8 49.8 0798 0764 019 403 27.00 000 100 0036 02.0 287.7 00.00 00000 00010110 00 00 00471 111 0 01 0000", mode: "L", warnings: "0")
        let host = UIHostingController(rootView: Dashboard(model: model).environment(\.scenePhase, .active))
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { findRenderer(in: host.view)?.sceneController?.stop(); window.isHidden = true; window.rootViewController = nil }
        try await Task.sleep(for: .milliseconds(400))
        host.view.layoutIfNeeded()
        let renderer = try #require(findRenderer(in: host.view))
        #expect(!renderer.isHidden)
        #expect(renderer.bounds.height > 0)
        #expect(renderer.scene.anchors.first?.isEnabled == true)
        #expect(renderer.sceneController?.isAnimating == true)

        host.rootView = Dashboard(model: model).environment(\.scenePhase, .inactive)
        try await Task.sleep(for: .milliseconds(200))
        #expect(!renderer.isHidden, "An inactive scene should keep the house visible while pausing live animation")
        #expect(renderer.scene.anchors.first?.isEnabled == true)
        #expect(renderer.sceneController?.isAnimating == false)

        host.rootView = Dashboard(model: model).environment(\.scenePhase, .active)
        try await Task.sleep(for: .milliseconds(200))
        #expect(findRenderer(in: host.view) === renderer)
        #expect(!renderer.isHidden)
        #expect(renderer.scene.anchors.first?.isEnabled == true)
        #expect(renderer.sceneController?.isAnimating == true)
    }

    private func findRenderer(in view: UIView) -> SolarRenderView? {
        if let renderer = view as? SolarRenderView { return renderer }
        return view.subviews.lazy.compactMap { findRenderer(in: $0) }.first
    }
}
