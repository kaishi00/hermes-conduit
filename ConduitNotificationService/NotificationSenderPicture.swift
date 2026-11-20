import Intents
import UserNotifications

/// Puts the bot's face on a verified push (Communication Notifications):
/// the push becomes a message from the bot, an `INSendMessageIntent`
/// whose sender carries the picture Conduit left in the app group
/// (NotificationAvatars). A push whose bot has no picture there, or that
/// iOS won't update, keeps Conduit's icon and its words unchanged.
///
/// Needs the Communication Notifications capability
/// (`com.apple.developer.usernotifications.communication`) on the app's
/// and this extension's identifiers; without it iOS ignores the update and
/// shows the push as before.
enum NotificationSenderPicture {
    static func apply(
        to content: UNMutableNotificationContent,
        sender: NotificationAvatars.Sender?,
        picture: Data?,
        completion: @escaping (UNMutableNotificationContent) -> Void
    ) {
        guard let sender, let picture else { return completion(content) }
        let image = INImage(imageData: picture)
        let handle = INPersonHandle(value: sender.handle, type: .unknown)
        let person = INPerson(
            personHandle: handle,
            nameComponents: nil,
            displayName: sender.displayName,
            image: image,
            contactIdentifier: nil,
            customIdentifier: sender.handle,
            isMe: false,
            suggestionType: .none
        )
        let intent = INSendMessageIntent(
            recipients: nil,
            outgoingMessageType: .outgoingMessageText,
            content: content.body,
            speakableGroupName: sender.groupName.map { INSpeakableString(spokenPhrase: $0) },
            conversationIdentifier: sender.conversationID,
            serviceName: nil,
            sender: person,
            attachments: nil
        )
        intent.setImage(image, forParameterNamed: \.sender)
        let interaction = INInteraction(intent: intent, response: nil)
        interaction.direction = .incoming
        interaction.donate { _ in
            // A refused donation still lets iOS draw the sender; the
            // update below is what decides.
            guard let updated = try? content.updating(from: intent),
                  let mutable = updated.mutableCopy() as? UNMutableNotificationContent
            else { return completion(content) }
            completion(mutable)
        }
    }
}
