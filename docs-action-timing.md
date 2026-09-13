# Opt-in action timing diagnostic

This fork retains normal `/actions` responses and execution, including the
post-synthesis stability wait. All timestamps describe WDA boundaries, not
physical finger contact. No gesture batching is used by the timing experiment.

Within a WDA session, POST `/session/:id/wda/actionTiming` with
`{"enabled":true}` starts a fresh in-memory capture. GET the same URL retrieves
records; POST `{"enabled":false}` disables capture without discarding records.
Capture is associated with that session, defaults off, and retains at most 256
action records; overflow increments `dropped_records`. Re-enabling clears the
buffer. Fetch only after the measured touch sequence, not between gestures.

Each request has a zero-based sequence, outcome, optional error and boundary
objects containing phone `epoch_s` and `monotonic_s` (system uptime). Boundaries:
`request_entered`, `preparation_started`, `preparation_finished`,
`submitted_to_ios`, `ios_completion_callback`, `stability_wait_started`,
`stability_wait_finished`, `request_finished`. Missing boundaries remain absent;
`missing_ios_callback` is explicit after request completion. Callback result and
error are recorded independently of existing command success semantics.

Build with `GCC_PREPROCESSOR_DEFINITIONS='$(inherited) WDA_TIMING_BUILD_REVISION=<full-sha>'`.
The GET response reports that revision; absent injection reports `unversioned`,
which the experiment must reject. Record the fetched SHA and source cleanliness
alongside the build log: the macro alone is not proof of build provenance.

Epoch and monotonic readings are sequential, not atomic; use monotonic intervals
and one human calibration onset to anchor video comparisons. Recording metadata
is not assumed to be an exact host/video synchronization. Instrumentation can
perturb timing and must itself be validated.

Deploy only after signed instrumented and baseline builds are available. Keep
separate derived-data directories and preserve the existing XR2 build. Do not
stop working WDA merely to discover a signing failure. Collection remains off.
