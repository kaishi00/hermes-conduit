//
//  ResponsivenessSignposts.swift
//  Conduit
//
//  Intervals around the moments users feel, for the os_signpost track of a
//  device trace in Instruments (#1533): a chat open from the tap to Hermes'
//  rows, with an event when its saved rows show; a profile switch; the live
//  Chats list landing; the saves and parses a tap used to wait on; and a
//  reconnect's steps: the OAuth refresh, the ticket and the socket (#1624).
//  Signposts cost next to nothing while no trace records them.
//

import os

enum ResponsivenessSignposts {
    static let signposter = OSSignposter(subsystem: "com.milim.relay", category: "Responsiveness")
}
