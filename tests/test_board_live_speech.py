"""Selected annotation model must produce live text before recording stops; no Apple substitute."""
import json
import os
from pathlib import Path
import sys
import tempfile
import threading
import time
import unittest
from unittest import mock
ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'scripts'))
try:
 import board_live as L
except ModuleNotFoundError:
 L=None

class LiveSpeechTest(unittest.TestCase):
 def test_selected_model_emits_live_text_before_stop(self):
  self.assertIsNotNone(L,'No selected-model live path exists; annotation always uses Apple')
  events=[];partial=threading.Event()
  class Session:
   request_id='fixture-live-request'
   text=''
   utterances=[]
   def __init__(self,update):self.update=update
   def feed(self,data):
    self.text='背景说明和按钮修改';self.update(self.text,False);partial.set()
   def finish(self,wait=10):return self.text
   def close(self):pass
  class Backend:
   def __init__(self):self.model='seed-asr-2.0';self.utterances=True
   def open(self,**kwargs):
    self.asserted=kwargs
    return Session(kwargs['on_update'])
  with tempfile.TemporaryDirectory() as td:
   root=Path(td);(root/'audio.pcm').write_bytes(bytes(6400))
   backend=Backend()
   def run():L.stream(root,'volcengine-seedasr',backend,events.append,window_seconds=1)
   thread=threading.Thread(target=run);thread.start()
   self.assertTrue(partial.wait(2),'No live result before stop')
   self.assertTrue(any(e.get('event')=='partial' and e.get('model')=='volcengine-seedasr' for e in events))
   (root/'stop').touch();thread.join(3)
   self.assertFalse(thread.is_alive())
   self.assertEqual(events[-1]['event'],'done')
   self.assertEqual(events[-2]['text'],'背景说明和按钮修改')
   self.assertTrue(all(e.get('model')=='volcengine-seedasr' for e in events))
   self.assertEqual(backend.asserted['url'],L.T.VOLC_LIVE_URL)
 def test_configured_nonapple_never_requests_apple_permission(self):
  source=(ROOT/'app/macos/Sources/PointTakenApp/Capture/Board.swift').read_text(encoding="utf-8")
  start=source[source.index('    func start(locale: String, directory: URL)'):source.index('    private func beginAudio()')]
  self.assertIn('self.finalModel == BoardTranscription.apple',start)
  self.assertLess(start.index('self.finalModel == BoardTranscription.apple'),start.index('SFSpeechRecognizer.requestAuthorization'))


class LiveLifecycleTest(unittest.TestCase):
 def test_pause_resume_keeps_both_segments_and_audio_offsets(self):
  self.assertIsNotNone(L)
  events=[];first=threading.Event();paused=threading.Event();second=threading.Event()
  class Session:
   utterances=[]
   def __init__(self,index,update):self.request_id=f'request-{index}';self.index=index;self.update=update;self.text=f'第{index}段'
   def feed(self,data):self.update(self.text,False)
   def finish(self,wait=10):return self.text
   def close(self):pass
  class Backend:
   count=0
   def open(self,**kwargs):
    self.count+=1
    return Session(self.count,kwargs['on_update'])
  def send(event):
   events.append(event)
   if event['event']=='partial':(first if event['part']==0 else second).set()
   if event['event']=='segment' and event['part']==0:paused.set()
  with tempfile.TemporaryDirectory() as td:
   root=Path(td);audio=root/'audio.pcm';audio.write_bytes(bytes(6400))
   t=threading.Thread(target=lambda:L.stream(root,'volcengine-seedasr',Backend(),send));t.start()
   self.assertTrue(first.wait(2))
   (root/'paused').touch();self.assertTrue(paused.wait(2))
   with audio.open('ab') as f:f.write(bytes(6400))
   (root/'paused').unlink(missing_ok=True)
   self.assertTrue(second.wait(2))
   (root/'stop').touch();t.join(3);self.assertFalse(t.is_alive())
   segments=[e for e in events if e['event']=='segment']
   self.assertEqual([e['text'] for e in segments],['第1段','第2段'])
   self.assertAlmostEqual(segments[1]['start'],.2)
   self.assertAlmostEqual(segments[1]['end'],.4)
 def test_api_refusal_does_not_switch_to_apple(self):
  self.assertIsNotNone(L)
  backend=mock.Mock();backend.open.side_effect=L.T.Fail('refused','auth')
  with tempfile.TemporaryDirectory() as td:
   root=Path(td);(root/'audio.pcm').write_bytes(bytes(6400));events=[]
   with self.assertRaises(L.T.Fail) as result:
    L.stream(root,'volcengine-seedasr',backend,events.append)
   self.assertEqual(result.exception.code,'auth')
   self.assertFalse(events)
 def test_nonstreaming_model_updates_before_stop_with_same_selection(self):
  self.assertIsNotNone(L)
  events=[];seen=threading.Event();models=[]
  class Engine:
   name='fixture-local'
   def load(self,language,model):models.append(model)
   def note(self,wav,model_id):
    models.append(model_id)
    return {'model':model_id,'text':'本地模型字幕'}
  def send(event):
   events.append(event)
   if event['event']=='partial':seen.set()
  with tempfile.TemporaryDirectory() as td, mock.patch.object(L.T,'NoteEngine',Engine):
   root=Path(td);(root/'audio.pcm').write_bytes(bytes(6400))
   t=threading.Thread(target=lambda:L.incremental(root,'selected-local',send,interval=.1));t.start()
   self.assertTrue(seen.wait(2))
   (root/'stop').touch();t.join(3);self.assertFalse(t.is_alive())
   self.assertTrue(all(m=='selected-local' for m in models))
   self.assertEqual(events[-1]['event'],'done')

if __name__=='__main__':unittest.main()
