/// State of a single macOS permission.
enum PermissionState: Equatable {
    case granted
    case denied
    case notDetermined

    var label: String {
        switch self {
        case .granted: "Granted"
        case .denied: "Not granted"
        case .notDetermined: "Not asked yet"
        }
    }

    var symbol: String {
        switch self {
        case .granted: "checkmark.circle.fill"
        case .denied: "xmark.circle.fill"
        case .notDetermined: "questionmark.circle.fill"
        }
    }
}
