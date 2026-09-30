import unittest
from classic_placement import check_loop

class PlacementTests(unittest.TestCase):
    def test_exact_loop_contract(self):
        thread={'name':'rtc-data-loop','affinity':[0],'scheduler':{'policy':'fifo','priority':83}}
        snapshot={'threads':[thread]}
        check_loop(snapshot,'rtc-data-loop',0,83)
        for field,value in [('affinity',[0,2]),('scheduler',{'policy':'other','priority':0})]:
            changed=dict(thread);changed[field]=value
            with self.assertRaises(RuntimeError):check_loop({'threads':[changed]},'rtc-data-loop',0,83)
        with self.assertRaises(RuntimeError):check_loop({'threads':[thread,thread]},'rtc-data-loop',0,83)
        with self.assertRaises(RuntimeError):check_loop({'threads':[]},'rtc-data-loop',0,83)
