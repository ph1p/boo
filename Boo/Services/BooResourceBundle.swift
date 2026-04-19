import Foundation

enum BooResourceBundle {
    static let bundle: Bundle = {
        if let appResources = Bundle.main.resourceURL {
            let packagedURL = appResources.appendingPathComponent("Boo_Boo.bundle", isDirectory: true)
            if let bundle = Bundle(url: packagedURL) {
                return bundle
            }
        }

        return Bundle.module
    }()
}
