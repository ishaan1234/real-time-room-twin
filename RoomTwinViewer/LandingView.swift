import SwiftUI

/// The overlay's content: nothing while waiting; when a model arrives the
/// screen greys out and the model flies up from the bottom edge, lands and
/// spins. Drag it to turn it and scroll or pinch to zoom. A preloaded model
/// waits loaded just below the bottom edge, and the same view flies up when
/// it's shown, so nothing has to load then.
struct LandingView: View {
    @ObservedObject var viewer: Viewer

    var body: some View {
        ZStack {
            Color.black
                .opacity(viewer.arrival == nil ? 0 : 0.45)
                .contentShape(Rectangle())
                .onTapGesture(perform: viewer.dismiss)
            ForEach(viewer.models) { model in
                LandingModel(arrival: model, isShown: model.id == viewer.arrival?.id, shakes: viewer.shakes) {
                    viewer.stagedIsReady(model.id)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.4), value: viewer.arrival)
        .ignoresSafeArea()
    }
}

private struct LandingModel: View {
    let arrival: Viewer.Arrival
    /// False while it's staged, out of sight below the screen.
    let isShown: Bool
    let shakes: Int
    let onReady: () -> Void
    @State private var landed = false

    var body: some View {
        GeometryReader { geometry in
            let side = min(geometry.size.width, geometry.size.height) * 0.7
            let spot = CGPoint(x: geometry.size.width / 2, y: geometry.size.height * 0.46)
            ZStack {
                // Its shadow on the "ground", there once it has landed.
                Ellipse()
                    .fill(.black.opacity(0.45))
                    .frame(width: side * 0.45, height: side * 0.07)
                    .blur(radius: 18)
                    .position(x: spot.x, y: spot.y + side * 0.36)
                    .opacity(landed ? 1 : 0)
                    .scaleEffect(landed ? 1 : 0.3)
                    .allowsHitTesting(false)
                SpinningModel(url: arrival.model, isPlaying: isShown, onReady: onReady)
                    .frame(width: side, height: side)
                    .scaleEffect(landed ? 1 : 0.55)
                    .modifier(Shake(animatableData: CGFloat(shakes)))
                    .position(x: spot.x, y: landed ? spot.y : geometry.size.height + side / 2)
                VStack(spacing: 6) {
                    Spacer()
                    Text(arrival.model.deletingPathExtension().lastPathComponent)
                        .font(.title2.weight(.semibold))
                    Text("from \(arrival.from) · drag to turn, scroll to zoom · click outside it or press Esc to close")
                        .foregroundStyle(.white.opacity(0.7))
                }
                .foregroundStyle(.white)
                .padding(.bottom, 70)
                .frame(maxWidth: .infinity)
                .opacity(landed ? 1 : 0)
                .allowsHitTesting(false)
            }
        }
        .onAppear { if isShown { land() } }
        .onChange(of: isShown) { _, shown in if shown { land() } }
    }

    private func land() {
        withAnimation(.spring(response: 0.8, dampingFraction: 0.6)) { landed = true }
    }
}

/// Three quick side-to-side shakes for each whole step of `animatableData`.
private struct Shake: GeometryEffect {
    var animatableData: CGFloat

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: 24 * sin(animatableData * .pi * 6), y: 0))
    }
}
