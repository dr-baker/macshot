import AppKit
import XCTest

@MainActor
final class StitchPaperCameraTests: XCTestCase {
    func testNativeDragChangesEachAngleWithPrecisionAndAxisLock() {
        let camera = StitchPaperCamera(perspective: 0, yaw: 0)
        let moved = camera.dragged(by: CGPoint(x: 80, y: -40))
        XCTAssertEqual(moved.yaw, 12)
        XCTAssertEqual(moved.perspective, -6)
        let precise = camera.dragged(by: CGPoint(x: 80, y: -40), precision: true)
        XCTAssertEqual(precise.yaw, 3)
        XCTAssertEqual(precise.perspective, -1.5)
        let horizontal = camera.dragged(by: CGPoint(x: -80, y: 40), axisLock: true)
        XCTAssertEqual(horizontal.yaw, -12)
        XCTAssertEqual(horizontal.perspective, 0)
        let vertical = camera.dragged(by: CGPoint(x: 40, y: 80), axisLock: true)
        XCTAssertEqual(vertical.yaw, 0)
        XCTAssertEqual(vertical.perspective, 12)
        let tie = camera.dragged(by: CGPoint(x: 40, y: 40), axisLock: true)
        XCTAssertEqual(tie.yaw, 6)
        XCTAssertEqual(tie.perspective, 0)
    }

    func testCameraClampsLargeDragsAndIgnoresNonfiniteDisplacement() {
        let camera = StitchPaperCamera()
        XCTAssertEqual(camera.perspective, 14)
        XCTAssertEqual(camera.yaw, 11.2)
        XCTAssertEqual(camera.dragged(by: CGPoint(x: 10_000, y: -10_000)),
                       StitchPaperCamera(perspective: -30, yaw: 35))
        XCTAssertEqual(camera.dragged(by: CGPoint(x: -10_000, y: 10_000)),
                       StitchPaperCamera(perspective: 30, yaw: -35))
        XCTAssertEqual(camera.dragged(by: CGPoint(x: CGFloat.nan, y: 20)), camera)
        XCTAssertEqual(camera.dragged(by: CGPoint(x: 20, y: CGFloat.infinity)), camera)
        XCTAssertEqual(StitchPaperCamera(perspective: .nan, yaw: .infinity), camera)
        XCTAssertEqual(StitchPaperCamera(perspective: -90, yaw: 90),
                       StitchPaperCamera(perspective: -30, yaw: 35))
    }

    func testIndependentSignedAnglesMoveCameraDepthInTheExpectedAxes() throws {
        var document = try fixture()
        document.style.accordionPerspective = 0
        for yaw in [CGFloat(-24), 24] {
            document.style.accordionYaw = yaw
            let plan = try XCTUnwrap(StitchAccordionProjection(document: document))
            let topLeft = try vertex(at: CGPoint(x: 0, y: 0), in: plan)
            let topRight = try vertex(at: CGPoint(x: document.bounds.maxX, y: 0), in: plan)
            let bottomLeft = try vertex(at: CGPoint(x: 0, y: document.bounds.maxY), in: plan)
            XCTAssertEqual(topLeft.depth, bottomLeft.depth, accuracy: 0.000001)
            XCTAssertEqual(topRight.depth - topLeft.depth,
                           document.bounds.width * sin(yaw * .pi / 180), accuracy: 0.000001)
        }
        document.style.accordionYaw = 0
        for perspective in [CGFloat(-24), 24] {
            document.style.accordionPerspective = perspective
            let plan = try XCTUnwrap(StitchAccordionProjection(document: document))
            let topLeft = try vertex(at: CGPoint(x: 0, y: 0), in: plan)
            let topRight = try vertex(at: CGPoint(x: document.bounds.maxX, y: 0), in: plan)
            let bottomLeft = try vertex(at: CGPoint(x: 0, y: document.bounds.maxY), in: plan)
            XCTAssertEqual(topLeft.depth, topRight.depth, accuracy: 0.000001)
            // The omitted 99px strip folds to 44.55px beside unchanged content.
            let foldedHeight = document.bounds.height + 44.55
            XCTAssertEqual(bottomLeft.depth - topLeft.depth,
                           foldedHeight * sin(perspective * .pi / 180), accuracy: 0.000001)
        }
    }

