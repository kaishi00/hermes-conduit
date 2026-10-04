//
//  UserFacingError.swift
//  Conduit
//
//  The text a failure shows people. Conduit's own errors already describe
//  themselves in plain words; system errors don't ("The operation couldn't
//  be completed. (Swift.CancellationError error 1.)", "The data couldn't be
//  read because it is missing."), so those become what happened and what to
//  do. Never classified from localized text: only from error types and codes.
//

import Foundation

enum UserFacingError {
    static func message(for error: Error) -> String {
        if error is CancellationError {
            return AppLocalization.string("That was interrupted before it finished. Try again.")
        }
        if error is DecodingError {
            return HermesError.invalidResponse.localizedDescription
        }
        let nsError = error as NSError
        if let urlError = error as? URLError ?? (nsError.domain == NSURLErrorDomain
            ? URLError(URLError.Code(rawValue: nsError.code)) : nil) {
            if urlError.code == .cancelled {
                return AppLocalization.string("That was interrupted before it finished. Try again.")
            }
            let failure = ConnectionFailureClassifier.classify(urlError)
            if failure != .unknown { return failure.userMessage }
            // Unmapped URL codes still get plain words, never NSURLErrorDomain
            // text. This fallback is context-neutral; mapped codes above keep
            // ConnectionFailure's (dashboard-worded) copy.
            return AppLocalization.string("A network problem stopped that. Check your connection and try again.")
        }
        return error.localizedDescription
    }
}
