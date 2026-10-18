import AppKit
import MapKit
import SwiftUI

/// The map of located photos: one pin per ~10 km cell, which MapKit clusters as the map zooms out. Clicking a pin or a
/// cluster selects its cells. SwiftUI's `Map` has no clustering on macOS 14, so this wraps `MKMapView`.
struct BrowseMapView: NSViewRepresentable {
    let cells: [BrowseCell]
    /// The place name shown for a cell, or its coordinates.
    let title: (String) -> String
    @Binding var selection: Set<String>
    /// Changes when the map should fit the located photos again.
    let fitGeneration: Int
    /// The cells on screen, after the map moves, so their names can be looked up.
    let onVisibleCells: (Set<String>) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.showsZoomControls = true
        map.setAccessibilityLabel("Map of backup photos by place")
        return map
    }

    func updateNSView(_ map: MKMapView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        coordinator.sync(cells: cells, on: map)
        if coordinator.fittedGeneration != fitGeneration, !cells.isEmpty {
            coordinator.fit(cells: cells, on: map)
            coordinator.fittedGeneration = fitGeneration
        }
        if selection.isEmpty, !map.selectedAnnotations.isEmpty {
            for annotation in map.selectedAnnotations {
                map.deselectAnnotation(annotation, animated: false)
            }
        }
    }

    /// One pin for one cell. Its count is the photos in the cell.
    final class CellAnnotation: NSObject, MKAnnotation {
        let key: String
        let count: Int
        let coordinate: CLLocationCoordinate2D
        var title: String?

        init(cell: BrowseCell, title: String?) {
            key = cell.key
            count = cell.count
            coordinate = CLLocationCoordinate2D(latitude: cell.latitude, longitude: cell.longitude)
            self.title = title
        }
    }

    /// The count on a pin or cluster: a filled circle in the accent colour with the photo count in white. It's drawn as an
    /// image, not as a marker, so it reads the same in every render; the pin is data, not a control.
    enum Badge {
        static func image(count: Int) -> NSImage {
            let text = count.formatted() as NSString
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.preferredFont(forTextStyle: .callout),
                .foregroundColor: NSColor.white,
            ]
            let textSize = text.size(withAttributes: attributes)
            let diameter = max(28, ceil(textSize.width) + 14)
            return NSImage(size: NSSize(width: diameter, height: diameter), flipped: false) { rect in
                let circle = rect.insetBy(dx: 2, dy: 2)
                NSColor.controlAccentColor.setFill()
                NSBezierPath(ovalIn: circle).fill()
                NSColor.white.setStroke()
                let ring = NSBezierPath(ovalIn: circle)
                ring.lineWidth = 2
                ring.stroke()
                text.draw(at: NSPoint(x: rect.midX - textSize.width / 2, y: rect.midY - textSize.height / 2), withAttributes: attributes)
                return true
            }
        }
    }

    @MainActor
    final class Coordinator: NSObject, MKMapViewDelegate {
        var parent: BrowseMapView
        var fittedGeneration: Int?
        private var annotations: [String: CellAnnotation] = [:]
        private static let cellReuse = "cell"
        private static let clusterReuse = "cluster"

        init(parent: BrowseMapView) {
            self.parent = parent
        }

        /// Adds, removes and retitles the pins so they match the cells, changing only what differs.
        func sync(cells: [BrowseCell], on map: MKMapView) {
            let wanted = Dictionary(cells.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
            for (key, annotation) in annotations where wanted[key]?.count != annotation.count {
                map.removeAnnotation(annotation)
                annotations[key] = nil
            }
            for cell in cells {
                if let annotation = annotations[cell.key] {
                    annotation.title = parent.title(cell.key)
                } else {
                    let annotation = CellAnnotation(cell: cell, title: parent.title(cell.key))
                    annotations[cell.key] = annotation
                    map.addAnnotation(annotation)
                }
            }
        }

        /// Fits the map to every located cell, with room around the edges.
        func fit(cells: [BrowseCell], on map: MKMapView) {
            var rect = MKMapRect.null
            for cell in cells {
                let point = MKMapPoint(CLLocationCoordinate2D(latitude: cell.latitude, longitude: cell.longitude))
                rect = rect.union(MKMapRect(x: point.x, y: point.y, width: 0, height: 0))
            }
            map.setVisibleMapRect(rect, edgePadding: NSEdgeInsets(top: 40, left: 40, bottom: 40, right: 40), animated: false)
            if map.visibleMapRect.size.width < 1 || map.visibleMapRect.size.height < 1 {
                // A single cell has no area to fit: zoom to a city-sized region instead.
                if let cell = cells.first {
                    map.setRegion(MKCoordinateRegion(
                        center: CLLocationCoordinate2D(latitude: cell.latitude, longitude: cell.longitude),
                        span: MKCoordinateSpan(latitudeDelta: 0.5, longitudeDelta: 0.5)
                    ), animated: false)
                }
            }
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: any MKAnnotation) -> MKAnnotationView? {
            if let cluster = annotation as? MKClusterAnnotation {
                // The badge counts photos, not pins.
                let photos = cluster.memberAnnotations.compactMap { ($0 as? CellAnnotation)?.count }.reduce(0, +)
                let view = mapView.dequeueReusableAnnotationView(withIdentifier: Self.clusterReuse)
                    ?? MKAnnotationView(annotation: cluster, reuseIdentifier: Self.clusterReuse)
                view.annotation = cluster
                view.image = Badge.image(count: photos)
                view.displayPriority = .required
                view.setAccessibilityLabel("\(photos) photos in \(cluster.memberAnnotations.count) places")
                return view
            }
            guard let cell = annotation as? CellAnnotation else { return nil }
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: Self.cellReuse)
                ?? MKAnnotationView(annotation: cell, reuseIdentifier: Self.cellReuse)
            view.annotation = cell
            view.clusteringIdentifier = "places"
            view.image = Badge.image(count: cell.count)
            view.canShowCallout = true
            view.displayPriority = .defaultHigh
            view.setAccessibilityLabel("\(cell.title ?? "Place"), \(cell.count) photos")
            return view
        }

        func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
            let keys: [String]
            if let cluster = view.annotation as? MKClusterAnnotation {
                keys = cluster.memberAnnotations.compactMap { ($0 as? CellAnnotation)?.key }
            } else if let cell = view.annotation as? CellAnnotation {
                keys = [cell.key]
            } else {
                return
            }
            parent.selection = Set(keys)
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            let visible = mapView.visibleMapRect
            let keys = mapView.annotations.compactMap { annotation -> String? in
                guard let cell = annotation as? CellAnnotation else { return nil }
                return visible.contains(MKMapPoint(cell.coordinate)) ? cell.key : nil
            }
            parent.onVisibleCells(Set(keys))
        }
    }
}
