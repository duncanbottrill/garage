import MapKit
import SwiftUI

/// The map hero: MapKit's flat, muted, dark standard map with no points of interest or controls,
/// a translucent ground wash so roads sit in the road tones, the 30-minute trail and the car.
///
/// With `mapEnabled` false it draws a flat `mapGround` rectangle instead (snapshots), and the layout
/// places the car itself.
struct CarMap: View {
    let model: StatusModel
    let trail: [TrailPoint]
    let mapEnabled: Bool
    /// The part of the map covered by the sheet, so the car is centred in what stays visible.
    let obscured: EdgeInsets

    /// How strongly the ground wash covers the base map; roads and labels still show through it.
    static let washOpacity: Double = 0.55
    /// Half the size of the washed square around the car, in degrees.
    static let washSpan: Double = 1.5
    /// How close the camera starts, in metres.
    static let cameraDistance: CLLocationDistance = 1400
    /// How far the car must move before the camera follows it, in metres. Smaller moves (GPS jitter, a
    /// car creeping in a car park) leave the camera where the owner put it.
    static let recentreDistance: CLLocationDistance = 50
    /// The farthest the camera may zoom out, in metres, so the view stays inside the washed square.
    static let maximumCameraDistance: CLLocationDistance = 50_000

    @State private var position: MapCameraPosition = .automatic
    @State private var distance = CarMap.cameraDistance
    /// Where the camera was last centred on the car; nil before the first fix.
    @State private var centred: StatusModel.Coordinate?

    /// Whether the camera should move to `next`: on the first fix, or once the car is more than
    /// ``recentreDistance`` from where the camera last centred it.
    static func shouldRecentre(from last: StatusModel.Coordinate?, to next: StatusModel.Coordinate) -> Bool {
        guard let last else { return true }
        let moved = CLLocation(latitude: last.latitude, longitude: last.longitude)
            .distance(from: CLLocation(latitude: next.latitude, longitude: next.longitude))
        return moved > recentreDistance
    }

    var body: some View {
        if mapEnabled, let coordinate = model.coordinate {
            map(centredOn: coordinate)
        } else {
            Rectangle().fill(Tokens.Colors.mapGround)
        }
    }

    private func map(centredOn coordinate: StatusModel.Coordinate) -> some View {
        let centre = CLLocationCoordinate2D(latitude: coordinate.latitude, longitude: coordinate.longitude)
        return Map(position: $position, bounds: MapCameraBounds(maximumDistance: Self.maximumCameraDistance), interactionModes: Self.interactionModes) {
            MapPolygon(coordinates: Self.wash(around: centre))
                .foregroundStyle(Tokens.Colors.mapGround.opacity(Self.washOpacity))
                .mapOverlayLevel(level: .aboveRoads)
            if trail.count > 1 {
                MapPolyline(coordinates: trail.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) })
                    .stroke(Tokens.Colors.accent.opacity(Tokens.Opacity.accentStroke), lineWidth: 3)
            }
            Annotation("", coordinate: centre, anchor: .center) {
                CarAnnotation(online: model.bridgeOnline, heading: model.heading, moving: model.isMoving)
            }
            .annotationTitles(.hidden)
        }
        .mapStyle(.standard(elevation: .flat, emphasis: .muted, pointsOfInterest: .excludingAll))
        .mapControls {}
        .environment(\.colorScheme, .dark)
        .safeAreaPadding(obscured)
        .onAppear {
            centred = coordinate
            position = .camera(MapCamera(centerCoordinate: centre, distance: distance))
        }
        .onChange(of: coordinate) {
            guard Self.shouldRecentre(from: centred, to: coordinate) else { return }
            centred = coordinate
            withAnimation(.smooth) { position = .camera(MapCamera(centerCoordinate: centre, distance: distance)) }
        }
        .onMapCameraChange(frequency: .onEnd) { distance = $0.camera.distance }
    }

    /// Pan and zoom on both platforms; nothing scrolls under the map, so a drag belongs to it. The
    /// camera stays where the owner put it until the car moves more than ``recentreDistance``.
    private static let interactionModes: MapInteractionModes = [.pan, .zoom]

    private static func wash(around centre: CLLocationCoordinate2D) -> [CLLocationCoordinate2D] {
        let lat = centre.latitude, lng = centre.longitude, span = washSpan
        return [
            .init(latitude: min(85, lat + span), longitude: lng - span),
            .init(latitude: min(85, lat + span), longitude: lng + span),
            .init(latitude: max(-85, lat - span), longitude: lng + span),
            .init(latitude: max(-85, lat - span), longitude: lng - span),
        ]
    }
}
