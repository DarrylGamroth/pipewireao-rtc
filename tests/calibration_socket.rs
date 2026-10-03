#![cfg(unix)]

use pipewireao_rtc::calibration::{
    acquire_calibration, CalibrationAction, CalibrationEffect, CalibrationEndpoint,
    CalibrationEvidence, CalibrationFailure, CalibrationPhase, CalibrationPlan, CalibrationRequest,
    CalibrationTimeouts, SettlingRule,
};
use pipewireao_rtc::calibration_socket::CalibrationSocketEndpoint;
use serde_json::{json, Value};
use std::io::{BufRead, BufReader, Read, Write};
use std::os::unix::net::UnixStream;
use std::sync::Arc;
use std::thread;
use std::time::{Duration, Instant};

fn effect(action: CalibrationAction) -> CalibrationEffect {
    CalibrationEffect {
        request: CalibrationRequest { run: 17, serial: 1 },
        action,
        deadline: Instant::now() + Duration::from_secs(2),
    }
}

fn reply(result: &Value) -> Vec<u8> {
    let mut bytes = serde_json::to_vec(&json!({
        "version":1,"run":17,"serial":1,"result":result,
    }))
    .unwrap();
    bytes.push(b'\n');
    bytes
}

#[test]
fn submission_is_bounded_and_does_not_wait_for_peer() {
    let (client, mut server) = UnixStream::pair().unwrap();
    let mut endpoint = CalibrationSocketEndpoint::new(client).unwrap();
    endpoint.submit(&effect(CalibrationAction::Hold)).unwrap();
    server.set_nonblocking(true).unwrap();
    assert_eq!(
        server.read(&mut [0]).unwrap_err().kind(),
        std::io::ErrorKind::WouldBlock
    );
    assert_eq!(
        endpoint.submit(&effect(CalibrationAction::Release)),
        Err(CalibrationFailure::Endpoint)
    );
    assert!(endpoint
        .receive(Instant::now() + Duration::from_millis(2))
        .unwrap()
        .is_none());
    let mut bytes = [0; 2048];
    let count = server.read(&mut bytes).unwrap();
    let request: Value = serde_json::from_slice(&bytes[..count]).unwrap();
    assert_eq!(request["action"], json!({"kind":"hold"}));
    assert_eq!(request["run"], 17);
    assert!(request["timeout_ns"].as_u64().unwrap() > 0);
    endpoint
        .submit(&effect(CalibrationAction::Release))
        .unwrap();
}

#[test]
fn oversized_unsubmitted_request_does_not_prevent_restoration() {
    let (client, _server) = UnixStream::pair().unwrap();
    let mut endpoint = CalibrationSocketEndpoint::new(client).unwrap();
    assert_eq!(
        endpoint.submit(&effect(CalibrationAction::Adopt {
            probe: 0,
            figure: Arc::from(vec![1.0; 16_384]),
        })),
        Err(CalibrationFailure::Endpoint)
    );
    endpoint
        .submit(&effect(CalibrationAction::Restore {
            figure: Arc::from([0.0]),
            rule: SettlingRule::Immediate,
        }))
        .unwrap();
}

#[test]
fn split_and_coalesced_completions_preserve_identities() {
    let (client, mut server) = UnixStream::pair().unwrap();
    let mut endpoint = CalibrationSocketEndpoint::new(client).unwrap();
    let bytes = reply(&json!({"kind":"held", "cursor":{
        "domain":7,"generation":1,"sequence":0,"model_ns":100,
    }}));
    let other = reply(&json!({"kind":"released"}));
    let producer = thread::spawn(move || {
        server.write_all(&bytes[..13]).unwrap();
        server.write_all(&bytes[13..]).unwrap();
        server.write_all(&other).unwrap();
    });
    let complete = endpoint
        .receive(Instant::now() + Duration::from_secs(2))
        .unwrap()
        .unwrap();
    assert_eq!(complete.request.run, 17);
    assert!(matches!(complete.result, Ok(CalibrationEvidence::Held(_))));
    assert!(matches!(
        endpoint
            .receive(Instant::now() + Duration::from_secs(2))
            .unwrap()
            .unwrap()
            .result,
        Ok(CalibrationEvidence::Released)
    ));
    producer.join().unwrap();
}

