#!/usr/bin/env python3
"""Prepare the maintained Copper FGN graph for a pipewireao-rtc session."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import sys


def expose_equivalence_outputs(graph: str) -> str:
    anchor = '            "feedback-to-controller:controller-constraint-feedback"\n'
    outputs = ('pyramid:mean-pupil-intensity', 'control:correction',
               'control:controller-state', 'command:constraint-feedback')
    if graph.count(anchor) != 1:
        raise ValueError("Copper feedback graph has no unique unmodified feedback output")
    tail = graph.split(anchor, 1)[1].split(']', 1)[0]
    if any(f'"{name}"' in tail for name in outputs):
        raise ValueError("Copper feedback graph has no unique unmodified feedback output")
    return graph.replace(
        anchor,
        anchor + ''.join(f'            "{name}"\n' for name in outputs),
        1,
    )


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--algorithms-root", type=Path, required=True)
    parser.add_argument("--heart-config", type=Path, required=True)
    parser.add_argument("--fgn-bundle", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--remote-name", default="pipewire-ao-0")
    parser.add_argument("--rate-hz", type=int, default=474)
    parser.add_argument("--command-limit-um", type=float, default=0.8)
    parser.add_argument("--clipping-feedback", action="store_true")
    parser.add_argument("--equivalence-observations", action="store_true",
                        help="expose existing feedback-state outputs for a direct-Algorithm test")
    args = parser.parse_args()

    if args.rate_hz <= 0:
        parser.error("--rate-hz must be positive")
    if args.command_limit_um <= 0:
        parser.error("--command-limit-um must be positive")
    if args.equivalence_observations and not args.clipping_feedback:
        parser.error("--equivalence-observations requires --clipping-feedback")
    scripts = args.algorithms_root.resolve() / "scripts"
    if not (scripts / "run_fgn_copper_fullframe_live.py").is_file():
        parser.error(f"maintained Copper generator is missing from {scripts}")
    if not args.fgn_bundle.is_file():
        parser.error(f"FGN bundle is not a file: {args.fgn_bundle}")
    sys.path.insert(0, str(scripts))
    from run_fgn_copper_fullframe_live import (  # noqa: PLC0415
        graph_config,
        prepare_artifacts,
        spa_quote,
    )

    output = args.output_dir.resolve()
    output.mkdir(parents=True, exist_ok=True)
    sources, manifest = prepare_artifacts(
        output, args.heart_config.resolve(), args.clipping_feedback
    )
    graph = graph_config(
        args.fgn_bundle.resolve(), args.rate_hz,
        args.clipping_feedback, args.command_limit_um,
    )
    if args.equivalence_observations:
        graph = expose_equivalence_outputs(graph)
    anchor = "    node.name = calculon-revolt-copper-fullframe\n"
    if graph.count(anchor) != 1:
        raise ValueError("maintained Copper graph changed its node identity")
    startup = "".join(
        f"    {spa_quote('pipewireao.startup-parameter.' + source['port'])}"
        f" = {spa_quote(str(source['path']))}\n"
        for source in sources
    )
    feedback = (
        '    "pipewireao.feedback.control:constraint-feedback" = '
        '"feedback-to-controller:controller-constraint-feedback"\n'
        if args.clipping_feedback else ""
    )
    graph = graph.replace(
        anchor,
        f"    remote.name = {spa_quote(args.remote_name)}\n"
        "    object.linger = false\n"
        "    pipewireao.run-control = true\n"
        "    pipewireao.reset-control = true\n"
        f"{anchor}{startup}{feedback}",
        1,
    )
    graph_path = output / "revolt-copper-rtc-graph.conf"
    graph_path.write_text(graph)
    (output / "revolt-copper-rtc-parameters.json").write_text(
        json.dumps(manifest, indent=2, sort_keys=True) + "\n"
    )
    print(f"PIPEWIREAO_RTC_GRAPH_COPPER_NATIVE={graph_path}")


if __name__ == "__main__":
    main()
