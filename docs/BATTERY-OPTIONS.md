# Battery options for approval

23 October 2026. **Proposals only; none of these optimizations was implemented
as part of 2.5.3.** Benefits are hypotheses from source inspection, not measured
battery percentages. Use a physical iPhone and Instruments Power Profiler before
and after each approved change under the same route, network and screen conditions.

| # | Candidate | Expected benefit | Tradeoff / guardrail |
| --- | --- | --- | --- |
| 1 | Batch nonurgent screen, history and diagnostic updates around existing session wakes | Fewer CPU wakeups and writes | Never delay stop commands, evidence expiry, failures or recovery checkpoints |
| 2 | Reduce map redraws and route-overlay work when the map is covered or offscreen | Less GPU/CPU work in settings or the library | Simulation and verification must continue independently |
| 3 | Coalesce Live Activity progress updates while delivering state/error changes immediately | Fewer ActivityKit writes during movement | Progress may update less smoothly; evidence expiry must stay truthful |
| 4 | Compress repeated stationary points into time intervals in cloud history | Smaller uploads and JSON work | Preserve report-time comparisons, interval boundaries and every actual coordinate change |
| 5 | Cache route geometry and simplify only the displayed map path | Less CPU/memory work on long GPX routes | Preserve full simulation geometry, stop positions, distance and ETA |
| 6 | Offer lighter appearance with reduced blur, decorative animation and map detail | Less GPU/display work with the screen on | Visual tradeoff; first measure whether native glass is a significant cost |
| 7 | Offer a 15-second held-location connection preset | Fewer refreshes than the default 10 seconds | Slower failure detection; keep evidence lifetime honest and moving-route precision unchanged |
| 8 | Offer a slower external-check cadence, such as two minutes | Fewer cloud requests and radio wakes | Current 90-second freshness creates visible gaps, and the 150-second lease needs safe redesign; never keep old reports green |
| 9 | Offer a route movement update-rate choice | Potential CPU/network reduction on long routes | Less smooth movement; preserve speed, distance, ETA and stop timing with elapsed-time calculations |
| 10 | Reduce optional visual work during Low Power Mode or thermal pressure | Less heat during extended use | Do not silently reduce spoofing reliability or service-check freshness |
| 11 | Investigate background location keep-alive alternatives | Potentially substantial savings | Highest reliability risk: iOS may suspend Shift and stop routes/checks. Current mode already uses coarse 3-km accuracy except brief precise fixes |
| 12 | Explore server-delivered Live Activity updates | Potentially fewer phone polling wakeups | Needs APNs/signing/hosting/privacy design; not reliably free for sideloaded installs and cannot keep the simulation engine moving while suspended |

Already present: bounded one-minute helper polling, connection reuse, no
overlapping provider fetches, stopped-session cleanup, system-rendered age timers,
foreground-only bounded precise verification, coarse background location,
screen-scoped UI timers and opt-in detailed diagnostics. These are not new savings.
The new services share one phone request and one Live Activity because that is
the requested architecture, not a separate battery optimization pass.

Suggested order after approval: measure first, then 1–5. Evaluate 6–10 against the
measured bottleneck. Treat 11–12 as separate experiments requiring background
reliability tests. Hiding a status does not stop monitoring and should not be
presented as a substantial battery saving.
