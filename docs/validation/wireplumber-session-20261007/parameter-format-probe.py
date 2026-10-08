from pathlib import Path
import tempfile,subprocess,os,time,json
r=Path(tempfile.mkdtemp(prefix='pwao-format-',dir='/run/user/1000'))
old=Path('/run/user/1000/pipewireao-session-wf-0710/1c10460020d247ed831377b1d99fc0ad')
prefix=Path('/tmp/pwao-linktrace')
env=os.environ.copy()
env.update(LD_LIBRARY_PATH=str(prefix/'lib/x86_64-linux-gnu'),PIPEWIREAO_RUNTIME_DIR=str(r),PIPEWIRE_RUNTIME_DIR=str(r),PIPEWIREAO_MODULE_DIR=str(prefix/'lib/x86_64-linux-gnu/pipewire-ao-0.3'),PIPEWIREAO_SPA_PLUGIN_DIR=str(prefix/'lib/x86_64-linux-gnu/spa-ao-0.2'),PIPEWIREAO_REMOTE='rtc-1c10460020d2',PIPEWIRE_REMOTE='rtc-1c10460020d2',JULIA_DEPOT_PATH=str(old/'julia-depot')+':/home/dgamroth/.julia:',OPENBLAS_NUM_THREADS='1')
processes=[]
logs=[]
def start(name,cmd,config):
 e=env.copy();e['PIPEWIREAO_CONFIG_DIR']=str(config)
 log=(r/(name+'.log')).open('w');logs.append(log)
 p=subprocess.Popen(['taskset','-c','12,14',*cmd],env=e,stdout=log,stderr=subprocess.STDOUT)
 processes.append(p);return p
try:
 core=start('core',[str(prefix/'bin/pipewire-ao'),'-c','daemon.conf'],old/'core')
 for _ in range(100):
  if (r/'rtc-1c10460020d2').exists():break
  if core.poll() is not None:raise RuntimeError('core exited')
  time.sleep(.05)
 fgn=start('fgn',[str(prefix/'bin/pipewire-ao'),'-c','client-host.conf'],old/'fgn')
 project='/tmp/rtc-wireplumber-session-20261007/deployment/julia'
 source=start('parameters',['julia','--startup-file=no','--threads=2,0','--project='+project,'/tmp/rtc-wireplumber-session-20261007/deployment/hil/parameter_source.jl','--config',str(old/'parameters/sources.json'),'--remote',str(r/'rtc-1c10460020d2'),'--bootstrap-node','pipewireao.rtc.bootstrap.parameters','--bootstrap-instance','11007','--control-node','pipewireao.rtc.parameters.probe','--control-instance','11008'],old/'parameters')
 time.sleep(1)
 client=start('connect',['julia','--startup-file=no','--project='+project,'/tmp/rtc-format-connect.jl',str(r/'rtc-1c10460020d2'),str(source.pid)],old/'parameters')
 end=time.monotonic()+90
 while 'Connected' not in (r/'connect.log').read_text():
  if client.poll() is not None or time.monotonic()>end:raise RuntimeError('connect failed')
  time.sleep(.05)
 result=subprocess.run([str(prefix/'bin/pwao-link'),'-o'],env=env,capture_output=True,text=True,check=True)
 print('OUTPUTS',result.stdout,flush=True)
 result=subprocess.run([str(prefix/'bin/pwao-link'),'-i'],env=env,capture_output=True,text=True,check=True)
 print('INPUTS',result.stdout,flush=True)
 subprocess.run([str(prefix/'bin/pwao-link'),'rtc-reconstructor:output_1','revolt-copper-fgn-frame-graph:reconstruct:reconstructor'],env=env,timeout=10,check=True)
 dump=subprocess.run([str(prefix/'bin/pwao-dump')],env=env,capture_output=True,text=True,check=True)
 (r/'registry.json').write_text(dump.stdout)
 end=time.monotonic()+15
 while source.poll() is None and time.monotonic()<end:time.sleep(.05)
 print('PARAMETER_EXIT',source.poll(),flush=True)
 client.wait(timeout=15)
 print('CLIENT_EXIT',client.returncode,flush=True)
finally:
 for p in reversed(processes):
  if p.poll() is None:p.terminate()
 for p in reversed(processes):
  try:p.wait(timeout=10)
  except subprocess.TimeoutExpired:p.kill();p.wait(timeout=5)
 for log in logs:log.close()
 print('EVIDENCE',str(r),flush=True)
 print((r/'parameters.log').read_text()[-5000:],flush=True)
 print((r/'connect.log').read_text()[-2000:],flush=True)
