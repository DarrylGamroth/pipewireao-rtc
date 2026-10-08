use super::*;
use pipewireao_rtc::calibration::{Exposure, ResponseBatch};
use tempfile::tempdir;
fn values() -> Vec<String> {
    [
        "--remote",
        "/tmp/private/pw",
        "--node",
        "owner.actions",
        "--owner-pid",
        "7",
        "--owner-instance",
        "42",
        "--plan",
        "plan.json",
    ]
    .map(str::to_owned)
    .to_vec()
}
#[test]
fn explicit_binding_is_required_and_legacy_endpoint_has_no_fallback() {
    let (binding, plan, evidence) = parse_args(values().into_iter()).unwrap();
    assert_eq!(binding.remote, "/tmp/private/pw");
    assert_eq!(binding.owner_pid, 7);
    assert_eq!(binding.instance, 42);
    assert_eq!(plan, "plan.json");
    assert!(evidence.is_none());
    for args in [
        vec!["--endpoint", "/tmp/calibration.sock", "--plan", "plan.json"],
        vec!["--remote"],
        vec!["--plan", "plan.json"],
    ] {
        assert!(parse_args(args.into_iter().map(str::to_owned)).is_err());
    }
    let mut duplicate = values();
    duplicate.extend(["--node".into(), "other".into()]);
    assert!(parse_args(duplicate.into_iter()).is_err());
    for (index, value) in [
        (1, "relative"),
        (5, "0"),
        (7, "0"),
        (7, "18446744073709551615"),
    ] {
        let mut args = values();
        args[index] = value.into();
        assert!(parse_args(args.into_iter()).is_err());
    }
}
fn plan() -> serde_json::Value {
    json!({"version":1,"run":u64::MAX,"reference":[0,0],"probes":[[1,2]],"measurements":2,
        "frames_per_probe":1,"settling":{"kind":"immediate"},
        "timeouts_ns":{"ownership":5_000_000_000_u64,"adoption":5_000_000_000_u64,
            "settling":5_000_000_000_u64,"collection":5_000_000_000_u64,"restoration":5_000_000_000_u64}})
}
#[test]
fn complete_native_wire_plan_preflight_precedes_connection_and_hold() {
    let valid = plan();
    assert_eq!(
        parse_plan(&serde_json::to_vec(&valid).unwrap()).unwrap().0,
        u64::MAX
    );
    let mut oversized = valid.clone();
    oversized["reference"] = json!(vec![1_f32; 4096]);
    oversized["probes"] = json!([vec![1_f32; 4096]]);
    assert!(parse_plan(&serde_json::to_vec(&oversized).unwrap()).is_err());
    let mut reply = valid.clone();
    reply["measurements"] = json!(131_072);
    assert!(parse_plan(&serde_json::to_vec(&reply).unwrap()).is_err());
    let mut rule = valid.clone();
    rule["settling"] = json!({"kind":"model_time","duration_ns":u64::MAX});
    assert!(parse_plan(&serde_json::to_vec(&rule).unwrap()).is_err());
    let mut budget = valid;
    budget["timeouts_ns"]["ownership"] = json!(u64::MAX);
    assert!(parse_plan(&serde_json::to_vec(&budget).unwrap()).is_err());
}

#[test]
fn evidence_charges_nested_objects_and_exposure_temporaries() {
    let after = AcquisitionCursor {
        domain: 1,
        generation: 1,
        sequence: 1,
        model_ns: 1,
    };
    let action = CalibrationAction::Settle {
        probe: 0,
        after,
        rule: SettlingRule::Immediate,
    };
    assert_eq!(action_charge(&action), 8192);
    let completion = CalibrationCompletion {
        request: pipewireao_rtc::calibration::CalibrationRequest { run: 1, serial: 1 },
        result: Ok(CalibrationEvidence::Responses(ResponseBatch {
            values: vec![1.0],
            exposures: vec![Exposure {
                domain: 1,
                generation: 1,
                sequence: 2,
                start_model_ns: 1,
                duration_ns: 1,
            }],
            valid: true,
        })),
    };
    assert_eq!(completion_charge(&completion), 8192 + 64 + 2048);
}

#[test]
fn evidence_preflight_preserves_existing_file_and_overflow_is_reported() {
    let dir = tempdir().unwrap();
    let path = dir.path().join("evidence.jsonl");
    std::fs::write(&path, "existing").unwrap();
    assert!(EvidenceJournal::create(&path, 1).is_err());
    assert_eq!(std::fs::read_to_string(&path).unwrap(), "existing");

    let fresh = dir.path().join("fresh.jsonl");
    let mut journal = EvidenceJournal::create(&fresh, 1).unwrap();
    journal.limit = journal.retained + 1024 + EVIDENCE_ERROR_RESERVE;
    journal.record(1024, || json!({"event":"first"}));
    journal.record(1024, || panic!("must not build a dropped record"));
    assert!(journal
        .finish()
        .unwrap_err()
        .contains("size limit exceeded"));
    let text = std::fs::read_to_string(&fresh).unwrap();
    assert!(text.contains("\"event\":\"header\""));
    assert!(text.contains("\"event\":\"first\""));
    assert!(text.contains("\"event\":\"evidence_error\""));
}

