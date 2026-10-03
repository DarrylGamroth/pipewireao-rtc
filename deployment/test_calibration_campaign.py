import json
from pathlib import Path
import shutil
import socket
import tempfile
import threading
from types import SimpleNamespace
import unittest
from unittest.mock import patch
import calibration_campaign as c


def recipe():
    return dict(version=1, dark_frames=16, training_frames=16, qualification_frames=16,
        seeds=dict(dark=0, training=1, qualification=2, interaction=3), lamp_magnitude=.5,
        candidate_mask=[True]*188, minimum_flux=[2000]*188, adc_upper_rail=4095,
        maximum_reference_residual=.1, reference=[0]*277, amplitudes=[.02]*277,
        frames_per_probe=2, settling=dict(kind='discard_exposures', frames=1),
        request_timeout_ns=20_000_000_000, stage_timeout_seconds=180)


class CampaignTests(unittest.TestCase):
    def test_explicit_recipe_and_wire_precision(self):
        original=recipe(); original['reference'][0]=.123456789
        result=c.validate_recipe(original)
        self.assertNotEqual(result['reference'][0], original['reference'][0])
        self.assertTrue(c.same_figure(result['reference'], [.12345679]+[0]*276))
        self.assertEqual(result['amplitudes'][0],c.wire_float32(.02))

    def test_recipe_rejection(self):
        changes=[('version', True), ('version', 1.0), ('dark_frames',True),('training_frames',1),('qualification_frames',65),
            ('candidate_mask',[False]*188),('minimum_flux',[2000]*187),
            ('maximum_reference_residual',float('nan')),('adc_upper_rail',0),
            ('amplitudes',[1e-99]*277),('reference',[float('inf')]*277),
            ('settling',dict(kind='sleep',seconds=1))]
        for field,value in changes:
            with self.subTest(field=field):
                bad=recipe();bad[field]=value
                with self.assertRaises((ValueError,OverflowError)):c.validate_recipe(bad)
        bad=recipe();bad['seeds']['qualification']=1
        with self.assertRaises(ValueError):c.validate_recipe(bad)
        bad=recipe();bad['unexpected']=True
        with self.assertRaises(ValueError):c.validate_recipe(bad)

    def make_capture(self,root,profile='classic'):
        channels, payload_bytes = c.capture_contract(profile)
        after=dict(domain=1,generation=1,sequence=1,model_ns=10)
        settings=dict(detector_config=dict(bits=12,exposure_duration_s=5e-9),graph_sha256='graph',wfs_active_sha256='mask')
        mapping=dict(opaque_domain=1,complete_domain=[1]*16)
        startup=dict(**settings,profile=profile,illumination='dark',acquisition_domain_mapping=mapping,capture_settings_sha256='settings',acquisition_generation=1)
        records=[]
        for i in (1,2):
            frame=root/'4'/str(i);frame.mkdir(parents=True);files={}
            for channel,(element,shape,size) in channels.items():
                path=frame/c.CAPTURE_FILENAMES[channel];path.write_bytes(bytes(size))
                files[channel]=dict(path=path.name,element_type=element,shape=shape,layout='ROW_MAJOR',bytes=size,sha256=c.digest(path))
            records.append(dict(domain=1,generation=1,sequence=i+1,start_model_ns=i*10,duration_ns=5,valid=False,directory=str(i),files=files))
        manifest=dict(version=1,run=1,serial=4,probe=0,stage='dark',profile=profile,illumination='dark',settings=settings,settings_sha256='settings',acquisition_domain_mapping=mapping,frames=2,bytes=2*payload_bytes,exposures=records)
        path=root/'4/manifest.json';path.write_text(json.dumps(manifest))
        completion=dict(manifest='4/manifest.json',sha256=c.digest(path),frames=2,bytes=2*payload_bytes,metadata_bytes=path.stat().st_size,cursor=dict(domain=1,generation=1,sequence=3,model_ns=25))
        return manifest,completion,after,startup

    def verify(self,root,completion,after,startup):
        return c.verify_capture(root,completion,run=1,serial=4,stage='dark',frames=2,after=after,startup=startup)

    def test_dark_invalid_quality_is_evidence(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);_,completion,after,startup=self.make_capture(root)
            result=self.verify(root,completion,after,startup)
            self.assertTrue(all(not x['valid'] for x in result['exposures']))

    def test_copper_three_channel_capture(self):
        channels, size = c.capture_contract('copper')
        self.assertEqual(size, 22596)
        self.assertEqual(channels, dict(raw=('U16_LE',[64,64],8192),
            pixels=('F32_LE',[4,900],14400), intensity=('F32_LE',[1],4)))
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);_,completion,after,startup=self.make_capture(root,'copper')
            result=c.verify_capture(root,completion,run=1,serial=4,stage='dark',
                frames=2,after=after,startup=startup,profile='copper')
            self.assertEqual(result['profile'],'copper')
            self.assertEqual(result['bytes'],45192)
            with self.assertRaises(ValueError):self.verify(root,completion,after,startup)

    def test_capture_profile_and_channels_cannot_be_selected_by_manifest(self):
        for change in ('profile','startup_profile','missing_startup_profile','extra_measurement','missing_intensity','wrong_shape','payload'):
            with self.subTest(change=change),tempfile.TemporaryDirectory() as tmp:
                root=Path(tmp);manifest,completion,after,startup=self.make_capture(root,'copper')
                if change=='profile':manifest['profile']='classic'
                elif change=='startup_profile':startup['profile']='classic'
                elif change=='missing_startup_profile':del startup['profile']
                elif change=='extra_measurement':manifest['exposures'][0]['files']['extra']={}
                elif change=='missing_intensity':del manifest['exposures'][0]['files']['intensity']
                elif change=='wrong_shape':manifest['exposures'][0]['files']['pixels']['shape']=[3600]
                else:(root/'4/1/pixels.f32le').write_bytes(b'changed')
                path=root/'4/manifest.json';path.write_text(json.dumps(manifest))
                completion['sha256']=c.digest(path);completion['metadata_bytes']=path.stat().st_size
                with self.assertRaises(ValueError):c.verify_capture(root,completion,run=1,serial=4,
                    stage='dark',frames=2,after=after,startup=startup,profile='copper')

    def test_unsupported_capture_profile_rejects_before_read(self):
        for profile in ('unknown',None,[],True):
            with self.subTest(profile=profile),patch.object(Path,'read_bytes',side_effect=AssertionError('unexpected read')):
                with self.assertRaises(ValueError):c.capture_contract(profile)

    def test_matching_hashes_do_not_override_association(self):
        for change in ('probe','illumination','settings','first','last'):
            with self.subTest(change=change), tempfile.TemporaryDirectory() as tmp:
                root=Path(tmp);manifest,completion,after,startup=self.make_capture(root)
                if change=='probe':manifest['probe']=1
                elif change=='illumination':manifest['illumination']='lamp'
                elif change=='settings':manifest['settings']={**manifest['settings'],'graph_sha256':'different'}
                elif change=='first':after['sequence']=0
                else:completion['cursor']['sequence']=4
                path=root/'4/manifest.json';path.write_text(json.dumps(manifest))
                completion['sha256']=c.digest(path);completion['metadata_bytes']=path.stat().st_size
                with self.assertRaises(ValueError):self.verify(root,completion,after,startup)

    def test_bound_checked_before_read(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);_,completion,after,startup=self.make_capture(root)
            completion['metadata_bytes']+=1
            with patch.object(Path,'read_bytes',side_effect=AssertionError('unexpected read')),self.assertRaises(ValueError):
                self.verify(root,completion,after,startup)

    def fake_endpoint(self,result,wrong_run=False):
        client,server=socket.socketpair();endpoint=object.__new__(c.Endpoint)
        endpoint.socket,endpoint.run,endpoint.serial,endpoint.timeout_ns=client,1,0,1_000_000_000
        endpoint.records,endpoint.can_restore=[],False
        def respond():
            with server:
                request=json.loads(server.recv(16384))
                reply=dict(version=1,run=2 if wrong_run else request['run'],serial=request['serial'],result=result)
                server.sendall((json.dumps(reply)+'\n').encode())
        thread=threading.Thread(target=respond);thread.start();return endpoint,thread

    def test_recovery_only_for_known_rejection(self):
        for reason,allowed in (('invalid_evidence',True),('endpoint',False)):
            endpoint,thread=self.fake_endpoint(dict(kind='failed',reason=reason))
            try:
                with self.assertRaises(ValueError):endpoint.request(dict(kind='hold'),'held')
                self.assertEqual(endpoint.can_restore,allowed)
            finally:endpoint.close();thread.join()
        endpoint,thread=self.fake_endpoint(dict(kind='released'),True)
        try:
            with self.assertRaises(ValueError):endpoint.request(dict(kind='release'),'released')
            self.assertFalse(endpoint.can_restore)
        finally:endpoint.close();thread.join()

    def test_late_reply_not_accepted(self):
        endpoint,thread=self.fake_endpoint(dict(kind='released'))
        try:
            with patch.object(c.time,'monotonic',side_effect=[0.,.1,.2,1.01]),self.assertRaises(TimeoutError):
                endpoint.request(dict(kind='release'),'released')
            self.assertFalse(endpoint.can_restore)
        finally:endpoint.close();thread.join()

    def test_late_rejection_cannot_authorize_recovery(self):
        endpoint,thread=self.fake_endpoint(dict(kind='failed',reason='invalid_evidence'))
        try:
            with patch.object(c.time,'monotonic',side_effect=[0.,.1,.2,.3,1.01]),self.assertRaises(TimeoutError):
                endpoint.request(dict(kind='hold'),'held')
            self.assertFalse(endpoint.can_restore)
        finally:endpoint.close();thread.join()

    def test_foreign_running_state_never_admits(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);(root/'state.json').write_text(json.dumps(dict(pid=11,phase='running')))
            process=SimpleNamespace(pid=10,poll=lambda:None)
            with self.assertRaisesRegex(RuntimeError,'different launcher'):
                c.wait_state(root,process,1,lambda state:True)

    def test_stage_timing_boundaries_and_units(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);package=root/'package';package.mkdir()
            output=root/'evidence';runtime=root/'runtime';instance=runtime/'owner'
            (package/'provenance.json').write_text(json.dumps(dict(profile='classic')))
            ready=dict(socket=str(instance/'calibration.sock'))
            def ready_state(*args,**kwargs):
                instance.mkdir(parents=True);(instance/'captured').mkdir()
                (instance/'simulator-result.json').write_text(json.dumps(dict(illumination='dark')))
                return ready
            class Process:
                pid=123
                returncode=None
                def poll(self):return self.returncode
                def wait(self,timeout=None):
                    shutil.rmtree(instance)
                    (runtime/'state.json').write_text(json.dumps(dict(phase='stopped')))
                    self.returncode=0
                def terminate(self):self.returncode=-15
                def kill(self):self.returncode=-9
            class Client:
                def __init__(self,*args):self.records=[];self.can_restore=False
                def request(self,action,expected):
                    kind=action['kind'];cursor=dict(domain=1,generation=1,sequence=1,model_ns=1)
                    if kind=='hold':return dict(cursor=cursor)
                    if kind=='adopt':return dict(figure=action['figure'],clipped=False,cursor=cursor)
                    if kind=='restore':return dict(figure=action['figure'],clipped=False)
                    if kind=='settle':return dict(cursor=cursor)
                    if kind=='capture':return dict(frames=1)
                    if kind=='release':return dict(kind='released')
                    raise AssertionError(kind)
                def close(self):pass
            class Response:
                returncode=0;stderr=''
                def check_returncode(self):pass
            def control(argv,**kwargs):
                response=Response()
                response.stdout=json.dumps(dict(ok=True,state='Ready' if argv[-1]=='session-stop' else 'Stopped'))
                return response
            recipe_value=recipe()
            with patch.object(c.subprocess,'Popen',return_value=Process()), \
                 patch.object(c.subprocess,'run',side_effect=control), \
                 patch.object(c,'Endpoint',Client), \
                 patch.object(c,'wait_state',side_effect=ready_state), \
                 patch.object(c,'verify_capture'), \
                 patch.object(c.time,'perf_counter_ns',side_effect=[0,10,20,30,40,50,60]):
                result=c.run_stage(package,output,runtime,recipe_value,'dark',frames=1)
            self.assertEqual(result['timing_ns'],dict(startup_readiness=10,acquisition=10,
                public_shutdown=10,total_stage=60))
            self.assertEqual(result['timing_confirmed'],dict(startup_readiness=True,
                acquisition=True,public_shutdown=True))
            stored=json.loads((output/'stage-result.json').read_text())
            self.assertEqual(stored['timing_ns'],result['timing_ns'])

    def test_campaign_total_timing_is_persisted(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);aoc=root/'aoc';(aoc/'src/reference_frames').mkdir(parents=True)
            (aoc/'src/reference_frames/reference_frames.jl').write_text('')
            recipe_path=root/'recipe.json';recipe_path.write_text(json.dumps(recipe()))
            output=root/'campaign';base=root/'base';base.mkdir()
            args=SimpleNamespace(recipe=recipe_path,output=output,aoc_source=aoc,
                base_package=base,pipewire_prefix=root/'prefix',rtc_binary='rtc',
                calibration_binary='cal',runtime=root/'runtime',julia='julia')
            def fake_stage_base(base_path,target,*args,**kwargs):
                target.mkdir(parents=True);return target
            def fake_run_stage(package,evidence,runtime,recipe_value,stage,*,frames=None):
                evidence.mkdir(parents=True);return {}
            class Response:
                returncode=0;stdout='';stderr=''
                def check_returncode(self):pass
            def analysis(argv,**kwargs):
                mode=argv[-3]
                if mode=='dark':(output/'measured-background.f32le').write_bytes(bytes(495616))
                if mode=='training':
                    (output/'measured-reference-slopes.f32le').write_bytes(bytes(1504))
                    (output/'measured-active.u8').write_bytes(bytes(188))
                return Response()
            with patch.object(c,'stage_base',side_effect=fake_stage_base), \
                 patch.object(c.export_calibration,'export'), \
                 patch.object(c,'run_stage',side_effect=fake_run_stage), \
                 patch.object(c.subprocess,'run',side_effect=analysis), \
                 patch.object(c.time,'perf_counter_ns',side_effect=[100,450]):
                result_path=c.campaign(args)
            stored=json.loads(result_path.read_text())
            self.assertEqual(stored['timing_ns'],dict(total_campaign=350))

if __name__=='__main__':unittest.main()
