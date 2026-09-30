#!/usr/bin/env python3
"""Drain Classic's automatic secondary streams using HEART's public Python client."""
import argparse
import json
from pathlib import Path
from queue import Empty
import sys
import time


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--heart-root',type=Path,required=True)
    parser.add_argument('--dao-root',type=Path,required=True)
    parser.add_argument('--ready',type=Path,required=True)
    parser.add_argument('--stop',type=Path,required=True)
    parser.add_argument('--report',type=Path,required=True)
    args=parser.parse_args()
    for root in (args.heart_root,args.dao_root):sys.path.insert(0,str(root/'source/python'))
    from heart.util.telstream import TelemetryStream
    from daoinsw.util.debugPrint import DebugLevel
    clients=[]
    report={'client':'unchanged HEART TelemetryStream','ports':[6300,6301],'buckets_consumed':[0,0]}
    try:
        for port in report['ports']:
            client=TelemetryStream('localhost',port,capacity=100)
            client.setDebugLevel(DebugLevel.ERROR)
            clients.append(client)
            # The public client returns silently on a finite timeout. Block
            # here; the launcher's readiness timeout keeps ingress closed.
            client.waitForConnection()
        args.ready.touch(exist_ok=False)
        while not args.stop.exists():
            for n,client in enumerate(clients):
                while True:
                    try:client.getBucket(block=False);report['buckets_consumed'][n]+=1
                    except Empty:break
            time.sleep(.005)
    finally:
        report['received']=[client.numReceived for client in clients]
        report['dropped']=[client.numDropped for client in clients]
        for client in clients:client.close()
        args.report.write_text(json.dumps(report,indent=2)+'\n')

if __name__=='__main__':main()
