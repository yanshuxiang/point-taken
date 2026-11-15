import sys, unittest
from pathlib import Path
from unittest.mock import patch
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
import transcribe as T
class SegmentTest(unittest.TestCase):
 def test_full_text_and_original_timeline(self):
  e=T.NoteEngine();e.backend=object();e.name='fixture';e.model_id='fixture-model'
  rows=[(51.2,55.3,'最后的补充',None,'zh'),(0.9,8.8,'背景说明',None,'zh'),(27.6,36.0,'按钮修改',None,'zh')]
  with patch.object(T,'read_wav',return_value=T.np.zeros(60*T.SR)), patch.object(e,'load',return_value=e), patch.object(T,'transcribe_track',return_value=(rows,20,0)),patch.object(T,'bias',return_value=False),patch.object(T,'voiceprint_settings',return_value=(True,.5)),patch.object(T.Voiceprint,'gate',side_effect=AssertionError('must retain background voices')):
   r=e.note(Path('fixture.wav'),model_id='fixture-model',include_segments=True)
  self.assertEqual(r['text'],'背景说明按钮修改最后的补充')
  self.assertEqual([s['start'] for s in r['segments']],[.9,27.6,51.2])
  self.assertEqual(r['model'],'fixture-model')
 def test_doubao_sentence_times_and_incomplete_timing(self):
  from argparse import Namespace
  from unittest.mock import Mock
  with patch.object(T, 'api_key', return_value='fixture'):
   backend=T.Volcengine(Namespace(language=None))
  backend.utterances=True
  session=Mock()
  session.request_id='fixture-request'
  session.finish.return_value='Background. Final note.'
  session.utterances=[{'start_time':900,'end_time':1800,'text':'Background.'}, {'start_time':5100,'end_time':5800,'text':'Final note.'}]
  with patch.object(backend,'open',return_value=session):
   result=backend.transcribe(T.np.zeros(6*T.SR))
   self.assertEqual(result,[(.9,1.8,'Background.'),(5.1,5.8,'Final note.')])
   session.utterances=session.utterances[:1]
   self.assertEqual(backend.transcribe(T.np.zeros(6*T.SR)),[(0.,6.,'Background. Final note.')])
if __name__=='__main__':unittest.main()
