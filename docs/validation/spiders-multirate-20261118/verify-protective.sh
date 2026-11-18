#!/usr/bin/env bash
set -euo pipefail
recovery="$1"
pulse="$2"
control="$3"

jq -e '
    .clean_stop and .commands_consumed==3346 and .phases.release.clipping==197 and
    .parameter_status.release_processed.active_parameter_sequence==2 and
    all(.stream_status[]; (.pending|not) and .dropped==0 and .gaps==0 and .rejected==0 and (.failed|not)) and
    .protective_recovery.flat_transition.tick==1801 and
    .protective_recovery.flat_transition.amplitude_native==0 and
    .protective_recovery.flat_transition.step_inf_native==0.5 and
    .phases.protective_reset.clipping==0 and .phases.reclose.clipping==0 and
    .phases.post_reclose.clipping==0 and .phases.post_reclose.command==990 and
    ([.protective_recovery.gates[]|[.name,.tick]] ==
        [["before_reset",1801],["reset_applied_cameras_silent",1801],
         ["fresh_llowfs_flat_reference",1801],["fresh_llowfs_flat_reference",1802],
         ["fresh_llowfs_flat_reference",1803],["fresh_llowfs_flat_reference",1804],
         ["scc_primed_without_demand",1804],["fresh_llowfs_flat_reference",1805],
         ["release_leaves_both_open",1805],["fresh_branch_2",1806],
         ["closed_branch_2",1806],["fresh_branch_1",1807],["closed_branch_1",1807]]) and
    (.protective_recovery.gates[-1].properties |
       .["correction:closed"] and .["llowfs-correction:closed"] and (.["pipewireao-recovery:close-guarded"]|not))
' "$recovery/transport.json" >/dev/null

jq -e '
    .native_commands==3346 and .missing_command_feedback==0 and .unpaired_feedback==0 and
    .inconsistent_clamps==0 and .out_of_bounds_commands==0 and
    (.scc_pair_history | .missing==0 and .unexpected==0 and .unpaired==0 and .priming_with_no_status==3) and
    (.recovery | .observed and .last_clipped_tick==1800 and .first_unclipped_tail_tick==1801 and
      .sustained_unclipped_commands==998 and .last_observed_tick==2550 and .verified_feedback_pairs and
      .consecutive_identity)
' "$recovery/measurement.json" >/dev/null

# A passive pw-dump readback supplements the gates recorded by the native runner.
if [[ -f "$recovery/live-closure-1950.json" ]]; then
jq -e '
    .state=="running" and (.properties[0].params as $p |
        reduce range(0; $p|length; 2) as $i ({}; .[$p[$i]]=$p[$i+1]) |
        .["correction:closed"] and .["llowfs-correction:closed"] and (.["pipewireao-recovery:close-guarded"]|not))
' "$recovery/live-closure-1950.json" >/dev/null
fi

for file in optical commands; do
    if [[ "$file" == optical ]]; then
        columns='{print $1,$2,$3,$4,$5,$6,$7,$8,$9,$11,$12}'
    else
        columns='{print $1,$2,$3,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16,$17}'
    fi
    cmp <(awk -F, "NR>1 && \$1<=1800 $columns" "$recovery/$file.csv") \
        <(awk -F, "NR>1 && \$1<=1800 $columns" "$pulse/$file.csv")
done
printf 'Pulse and protective runs match through tick 1800\n'

# Each row in applied-command.csv is one serialized native camera event.
# The conditioner has no slew or dither. An isolated step in that event's
# exact shared sequence establishes an active branch contribution.
awk -F, '
    NR==FNR {if (FNR>1 && $1>=2500 && $8>0) changed[$4,$5,$6]=1; next}
    FNR>1 && ($5 SUBSEP $6 SUBSEP $7) in changed {last[$3]=$1; updates[$3]++}
    END {
        if (last["llowfs"]!=2550 || last["scc"]!=2548) exit 1
        printf "Late nonzero branch command steps: LLOWFS %d (last tick %d), SCC %d (last tick %d)\n", \
            updates["llowfs"],last["llowfs"],updates["scc"],last["scc"]
    }' "$recovery/commands.csv" "$recovery/applied-command.csv"

printf 'Last 300 model ticks\narm,mean_unfringed_contrast,llowfs_tip_tilt_rms_m\n'
for arm in control pulse recovery; do
    run=${!arm}
    contrast=$(awk -F, '$1>=2251 && $3=="scc" && $8=="unfringed" && $9!="" {n++; total+=$9} END {if(n!=150) exit 1; printf "%.14g",total/n}' "$run/optical.csv")
    residual=$(awk -F, '$1>=2251 && $3=="llowfs-modal-residual" && $10!="" {n++; total+=$10*$10} END {if(n!=300) exit 1; printf "%.14g",sqrt(total/n)}' "$run/native.csv")
    printf '%s,%s,%s\n' "$arm" "$contrast" "$residual"
done