#[test]
fn malformed_and_oversized_evidence_is_rejected() {
    for bytes in [
        b"{\n".to_vec(),
        reply(&json!({"kind":"released","extra":true})),
        reply(&json!({"kind":"failed","reason":"invented"})),
        vec![b'x'; 64 * 1024],
    ] {
        let (client, mut server) = UnixStream::pair().unwrap();
        let mut endpoint = CalibrationSocketEndpoint::new(client).unwrap();
        let producer = thread::spawn(move || server.write_all(&bytes).unwrap());
        let result = endpoint.receive(Instant::now() + Duration::from_secs(2));
        assert!(
            matches!(result, Err(CalibrationFailure::InvalidEvidence)),
            "unexpected completion: {result:?}"
        );
        producer.join().unwrap();
    }
}

#[test]
fn disconnect_and_fault_do_not_resume_or_retry() {
    let (client, mut server) = UnixStream::pair().unwrap();
    let mut endpoint = CalibrationSocketEndpoint::new(client).unwrap();
    endpoint.fault(CalibrationFailure::InvalidEvidence);
    assert_eq!(
        endpoint.fault_reason(),
        Some(CalibrationFailure::InvalidEvidence)
    );
    assert_eq!(
        endpoint.submit(&effect(CalibrationAction::Release)),
        Err(CalibrationFailure::Endpoint)
    );
    assert_eq!(server.read(&mut [0]).unwrap(), 0);
    let (client, server) = UnixStream::pair().unwrap();
    let mut endpoint = CalibrationSocketEndpoint::new(client).unwrap();
    drop(server);
    assert!(matches!(
        endpoint.receive(Instant::now() + Duration::from_secs(2)),
        Err(CalibrationFailure::Endpoint)
    ));
}

#[test]
fn saturated_socket_expires_and_cannot_replace_unwritten_request() {
    let (mut client, mut server) = UnixStream::pair().unwrap();
    client.set_nonblocking(true).unwrap();
    // Fill the real kernel send queue, independently of the endpoint's single
    // prepared output slot. No peer reader frees capacity during this test.
    let block = [b'x'; 4096];
    let mut queued = 0;
    loop {
        match client.write(&block) {
            Ok(count) => queued += count,
            Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => break,
            Err(error) => panic!("socket filling failed: {error}"),
        }
    }
    assert!(queued > 0);
    let mut endpoint = CalibrationSocketEndpoint::new(client).unwrap();
    endpoint.submit(&effect(CalibrationAction::Hold)).unwrap();
    assert!(endpoint
        .receive(Instant::now() + Duration::from_millis(2))
        .unwrap()
        .is_none());
    assert_eq!(
        endpoint.submit(&effect(CalibrationAction::Restore {
            figure: Arc::from([0.0]),
            rule: SettlingRule::Immediate,
        })),
        Err(CalibrationFailure::Endpoint)
    );
    endpoint.fault(CalibrationFailure::Endpoint);
    let mut observed = Vec::new();
    server.read_to_end(&mut observed).unwrap();
    assert_eq!(observed.len(), queued);
    assert!(observed.iter().all(|byte| *byte == b'x'));
}

