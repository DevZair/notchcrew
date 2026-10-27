import copy
import os
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch
import json
from collector import Collector

class InboxSchemaTests(unittest.TestCase):
    def test_bad_entries_do_not_hide_live_neighbour_or_create_answers(self):
        with tempfile.TemporaryDirectory() as tmp:
            home=Path(tmp)
            inbox=home/'Library/Application Support/NotchCrew/requests'
            inbox.mkdir(parents=True,mode=0o700)
            valid={'id':'b'*32,'pid':os.getpid(),'sessionId':'fixture','role':'planner','kind':'permission','input':{'command':'printf test'},'questions':[],'tool':'Bash','project':'Fixture','createdAt':90,'expiresAt':200}
            good=inbox/(valid['id']+'.request.json')
            good.write_text(json.dumps(valid));good.chmod(0o600)
            reader=Collector(home)
            cases=[('pid',10**100),('pid',True),('pid',-1),('input',[]),('input',{'command':[]}),('sessionId',[]),('role',{}),('expiresAt',float('nan')),('expiresAt',float('inf')),('expiresAt',True),('expiresAt',10**1000),('questions','bad'),('kind','unrecognised')]
            for key,value in cases:
                with self.subTest(key=key,value=str(value)[:20]):
                    bad=copy.deepcopy(valid);bad['id']='a'*32;bad[key]=value
                    p=inbox/(bad['id']+'.request.json');p.write_text(json.dumps(bad));p.chmod(0o600)
                    found=reader.pending_requests([],100)
                    self.assertEqual([r['id'] for r in found],[valid['id']])
                    self.assertFalse(list(inbox.glob('*.answer.json')))

if __name__=='__main__':unittest.main()
