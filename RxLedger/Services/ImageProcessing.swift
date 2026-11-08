import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit

/// Image preprocessing for OCR and storage.
enum ImageProcessing {
    private static let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    /// Redraws the image so its pixel data is upright (applies the EXIF orientation).
    static func normalizedOrientation(_ image: UIImage) -> UIImage {
        guard image.imageOrientation != .up else { return image }
        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        format.opaque = true
        return UIGraphicsImageRenderer(size: image.size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
    }

    /// Grayscale with a slight contrast boost — helps Vision on the shaded patient band.
    static func grayscale(_ cgImage: CGImage) -> CGImage {
        let filter = CIFilter.colorControls()
        filter.inputImage = CIImage(cgImage: cgImage)
        filter.saturation = 0
        filter.contrast = 1.15
        guard let output = filter.outputImage,
              let result = ciContext.createCGImage(output, from: output.extent) else { return cgImage }
        return result
    }

    /// Rotates clockwise by a multiple of 90°.
    static func rotate(_ cgImage: CGImage, degrees: Int) -> CGImage {
        let turns = ((degrees / 90) % 4 + 4) % 4
        guard turns != 0 else { return cgImage }
        let orientation: CGImagePropertyOrientation = [.up, .right, .down, .left][turns]
        let ci = CIImage(cgImage: cgImage).oriented(orientation)
        return ciContext.createCGImage(ci, from: ci.extent) ?? cgImage
    }

    /// Downscales so the long edge is ≤ `maxDimension` and encodes as JPEG.
    static func jpegForStorage(_ cgImage: CGImage, maxDimension: CGFloat = 1600, quality: CGFloat = 0.75) -> Data? {
        let w = CGFloat(cgImage.width), h = CGFloat(cgImage.height)
        let scale = min(1, maxDimension / max(w, h))
        let target = CGSize(width: (w * scale).rounded(), height: (h * scale).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let resized = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            UIImage(cgImage: cgImage).draw(in: CGRect(origin: .zero, size: target))
        }
        return resized.jpegData(compressionQuality: quality)
    }

    /// Crops a normalized Vision rect (origin bottom-left) out of the image, with a little padding.
    static func crop(_ cgImage: CGImage, normalizedRect: CGRect, padding: CGFloat = 0.006) -> UIImage? {
        let w = CGFloat(cgImage.width), h = CGFloat(cgImage.height)
        let r = normalizedRect.insetBy(dx: -padding, dy: -padding)
            .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !r.isNull, r.width > 0, r.height > 0 else { return nil }
        let pixelRect = CGRect(x: r.minX * w, y: (1 - r.maxY) * h, width: r.width * w, height: r.height * h).integral
        guard let cropped = cgImage.cropping(to: pixelRect) else { return nil }
        return UIImage(cgImage: cropped)
    }
}