    func testDefaultCameraKeepsAboveLeftViewAndActualPaperDepth() throws {
        let document = try fixture()
        for progress: CGFloat in [0.45, 1] {
            let plan = try XCTUnwrap(StitchAccordionProjection(document: document, progress: progress))
            let topLeft = try vertex(at: .zero, in: plan)
            let topRight = try vertex(at: CGPoint(x: document.bounds.maxX, y: 0), in: plan)
            let bottomLeft = try vertex(at: CGPoint(x: 0, y: document.bounds.maxY), in: plan)
            let pitch = 14 * progress * .pi / 180, yaw = 11.2 * progress * .pi / 180
            let actualHeight = document.bounds.height + 99 * cos(acos(CGFloat(0.45)) * progress)
            XCTAssertEqual(topRight.depth - topLeft.depth,
                document.bounds.width * sin(yaw) * cos(pitch), accuracy: 0.000001)
            XCTAssertEqual(bottomLeft.depth - topLeft.depth,
                actualHeight * sin(pitch), accuracy: 0.000001)
            XCTAssertLessThan(topLeft.depth, topRight.depth)
            XCTAssertLessThan(topLeft.depth, bottomLeft.depth)
            XCTAssertEqual(plan.source.camera, StitchPaperCamera())
            XCTAssertTrue(plan.outputBounds.contains(plan.paperPath.boundingBoxOfPath))
        }
    }

    func testSourceBuildsIdenticalPlansOffMainAndFreezesBothAngles() async throws {
        var document = try fixture()
        document.style.accordionPerspective = -19
        document.style.accordionYaw = 27
        let source = try XCTUnwrap(StitchAccordionProjection.Source(document: document))
        let expected = try XCTUnwrap(StitchAccordionProjection(document: document, progress: 0.45))
        document.style.accordionPerspective = 30
        document.style.accordionYaw = -35
        document.style.accordionWidth = 80
        let result = await Task.detached { source.projection(progress: 0.45) }.value
        let actual = try XCTUnwrap(result)
        XCTAssertEqual(source.camera.perspective, -19)
        XCTAssertEqual(source.camera.yaw, 27)
        XCTAssertEqual(actual.documentBounds, expected.documentBounds)
        XCTAssertEqual(actual.outputBounds, expected.outputBounds)
        XCTAssertEqual(actual.drawingOrder, expected.drawingOrder)
        XCTAssertEqual(actual.faces.count, expected.faces.count)
        for (a, b) in zip(actual.faces, expected.faces) {
            XCTAssertEqual(a.shade, b.shade)
            XCTAssertEqual(a.isFrontFacing, b.isFrontFacing)
            XCTAssertEqual(a.boundaryEdges, b.boundaryEdges)
            for (av, bv) in zip(a.vertices, b.vertices) {
                XCTAssertEqual(av.source, bv.source)
                XCTAssertEqual(av.rest, bv.rest)
                XCTAssertEqual(av.world, bv.world)
                XCTAssertEqual(av.projected, bv.projected)
                XCTAssertEqual(av.depth, bv.depth)
            }
        }
    }

    func testSignedCameraAnimationKeepsSharedMeshFlatAtStartAndBoundedAtFinish() throws {
        for angles in [StitchPaperCamera(perspective: -30, yaw: -35),
                       StitchPaperCamera(perspective: 30, yaw: 35),
                       StitchPaperCamera(perspective: -30, yaw: 35),
                       StitchPaperCamera(perspective: 30, yaw: -35)] {
            var document = try fixture()
            document.style.accordionPerspective = angles.perspective
            document.style.accordionYaw = angles.yaw
            let source = try XCTUnwrap(StitchAccordionProjection.Source(document: document))
            let first = try XCTUnwrap(source.projection(progress: 0))
            let final = try XCTUnwrap(source.projection())
            XCTAssertTrue(first.hasProjectedOutput, "The opening frame includes the actual removed paper")
            XCTAssertTrue(final.hasProjectedOutput)
            XCTAssertEqual(first.faces.count, final.faces.count)
            XCTAssertTrue(final.outputBounds.contains(final.paperPath.boundingBoxOfPath))
            for face in first.faces {
                for vertex in face.vertices {
                    XCTAssertEqual(vertex.world.x, vertex.rest.x, accuracy: 0.000001)
                    XCTAssertEqual(vertex.world.y, vertex.rest.y, accuracy: 0.000001)
                    XCTAssertEqual(vertex.world.z, 0, accuracy: 0.000001)
                }
            }
            for face in final.faces where face.isFrontFacing && face.paperSample == nil {
                let center = CGPoint(x: (face.a.source.x + face.b.source.x + face.c.source.x) / 3,
                                     y: (face.a.source.y + face.b.source.y + face.c.source.y) / 3)
                let point = try XCTUnwrap(face.project(center))
                let restored = try XCTUnwrap(face.unproject(point))
                XCTAssertEqual(restored.source.x, center.x, accuracy: 0.000001)
                XCTAssertEqual(restored.source.y, center.y, accuracy: 0.000001)
            }
        }
    }

