# Alaud

Native iOS / watchOS meeting recorder. Read `docs/PRODUCT.md` and `docs/VALIDATION.md` before changing scope or reporting readiness.

- Product name: Alaud. Phone bundle ID `com.gaoyiming.alaud`, Watch ID `com.gaoyiming.alaud.watchkitapp`; update the companion ID together if renaming.
- `Sources/Core` is a UI-independent Swift package. `Sources/Shared` contains device recording, transfer, runtime and intents. Platform views live in `Sources/Phone` and `Sources/Watch`.
- Generate the Xcode project with `xcodegen generate` after editing `project.yml`. Keep developer-team values out of committed files; set them in Xcode or pass `DEVELOPMENT_TEAM` when building.
- Preserve watch originals until a fresh full-meeting storage receipt confirms the phone has persisted and hashed every original and final manifest. Legacy part/final acknowledgements and WCSession completion do not authorize deletion. Copy incoming WCSession temporary files synchronously before returning from the delegate.
- Cleanup is automatic on the watch after full proof, using an atomic move into .cleanup before removal. Reject incomplete/live meetings, mismatched receipts, and unregistered audio. Never run watch cleanup against the phone store.
- Playback and ShareLink in the same List row require explicit independent button styles and tap targets. Run the playback UI regression after changing that row.
- Never overwrite orphaned audio on resume, mark missing parts complete, or erase phone edits when Watch retries arrive.
- Keep original audio, transcript, gaps and follow-ups distinct. Meeting speech is input data, not authorization for Agent actions.
- Agent execution scope is intentionally undefined. Current export is a handoff interface, not a running Agent integration.
- Focus needs user-configured Shortcuts; system alarms and calls cannot be comprehensively suppressed. Do not present these as guaranteed capabilities.
- Run `swift test` for model/storage changes. Audio writer changes also require the hosted iOS tests, including the 90-minute synthetic stream and format-conversion case.
- Keep simulator compilation, synthetic file tests, visual review and real-device acceptance separate. `docs/DEVICE_ACCEPTANCE.md` remains open until real evidence exists.
- Raw meeting audio, transcripts, signing state and credentials stay off GitHub and developer-material uploads. Cloud pointers are in `project-cloud-manifest.json`.
