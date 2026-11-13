enum GhosttyIntentError: Error, CustomLocalizedStringResourceConvertible {
    case appUnavailable
    case surfaceNotFound
    case permissionDenied
    case passwordInputActive

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .appUnavailable: "The OMG app isn't properly initialized."
        case .surfaceNotFound: "The terminal no longer exists."
        case .permissionDenied: "OMG doesn't allow Shortcuts."
        case .passwordInputActive: "Cannot send input while the terminal is waiting for password input."
        }
    }
}
