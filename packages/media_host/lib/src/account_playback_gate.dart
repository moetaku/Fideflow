/// The playback half of an account revocation (docs/design/accounts.md).
///
/// Signing out — or switching accounts — has to stop the previous account's
/// audio and take its private sources out of the session's hands. That is a
/// playback concern, so the credential owner does not do it itself: it holds a
/// gate and calls it inside the local sign-out transaction, *before* the
/// credentials are cleared, so that nothing authorized by the outgoing account
/// can reach the session afterwards.
///
/// The gate is deliberately narrower than a media controller: the coordinator
/// does not queue tracks, and a page must never drive the native queue on its
/// own. A caller that has nothing to stop (the fake backend, a test) passes
/// nothing, and the revocation is then a credentials-only operation.
abstract interface class AccountPlaybackGate {
  /// Stops the old account's playback and drops everything it authorized.
  ///
  /// Must be safe to call when nothing is playing and when the session is
  /// already gone, and must not throw for a session that refused: the local
  /// revocation is what makes the sign-out effective, and the remote round trip
  /// is best-effort on top of it.
  ///
  /// [authEpoch] is the epoch the new (post-revocation) credentials will carry,
  /// so an implementation can tag whatever it keeps from here on.
  Future<void> onAccountRevoked(int authEpoch);
}
