//
//  LocationIngest.swift
//  Conduit
//
//  The sealed body a batch is posted to `/location/ingest` with. Kept apart
//  from LocationHostClient.swift, which the Pulse widget also compiles.
//

import Foundation

/// Seals a batch and posts it to `/location/ingest`.
enum LocationIngest {
    /// The ingest body for a batch.
    static func body(_ batch: LocationBatch, key: LocationCrypto.SessionKey) throws -> [String: Any] {
        var batch = batch
        // A key from before maps can't open a maps request: the host isn't
        // told this iPhone answers them until the key is agreed again.
        if !key.answersMaps { batch.features = [] }
        return try LocationCrypto.envelope(plaintext: batch.plaintext(), key: key, batchID: batch.batchID)
    }
}