struct InvalidAt {
    action: Option<CalibrationEffect>,
    second_adopt: bool,
}

impl CalibrationEndpoint for InvalidAt {
    fn submit(&mut self, effect: &CalibrationEffect) -> Result<(), CalibrationFailure> {
        self.action = Some(effect.clone());
        Ok(())
    }

    fn receive(
        &mut self,
        _deadline: Instant,
    ) -> Result<Option<CalibrationCompletion>, CalibrationFailure> {
        let effect = self.action.take().unwrap();
        let zero = AcquisitionCursor {
            domain: 1,
            generation: 1,
            sequence: 0,
            model_ns: 0,
        };
        let result = match effect.action {
            CalibrationAction::Hold => CalibrationEvidence::Held(zero),
            CalibrationAction::Adopt { probe, figure } => CalibrationEvidence::Adopted {
                cursor: if probe == 1 && self.second_adopt {
                    zero
                } else if probe == 1 {
                    AcquisitionCursor {
                        sequence: 1,
                        model_ns: 1,
                        ..zero
                    }
                } else {
                    zero
                },
                figure,
                clipped: false,
            },
            CalibrationAction::Settle { after, .. } => CalibrationEvidence::Settled(after),
            CalibrationAction::Collect { .. } => CalibrationEvidence::Responses(ResponseBatch {
                values: vec![0.25, 0.5],
                exposures: vec![Exposure {
                    domain: 1,
                    generation: 1,
                    sequence: 1,
                    start_model_ns: 0,
                    duration_ns: 1,
                }],
                valid: self.second_adopt,
            }),
            CalibrationAction::Restore { figure, .. } => CalibrationEvidence::Restored {
                figure,
                clipped: false,
            },
            CalibrationAction::Release => CalibrationEvidence::Released,
        };
        Ok(Some(CalibrationCompletion {
            request: effect.request,
            result: Ok(result),
        }))
    }

    fn fault(&mut self, _failure: CalibrationFailure) {}
}

#[test]
fn aborted_journal_identifies_first_collect_or_second_adopt() {
    for second_adopt in [false, true] {
        let dir = tempdir().unwrap();
        let path = dir.path().join("evidence.jsonl");
        let mut input = plan();
        input["probes"] = json!([[1, 2], [2, 1]]);
        let (run, plan, _, probes) = parse_plan(&serde_json::to_vec(&input).unwrap()).unwrap();
        let mut endpoint = EvidenceEndpoint {
            inner: InvalidAt {
                action: None,
                second_adopt,
            },
            journal: EvidenceJournal::create(&path, probes).unwrap(),
            last_cursor: None,
        };
        let result = acquire_calibration(&mut endpoint, run, plan).unwrap();
        assert_eq!(result.phase(), CalibrationPhase::Aborted);
        assert_eq!(result.failure(), Some(CalibrationFailure::InvalidEvidence));
        assert!(result.responses().is_none());
        endpoint.journal.finish().unwrap();
        let records: Vec<serde_json::Value> = std::fs::read_to_string(&path)
            .unwrap()
            .lines()
            .map(|line| serde_json::from_str(line).unwrap())
            .collect();
        let submits: Vec<_> = records.iter().filter(|r| r["event"] == "submit").collect();
        let completions: Vec<_> = records
            .iter()
            .filter(|r| r["event"] == "completion")
            .collect();
        assert_eq!(submits.len(), completions.len());
        for (submit, completion) in submits.iter().zip(completions.iter()) {
            assert_eq!(submit["run"], completion["run"]);
            assert_eq!(submit["serial"], completion["serial"]);
        }
        let collect = records
            .iter()
            .find(|r| r["result"]["kind"] == "responses")
            .unwrap();
        assert_eq!(collect["result"]["values"], json!([0.25, 0.5]));
        assert_eq!(collect["result"]["exposures"][0]["sequence"], 1);
        if second_adopt {
            assert_eq!(collect["result"]["valid"], true);
            let rejected = records
                .iter()
                .find(|r| r["event"] == "completion" && r["serial"] == 5)
                .unwrap();
            assert_eq!(rejected["result"]["kind"], "adopted");
            assert_eq!(rejected["result"]["cursor"]["sequence"], 0);
            assert_eq!(submits[4]["action"]["kind"], "adopt");
            assert_eq!(submits[4]["action"]["probe"], 1);
            assert_eq!(submits[4]["prior_received_cursor"]["sequence"], 1);
        } else {
            assert_eq!(collect["result"]["valid"], false);
            assert_eq!(collect["serial"], 4);
            assert_eq!(submits[3]["action"]["kind"], "collect");
            assert_eq!(submits[3]["action"]["probe"], 0);
            assert_eq!(submits[3]["action"]["after"]["sequence"], 0);
        }
        assert_eq!(submits.last().unwrap()["action"]["kind"], "release");
    }
}
