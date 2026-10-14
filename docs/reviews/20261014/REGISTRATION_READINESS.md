# Registration boundary for the Classic application

Observed local sources and registry on 2026-10-14. This inventory identifies
release prerequisites; it does not declare the scientific working trees ready
for publication or the small application complete.

| Dependency | Installed Local Registry | Selected local source and boundary |
|---|---|---|
| PipeWireAORTC | Initially absent | Reviewed implementation branch; register only a clean committed tree after focused checks |
| PipeWireAO | Initially through 0.6.16 | Already published commit `1417b69656b94e146e600c7201bc4d3b34d2cea4`, version 0.6.17, tree `4b859fef04b1b77e3a6451d1c22b2a3e0e5bc5ee`; clean detached registration worktree excludes current unrelated source changes |
| FilterGraphAlgorithms | 0.5.5 | Source declares 0.5.6; enclosing JFG repository has uncommitted algorithm/declaration changes |
| JuliaFilterGraph | 0.2.3 | Source declares 0.2.4 at repository HEAD `97ead7c36ba0ee69e548164ca7a719658ff6968c`, with additional working changes |
| FilterGraphPipeWire | Absent | Source declares 0.1.2 in the same repository, with working changes; registration needs subdirectory `julia/FilterGraphPipeWire` |
| AdaptiveOpticsSim | Absent | Source 0.1.0 at `ed9a3f30f2834662a746961ee3f920b23823d8de`; work branch is ahead 1/behind 101 against its cached origin/main and has substantial working changes |
| AdaptiveOpticsSimPipeWireHIL | Absent | Source 0.1.2 at `2c15a9f062532e43b69076429465482f4297a0e9`, working changes and no tracked upstream on the selected branch |
| AdaptiveOpticsCalibration | 0.17.0 | Already registered; no release needed merely to satisfy the user's registration decision |
| FITSIO / CUDA | General dependencies | FITSIO 0.17.5 resolved for the cold package; CUDA remains an optional scientific application dependency |
| REVOLTClassicSim | Intentionally excluded | Export exact instrument data/configuration and remove runtime dependency; do not register this package |

The 2026-10-13 installed HIL Manifest uses sealed local paths for AOC, AOS,
the HIL adapter, FGA, PipeWireAO and REVOLTClassicSim. Package version strings
in that Manifest do not identify the dirty working snapshots as immutable
registered releases. Registering the current clean HEAD under the same version
would not, by itself, establish equivalence to the installed snapshot.

Next scientific release work must select and review the intended source changes,
commit them in dedicated worktrees, implement public graph introspection and
configuration-driven owner entrypoints, and qualify the exact dependency closure.
Do not publish unrelated working changes or select older clean source merely to
make a registry resolver succeed. FGA/JFG existing registry entries already use
their monorepo subdirectories; retain that convention for FGPW.

The core registration can proceed independently using the reviewed PipeWireAORTC
tree and the existing published PipeWireAO release. It does not close the
registered Classic science/application gate. LocalRegistry's installed version
does not recognize a registry with a Git-worktree `.git` file; registration is
prepared in an ordinary isolated registry clone, preserving the user's registry
until the resulting entries and resolution are checked.
