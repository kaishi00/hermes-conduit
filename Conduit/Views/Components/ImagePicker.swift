//
//  ImagePicker.swift
//  Conduit
//
//  Wraps UIImagePickerController with allowsEditing = true
//  to give the native iOS crop UI for profile photos. With `onAnimated`,
//  it also offers videos (trimmed to AnimatedAvatar.maxDuration) and hands
//  over a GIF or other animated picture as its file, for a moving picture.
//

import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct ImagePicker: UIViewControllerRepresentable {
    @Binding var image: UIImage?
    /// A picked video or animated picture, as a copy the caller owns. Nil
    /// offers pictures only, and an animated one arrives as a still.
    var onAnimated: ((AnimatedAvatar.Source) -> Void)? = nil
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .photoLibrary
        picker.allowsEditing = true
        if onAnimated != nil {
            picker.mediaTypes = [UTType.image.identifier, UTType.movie.identifier]
            picker.videoMaximumDuration = AnimatedAvatar.maxDuration
            picker.videoQuality = .typeMedium
        }
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: ImagePicker
        init(_ parent: ImagePicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey : Any]) {
            if let onAnimated = parent.onAnimated {
                // The trimmed video, or the picture's own file when it
                // moves: the crop and the image hand over one frame.
                if let movie = info[.mediaURL] as? URL, let copy = AnimatedAvatar.keptCopy(of: movie) {
                    onAnimated(.movie(copy))
                    parent.dismiss()
                    return
                }
                if let file = info[.imageURL] as? URL, AnimatedAvatar.isAnimated(at: file),
                   let copy = AnimatedAvatar.keptCopy(of: file) {
                    onAnimated(.image(copy))
                    parent.dismiss()
                    return
                }
            }
            // Use the edited image if available, otherwise the original
            if let edited = info[.editedImage] as? UIImage {
                parent.image = edited
            } else if let original = info[.originalImage] as? UIImage {
                parent.image = original
            }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}
