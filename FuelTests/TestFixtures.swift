import UIKit

func testMealImageData(color: UIColor = .systemGreen) -> Data {
    let size = CGSize(width: 8, height: 8)
    let image = UIGraphicsImageRenderer(size: size).image { context in
        color.setFill()
        context.fill(CGRect(origin: .zero, size: size))
    }
    return image.jpegData(compressionQuality: 0.8)!
}
