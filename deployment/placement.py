"""Inspect deployment credentials and threads without changing host policy."""

from __future__ import annotations

import os
from pathlib import Path
import resource


class DeploymentError(RuntimeError):
    pass


def cpu_set(values: list[int]) -> set[int]:
    if (not values or any(type(cpu) is not int or cpu < 2 for cpu in values)
            or len(values) != len(set(values))):
        raise DeploymentError("CPU lists must be distinct integers excluding CPUs 0 and 1")
    return set(values)


def credentials(priority: int, locked_bytes: int, latency_us: int | None) -> dict:
    rt_soft, rt_hard = resource.getrlimit(resource.RLIMIT_RTPRIO)
    mem_soft, mem_hard = resource.getrlimit(resource.RLIMIT_MEMLOCK)
    if priority and rt_soft != resource.RLIM_INFINITY and rt_soft < priority:
        raise DeploymentError(f"effective RT priority limit {rt_soft} is below {priority}; "
                              "user units cannot exceed the user manager's inherited rights")
    if locked_bytes and mem_soft != resource.RLIM_INFINITY and mem_soft < locked_bytes:
        raise DeploymentError(f"effective memlock limit {mem_soft} is below {locked_bytes} bytes")
    if latency_us is not None and not os.access("/dev/cpu_dma_latency", os.R_OK | os.W_OK):
        raise DeploymentError("cpu_dma_latency access requested but unavailable to effective "
                              "credentials; account rtc membership alone does not refresh "
                              "an existing shell or systemd user manager")
    return {"uid": os.getuid(), "groups": os.getgroups(),
            "rtprio": [rt_soft, rt_hard], "memlock": [mem_soft, mem_hard],
            "cpu_latency_us": latency_us}


def snapshot(pid: int, contract: dict) -> dict:
    envelope = cpu_set(contract["cpus"])
    task = Path(f"/proc/{pid}/task")
    before = sorted(int(path.name) for path in task.iterdir())
    threads = []
    for tid in before:
        affinity = sorted(os.sched_getaffinity(tid))
        policy = os.sched_getscheduler(tid) & ~0x40000000
        priority = os.sched_getparam(tid).sched_priority
        name = (task / str(tid) / "comm").read_text().strip()
        if not set(affinity) <= envelope:
            raise DeploymentError(f"thread {tid} ({name}) affinity {affinity} exceeds "
                                  f"deployment envelope {sorted(envelope)}")
        permitted = policy == os.SCHED_OTHER and priority == 0
        permitted |= policy == os.SCHED_FIFO and priority == contract["rt-priority"]
        if not permitted or (tid == pid and policy != os.SCHED_OTHER):
            raise DeploymentError(f"thread {tid} ({name}) has unrequested scheduler "
                                  f"policy={policy} priority={priority}")
        if tid == pid and affinity != [contract["leader-cpu"]]:
            raise DeploymentError(f"process leader {tid} must remain on housekeeping "
                                  f"CPU {contract['leader-cpu']}, observed {affinity}")
        threads.append({"tid": tid, "name": name, "cpus": affinity,
                        "policy": policy, "priority": priority})
    after = sorted(int(path.name) for path in task.iterdir())
    if before != after:
        raise DeploymentError(f"process {pid} changed threads during readiness inspection")
    for required in contract["threads"]:
        matching = [thread for thread in threads
                    if thread["cpus"] == required["cpus"]
                    and thread["policy"] == (os.SCHED_FIFO if required["policy"] == "fifo"
                                             else os.SCHED_OTHER)
                    and thread["priority"] == required["priority"]
                    and ("name" not in required or thread["name"] == required["name"])]
        if len(matching) != required["count"]:
            raise DeploymentError(f"process {pid} requires {required['count']} thread(s) "
                                  f"matching {required}, observed {len(matching)}")
    status = dict(line.split(":", 1) for line in Path(f"/proc/{pid}/status").read_text()
                  .splitlines() if ":" in line)
    locked_kb = int(status.get("VmLck", "0 kB").split()[0])
    if locked_kb * 1024 < contract.get("locked-bytes", 0):
        raise DeploymentError(f"process {pid} locked {locked_kb * 1024} bytes, below "
                              f"requested {contract['locked-bytes']}")
    return {"pid": pid, "threads": threads, "locked_bytes": locked_kb * 1024}