#[test]
fn late_adoption_is_rejected_while_fenced_restoration_completes() {
    let (client, server) = UnixStream::pair().unwrap();
    let mut endpoint = CalibrationSocketEndpoint::new(client).unwrap();
    let owner = thread::spawn(move || {
        let mut reader = BufReader::new(server);
        let mut late = None;
        loop {
            let mut line = String::new();
            assert!(reader.read_line(&mut line).unwrap() > 0);
            let request: Value = serde_json::from_str(&line).unwrap();
            let cursor = json!({"domain":7,"generation":1,"sequence":0,"model_ns":0});
            let kind = request["action"]["kind"].as_str().unwrap();
            let result = match kind {
                "hold" => json!({"kind":"held","cursor":cursor}),
                "adopt" => {
                    late = Some(request.clone());
                    continue;
                }
                "restore" => {
                    // The timed-out operation finishes first. It cannot advance
                    // the coordinator's current restoration request.
                    let prior = late.take().unwrap();
                    let mut bytes = serde_json::to_vec(&json!({"version":1,"run":prior["run"],
                        "serial":prior["serial"],"result":{"kind":"adopted","cursor":cursor,
                        "figure":prior["action"]["figure"],"clipped":false}}))
                    .unwrap();
                    bytes.push(b'\n');
                    reader.get_mut().write_all(&bytes).unwrap();
                    json!({"kind":"restored","figure":request["action"]["figure"],"clipped":false})
                }
                "release" => json!({"kind":"released"}),
                _ => panic!("unexpected action: {kind}"),
            };
            let mut bytes = serde_json::to_vec(&json!({"version":1,"run":request["run"],
                "serial":request["serial"],"result":result}))
            .unwrap();
            bytes.push(b'\n');
            reader.get_mut().write_all(&bytes).unwrap();
            if kind == "release" {
                break;
            }
        }
    });
    let timeout = Duration::from_secs(2);
    let plan = CalibrationPlan::new(
        Arc::from([0.0]),
        vec![Arc::from([0.1])],
        1,
        1,
        SettlingRule::Immediate,
        CalibrationTimeouts {
            ownership: timeout,
            adoption: Duration::from_millis(40),
            settling: timeout,
            collection: timeout,
            restoration: timeout,
        },
    )
    .unwrap();
    let coordinator = acquire_calibration(&mut endpoint, 17, plan).unwrap();
    assert_eq!(coordinator.phase(), CalibrationPhase::Aborted);
    assert_eq!(
        coordinator.failure(),
        Some(CalibrationFailure::TimedOut(CalibrationPhase::Adopting))
    );
    assert!(coordinator.restoration_confirmed());
    assert!(coordinator.responses().is_none());
    assert_eq!(endpoint.fault_reason(), None);
    owner.join().unwrap();
}

#[test]
fn coordinator_uses_socket_completions_for_entire_session() {
    let (client, server) = UnixStream::pair().unwrap();
    let mut endpoint = CalibrationSocketEndpoint::new(client).unwrap();
    let owner = thread::spawn(move || {
        let mut reader = BufReader::new(server);
        let mut sequence = 0;
        loop {
            let mut line = String::new();
            assert!(reader.read_line(&mut line).unwrap() > 0);
            let request: Value = serde_json::from_str(&line).unwrap();
            let cursor =
                json!({"domain":7,"generation":1,"sequence":sequence,"model_ns":sequence*10});
            let kind = request["action"]["kind"].as_str().unwrap();
            let result = match kind {
                "hold" => json!({"kind":"held","cursor":cursor}),
                "adopt" => {
                    json!({"kind":"adopted","cursor":cursor,"figure":request["action"]["figure"],"clipped":false})
                }
                "settle" => json!({"kind":"settled","cursor":cursor}),
                "collect" => {
                    let start = sequence * 10;
                    sequence += 1;
                    json!({"kind":"responses","values":[0.25],"valid":true,
                        "exposures":[{"domain":7,"generation":1,"sequence":sequence,"start_model_ns":start,"duration_ns":10}]})
                }
                "restore" => {
                    json!({"kind":"restored","figure":request["action"]["figure"],"clipped":false})
                }
                "release" => json!({"kind":"released"}),
                _ => panic!("unexpected action"),
            };
            let mut reply = serde_json::to_vec(&json!({"version":1,"run":request["run"],
                "serial":request["serial"],"result":result}))
            .unwrap();
            reply.push(b'\n');
            reader.get_mut().write_all(&reply).unwrap();
            if kind == "release" {
                break;
            }
        }
    });
    let timeout = Duration::from_secs(2);
    let plan = CalibrationPlan::new(
        Arc::from([0.0]),
        vec![Arc::from([0.1])],
        1,
        1,
        SettlingRule::Immediate,
        CalibrationTimeouts {
            ownership: timeout,
            adoption: timeout,
            settling: timeout,
            collection: timeout,
            restoration: timeout,
        },
    )
    .unwrap();
    let coordinator = acquire_calibration(&mut endpoint, 17, plan).unwrap();
    assert_eq!(coordinator.phase(), CalibrationPhase::Complete);
    assert!(coordinator.restoration_confirmed());
    assert_eq!(coordinator.responses().unwrap()[0].values, [0.25]);
    owner.join().unwrap();
}
