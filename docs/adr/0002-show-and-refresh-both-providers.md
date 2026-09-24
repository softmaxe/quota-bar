# Show and refresh both providers

The status card shows Codex and Claude together, and every refresh fetches both. Until now the card showed one provider at a time and only that provider was polled, so switching providers could reveal a reading hours old. We accepted twice the quota requests, each still limited by its own provider's cooldown and server retry deadline, so that no reading on screen is older than the polling interval.

## Considered options

- **Keep one provider on show and add a compact summary of the other.** The summary would still show a reading that is never refreshed.
- **Refresh the hidden provider only when the card opens.** Every opening would first show the old reading and then change under the pointer.

## Consequences

- The "Showing" setting is gone. The menu bar icon reports the tightest window across signed-in providers instead of the chosen one.
- Reading Claude's credentials can raise a keychain prompt for people who never chose Claude. If the credentials cannot be read, whether the prompt was cancelled, denied, or left unanswered, automatic polling skips Claude's quota until the user retries or relaunches, so the prompt appears at most once per launch. Claude's local logs are still scanned.
- Local usage is scanned for both providers after launch, so the first scan reads both log trees.
