import json
from pathlib import Path
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

    def make_capture(self,root):
        after=dict(domain=1,generation=1,sequence=1,model_ns=10)
        settings=dict(detector_config=dict(bits=12,exposure_duration_s=5e-9),graph_sha256='graph',wfs_active_sha256='mask')
        mapping=dict(opaque_domain=1,complete_domain=[1]*16)
        startup=dict(**settings,illumination='dark',acquisition_domain_mapping=mapping,capture_settings_sha256='settings',acquisition_generation=1)
        records=[]
        for i in (1,2):
            frame=root/'4'/str(i);frame.mkdir(parents=True);files={}
            names=dict(raw='raw.u16le',slopes='slopes.f32le',flux='flux.f32le',validity='validity.u8')
            for channel,(element,shape,size) in c.CHANNELS.items():
                path=frame/names[channel];path.write_bytes(bytes(size))
                files[channel]=dict(path=path.name,element_type=element,shape=shape,layout='ROW_MAJOR',bytes=size,sha256=c.digest(path))
            records.append(dict(domain=1,generation=1,sequence=i+1,start_model_ns=i*10,duration_ns=5,valid=False,directory=str(i),files=files))
        manifest=dict(version=1,run=1,serial=4,probe=0,stage='dark',profile='classic',illumination='dark',settings=settings,settings_sha256='settings',acquisition_domain_mapping=mapping,frames=2,bytes=2*c.PAYLOAD_BYTES,exposures=records)
        path=root/'4/manifest.json';path.write_text(json.dumps(manifest))
        completion=dict(manifest='4/manifest.json',sha256=c.digest(path),frames=2,bytes=2*c.PAYLOAD_BYTES,metadata_bytes=path.stat().st_size,cursor=dict(domain=1,generation=1,sequence=3,model_ns=25))
        return manifest,completion,after,startup

    def verify(self,root,completion,after,startup):
        return c.verify_capture(root,completion,run=1,serial=4,stage='dark',frames=2,after=after,startup=startup)

    def test_dark_invalid_quality_is_evidence(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);_,completion,after,startup=self.make_capture(root)
            result=self.verify(root,completion,after,startup)
            self.assertTrue(all(not x['valid'] for x in result['exposures']))

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

if __name__=='__main__':unittest.main()
