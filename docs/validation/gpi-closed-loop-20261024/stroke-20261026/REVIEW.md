# Independent woofer stroke sensitivity review — 2026-10-26

Reviewed the private replay driver, resource resolver, case records, summary
and aggregation code. RTC worktree base: `49548303f08ff144f693d2c81047a831341c0a8d`.
The reviewer performed no new optical experiment or live action and wrote only
this review file.

## Isolation and verification

No scientific blocker was found. The candidate changes only the original
integrator's woofer conditioner limits from ±1 to ±3.4 µm OPD. Restoring those
two numbers reproduces the baseline graph exactly; both graphs receive the
same four observation outputs and identical parameter bytes. Hidden removal,
reconstructor, gains, feedback connections, optics, registration, atmosphere,
detector configuration, and stage/tweeter limits remain fixed. The scratch
resource resolver changes only resource-root lookup, with original source and
staged prescription identities still required.

All four scientific cases completed. Recorded clamp, requested-minus-demanded
feedback, adopted input, grid command and applied command errors are zero.
The actual mirror models are `LinearStaticActuators`; runtime command equality
confirms there is no second device clipping policy in this model. At optical
frame n these checks concern command n−1. The last newly issued command is
bounded and finite but has not yet produced an optical frame.

Baseline observations match the prior replay at all 96 recorded frames.
Baseline/candidate atmosphere hashes match over every spatial field at every
frame, including the 16,384-frame extension. Detector reset seed and observed
draw sequences match. This establishes the declared noise/reset policy, not
identical camera pixels after different optical trajectories. The summarizer
also checks that both long-run prefixes reproduce all short-run command
statistics, sampled optical series and sampled camera hashes. Separate raw-data
verification is owned by the root agent; this reviewer did not duplicate that
computation or infer its completion.

## Result and disposition

The short screen's sampled late-window mean residual WFE improves from
66.37 to 54.18 nm, meeting the predeclared 2% extension criterion. Both cases
were therefore extended from reset rather than extending only the candidate.

Over frames 2049–16384, sampled mean residual WFE improves from 59.68 to
54.08 nm, about 9.38%; sampled maximum improves from 89.28 to 70.32 nm.
These optical statistics use 224 uniform observations, not every frame.
In contrast, clipping and command peaks cover all 14,336 frames in that window.

The candidate has no woofer or stage clipping in this interval. Its maximum
woofer demand is 2.378 µm OPD, compared with the baseline's 1 µm clamp.
Tweeter clipping remains substantial: mean clipped coordinates fall from
54.82 to 27.43, but at least one tweeter coordinate still clips in 99.693% of
frames. Its maximum preclip request reaches 1.270 µm against the unchanged
1 µm bound. Thus this result does not establish an unsaturated whole plant or
resolve all allocation constraints.

Accept the result as finite sensitivity evidence that the provisional woofer
bound affects achievable correction for this matched scene. It does not
establish that ±3.4 µm is necessary or optimal: the assessed candidate demands
remain below that bound. Neither tilt redistribution nor discarded-state
removal was measured as a mechanism in this experiment.

No production or live limit change follows from this result. The wider bound
is a HEART-reference sensitivity setting, not measured hardware-stroke
qualification. This one-seed 8.192 s model replay does not establish global
stability, nonlinear hardware response, native-session behavior or deadline
performance. The original integrator and live settings remain unchanged.
