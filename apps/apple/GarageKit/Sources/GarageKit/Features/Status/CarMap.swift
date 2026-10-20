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

    @State private var position: MapCameraPosition = .automatic
    @State private var distance = CarMap.cameraDistance

    var body: some View {
        if mapEnabled, let coordinate = model.coordinate {
            map(centredOn: coordinate)
        } else {
            Rectangle().fill(Tokens.Colors.mapGround)
        }
    }

    private func map(centredOn coordinate: StatusModel.Coordinate) -> some View {
        let centre = CLLocationCoordinate2D(latitude: coordinate.latitude, longitude: coordinate.longitude)
        return Map(position: $position, interactionModes: Self.interactionModes) {
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
        .onAppear { position = .camera(MapCamera(centerCoordinate: centre, distance: distance)) }
        .onChange(of: coordinate) {
            withAnimation(.smooth) { position = .camera(MapCamera(centerCoordinate: centre, distance: distance)) }
        }
        .onMapCameraChange(frequency: .onEnd) { distance = $0.camera.distance }
    }

    /// iPhone: pinch to zoom only, so the screen scrolls rather than the map. Mac: pan and zoom.
    private static var interactionModes: MapInteractionModes {
        #if os(iOS)
        .zoom
        #else
        [.pan, .zoom]
        #endif
    }

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
