"""Opt-in AppKit regression: POINT_TAKEN_E2E=1 python3 -m unittest tests.test_board_startup.

Build the macOS release executable first. Opens only a diagnostic window; no mic, screenshots, or user records.
"""
import json
import os
from pathlib import Path
import subprocess
import sys
import unittest


ROOT = Path(__file__).resolve().parent.parent
BIN = ROOT / "app/macos/.build/release/point-taken"


@unittest.skipUnless(sys.platform == "darwin" and os.environ.get("POINT_TAKEN_E2E") == "1",
                     "opt-in: POINT_TAKEN_E2E=1 on macOS")
class BoardStartup(unittest.TestCase):
    def test_new_record_retention_and_temporal_references(self):
        result = subprocess.run([str(BIN), "--board-evidence-check"],
                                env=dict(os.environ, POINT_TAKEN_BOARD_HOME="1"),
                                capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        events = [json.loads(line) for line in result.stdout.splitlines() if line.startswith("{")]
        event = next(e for e in events if e.get("event") == "board_evidence_check")
        self.assertTrue(event["ok"], event)
        self.assertGreaterEqual(len(event["checks"]), 20)

    def test_passive_messages_and_delivery_follow_scope(self):
        result = subprocess.run([str(BIN), "--board-scope-check"],
                                env=dict(os.environ, POINT_TAKEN_BOARD_HOME="1"),
                                capture_output=True, text=True, timeout=20)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        events = [json.loads(line) for line in result.stdout.splitlines() if line.startswith("{")]
        event = next(e for e in events if e.get("event") == "board_scope_check")
        self.assertTrue(event["ok"], event)

    def test_review_editing_focus_and_full_transcript(self):
        result = subprocess.run([str(BIN), "--board-workflow-check"],
                                capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        events = [json.loads(line) for line in result.stdout.splitlines() if line.startswith("{")]
        event = next(e for e in events if e.get("event") == "board_workflow_check")
        self.assertTrue(event["ok"], event)
        self.assertGreaterEqual(len(event["checks"]), 8)

    def test_background_and_final_transcript_reach_delivery(self):
        result = subprocess.run([str(BIN), "--board-retention-check"],
                                capture_output=True, text=True, timeout=20)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        events = [json.loads(line) for line in result.stdout.splitlines() if line.startswith("{")]
        event = next(e for e in events if e.get("event") == "board_retention_check")
        self.assertGreaterEqual(len(event["checks"]), 8, event)
        self.assertTrue(event["ok"], event)

    def test_capsule_content_stays_inside_window(self):
        self.assertTrue(BIN.is_file(), "Build the macOS release executable first")
        result = subprocess.run([str(BIN), "--board-startup-check"],
                                capture_output=True, text=True, timeout=20)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        events = [json.loads(line) for line in result.stdout.splitlines() if line.startswith("{")]
        event = next(e for e in events if e.get("event") == "board_startup_check")
        self.assertTrue(event["ok"], event)
        self.assertEqual(set(event["checks"]), {"initial", "same_size_refresh_0", "same_size_refresh_1",
                                                "same_size_refresh_2", "permission_warning", "compact", "message",
                                                "transparent_margin", "warning_button_clickable", "settings_command_q",
                                                "settings_command_h", "hidden_stays_hidden", "keyboard_released",
                                                "capsule_cannot_take_focus", "recording_does_not_activate_app",
                                                "drawing_cannot_take_focus", "normal_mode_passes_clicks", "capsule_control_works", "expanded_controls_fit"})
        self.assertTrue(all(event["checks"].values()), event)


if __name__ == "__main__":
    unittest.main()
