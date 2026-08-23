import AVFoundation
import SwiftUI
import UIKit

struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession
    var regionFraction: Double

    func makeUIView(context: Context) -> PreviewHostView {
        let view = PreviewHostView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        view.regionFraction = regionFraction
        return view
    }

    func updateUIView(_ uiView: PreviewHostView, context: Context) {
        uiView.previewLayer.session = session
        uiView.regionFraction = regionFraction
        uiView.setNeedsLayout()
    }
}

final class PreviewHostView: UIView {
    let previewLayer = AVCaptureVideoPreviewLayer()
    var regionFraction: Double = 0.35 {
        didSet { overlay.setNeedsDisplay() }
    }
    private let overlay = TargetOverlayView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        previewLayer.frame = bounds
        layer.addSublayer(previewLayer)
        overlay.backgroundColor = .clear
        overlay.isUserInteractionEnabled = false
        addSubview(overlay)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        previewLayer.frame = bounds
        overlay.frame = bounds
        overlay.regionFraction = regionFraction
    }
}

final class TargetOverlayView: UIView {
    var regionFraction: Double = 0.35 {
        didSet { setNeedsDisplay() }
    }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        let frac = CGFloat(min(0.9, max(0.08, regionFraction)))
        let w = rect.width * frac
        let h = rect.height * frac
        let r = CGRect(x: (rect.width - w) / 2, y: (rect.height - h) / 2, width: w, height: h)
        ctx.setStrokeColor(UIColor(red: 0.25, green: 0.85, blue: 0.40, alpha: 0.95).cgColor)
        ctx.setLineWidth(2)
        ctx.stroke(r)
        let cross = 10.0
        ctx.move(to: CGPoint(x: r.midX - cross, y: r.midY))
        ctx.addLine(to: CGPoint(x: r.midX + cross, y: r.midY))
        ctx.move(to: CGPoint(x: r.midX, y: r.midY - cross))
        ctx.addLine(to: CGPoint(x: r.midX, y: r.midY + cross))
        ctx.strokePath()
    }
}
