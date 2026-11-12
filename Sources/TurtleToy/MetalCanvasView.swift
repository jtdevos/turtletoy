import SwiftUI
import MetalKit
import AppKit
import simd

public final class InteractiveMTKView: MTKView {
    public weak var viewModel: IDEViewModel?
    private var lastDragPoint: NSPoint?

    public override var acceptsFirstResponder: Bool { true }

    public override func scrollWheel(with event: NSEvent) {
        guard let vm = viewModel else { return }
        if event.modifierFlags.contains(.option) || event.modifierFlags.contains(.command) {
            let zoomFactor = Float(1.0 - event.scrollingDeltaY * 0.015)
            vm.cameraZoom = min(max(vm.cameraZoom * zoomFactor, 0.15), 14.0)
        } else {
            let scale = 1.0 / max(vm.cameraZoom, 0.1)
            vm.cameraPan.x += Float(event.scrollingDeltaX) * scale
            vm.cameraPan.y -= Float(event.scrollingDeltaY) * scale
        }
    }

    public override func magnify(with event: NSEvent) {
        guard let vm = viewModel else { return }
        let factor = Float(1.0 + event.magnification)
        vm.cameraZoom = min(max(vm.cameraZoom * factor, 0.15), 14.0)
    }

    public override func mouseDown(with event: NSEvent) {
        lastDragPoint = convert(event.locationInWindow, from: nil)
        if event.clickCount == 2 {
            // Double-click emits a whimsical ripple & stardust burst at click position!
            if let pt = lastDragPoint, let vm = viewModel {
                let world = viewPointToWorld(pt, vm: vm)
                vm.renderer?.triggerRipple(at: world, maxRadius: 200.0)
                vm.renderer?.triggerBurst(
                    at: world,
                    color: SIMD4<Float>(0.25, 0.95, 1.0, 1.0),
                    count: 34,
                    size: 9.5,
                    speed: 115.0,
                    kind: 1
                )
            }
        }
    }

    public override func mouseDragged(with event: NSEvent) {
        guard let vm = viewModel else { return }
        let pt = convert(event.locationInWindow, from: nil)
        if let prev = lastDragPoint {
            let dx = Float(pt.x - prev.x)
            let dy = Float(pt.y - prev.y)
            let scale = 1.0 / max(vm.cameraZoom, 0.1)
            vm.cameraPan.x += dx * scale
            vm.cameraPan.y += dy * scale
        }
        lastDragPoint = pt
    }

    public override func rightMouseDown(with event: NSEvent) {
        guard let vm = viewModel else { return }
        let pt = convert(event.locationInWindow, from: nil)
        let world = viewPointToWorld(pt, vm: vm)
        vm.renderer?.triggerRipple(at: world, maxRadius: 220.0)
        vm.renderer?.triggerBurst(
            at: world,
            color: SIMD4<Float>(1.0, 0.45, 0.85, 1.0),
            count: 42,
            size: 10.0,
            speed: 135.0,
            kind: 1
        )
    }

    private func viewPointToWorld(_ pt: NSPoint, vm: IDEViewModel) -> SIMD2<Float> {
        let w = Float(bounds.width)
        let h = Float(bounds.height)
        let centered = SIMD2<Float>(Float(pt.x) - w * 0.5, Float(pt.y) - h * 0.5)
        return (centered / max(vm.cameraZoom, 0.001)) - vm.cameraPan
    }
}

public struct MetalCanvasView: NSViewRepresentable {
    @ObservedObject public var viewModel: IDEViewModel

    public init(viewModel: IDEViewModel) {
        self.viewModel = viewModel
    }

    public func makeNSView(context: Context) -> InteractiveMTKView {
        let mtkView = InteractiveMTKView(frame: .zero, device: viewModel.renderer?.device)
        mtkView.viewModel = viewModel
        mtkView.framebufferOnly = false
        viewModel.renderer?.configure(mtkView: mtkView)
        return mtkView
    }

    public func updateNSView(_ nsView: InteractiveMTKView, context: Context) {
        nsView.viewModel = viewModel
    }
}
