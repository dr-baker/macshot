import AppKit

/// A redaction fragment follows one capture, with clipping in canvas points.
/// Piece and lineage IDs survive history reloads and further source slicing.
struct StitchAnnotationAttachment: Codable, Equatable {
    var pieceID: UUID?
    var lineageID: UUID?
    var clipRect: CGRect

    var isValid: Bool {
        let r = clipRect
        return !r.isNull && r.width > 0 && r.height > 0
            && (pieceID == nil) == (lineageID == nil)
            && [r.minX, r.minY, r.maxX, r.maxY].allSatisfy {
                $0.isFinite && abs($0) <= SavedCaptureValidation.maximumCoordinate
            }
    }
}