    func testSavedDocumentPersistsSignedAnglesAndYawChangesIdentity() throws {
        let original = try fixture()
        var edited = original
        edited.style.accordionPerspective = -23
        edited.style.accordionYaw = -31
        let saved = try XCTUnwrap(SavedStitchDocument(edited))
        let data = try JSONEncoder().encode(saved)
        let decoded = try JSONDecoder().decode(SavedStitchDocument.self, from: data)
        let restored = try XCTUnwrap(decoded.restore())
        XCTAssertEqual(restored.style.accordionPerspective, -23)
        XCTAssertEqual(restored.style.accordionYaw, -31)
        XCTAssertFalse(original.isIdentical(to: edited))
        var onlyYaw = original
        onlyYaw.style.accordionYaw += 1
        XCTAssertFalse(original.isIdentical(to: onlyYaw))
        XCTAssertTrue(original.isIdentical(to: original))
    }

    func testDocumentsWithoutYawRestoreTheirOriginalCameraAndRejectOutOfRangeAngles() throws {
        let saved = try XCTUnwrap(SavedStitchDocument(fixture()))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(saved)) as? [String: Any])
        for perspective in [14.0, 22.0] {
            var previous = json
            previous["accordionPerspective"] = perspective
            previous.removeValue(forKey: "accordionYaw")
            let previousSaved = try JSONDecoder().decode(SavedStitchDocument.self,
                from: JSONSerialization.data(withJSONObject: previous))
            let restored = try XCTUnwrap(previousSaved.restore())
            XCTAssertEqual(restored.style.accordionPerspective, perspective)
            XCTAssertEqual(restored.style.accordionYaw, perspective * 0.8, accuracy: 0.000001)
        }
        for (key, value) in [("accordionPerspective", -31.0), ("accordionPerspective", 31.0),
                             ("accordionYaw", -36.0), ("accordionYaw", 36.0)] {
            var invalid = json
            invalid[key] = value
            let invalidSaved = try JSONDecoder().decode(SavedStitchDocument.self,
                from: JSONSerialization.data(withJSONObject: invalid))
            XCTAssertNil(invalidSaved.restore())
        }
    }

    func testActiveProjectionRejectsMalformedCameraWithoutClampingStoredState() throws {
        var document = try fixture()
        for invalid in [CGFloat.nan, .infinity, -36, 36] {
            document.style.accordionYaw = invalid
            XCTAssertNil(StitchAccordionProjection.Source(document: document))
        }
        document.style.accordionYaw = 11.2
        for invalid in [CGFloat.nan, .infinity, -31, 31] {
            document.style.accordionPerspective = invalid
            XCTAssertNil(StitchAccordionProjection.Source(document: document))
        }
        document.style.accordionPerspective = 14
        let source = try XCTUnwrap(StitchAccordionProjection.Source(document: document))
        XCTAssertNil(source.projection(progress: .nan))
        XCTAssertNil(source.projection(progress: .infinity))
    }

    private func fixture() throws -> StitchDocument {
        // Compact texture is 240×220; the complete rest sheet remains 240×319.
        let image = try XCTUnwrap(ImageProbe.makeImage(width: 240, height: 319) { context in
            context.setFillColor(NSColor.white.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: 240, height: 319))
        }.cgImage(forProposedRect: nil, context: nil, hints: nil))
        var document = StitchDocument(pieces: [StitchPiece(image: image)])
        document.style.transition = .accordion
        XCTAssertTrue(document.collapse(axis: .horizontal, from: 110, to: 209))
        return document
    }

    private func vertex(at point: CGPoint, in projection: StitchAccordionProjection) throws -> StitchAccordionProjection.Vertex {
        try XCTUnwrap(projection.faces.flatMap(\.vertices).first { $0.source == point })
    }
}
