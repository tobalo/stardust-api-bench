"""Storage accounting regressions: python3 -m unittest discover -s bench -p 'test_*.py'."""
import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

import report

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("measure", ROOT / "seed/measure.py")
measure = importlib.util.module_from_spec(spec)
spec.loader.exec_module(measure)


def sample(t, allocated, written, **changes):
    row = {"t": str(t), "db_id": "1:2", "svc_pid": "100", "svc_start_ticks": "42",
           "db_apparent_bytes": str(2**30), "db_allocated_bytes": str(allocated),
           "svc_write_bytes": str(written), "svc_cancelled_write_bytes": "0"}
    row.update(changes)
    return row


class StorageTests(unittest.TestCase):
    def test_rewrites_are_not_growth(self):
        rows = [sample(10, 4096, 0), sample(20, 4096, 10 * 2**30)]
        self.assertEqual(report.storage_delta(rows, "db_apparent_bytes"), 0)
        self.assertEqual(report.storage_delta(rows, "db_allocated_bytes"), 0)
        self.assertEqual(report.storage_delta(rows, "svc_write_bytes"), 10 * 2**30)

    def test_reset_and_missing_data_are_not_negative_growth(self):
        for change in ({"db_id": "1:3"}, {"db_id": ""},
                       {"svc_start_ticks": "99"}, {"db_allocated_bytes": ""}):
            rows = [sample(10, 8192, 100), sample(20, 4096, 50, **change)]
            self.assertIsNone(report.storage_delta(rows, "db_allocated_bytes"))
        self.assertIsNone(report.storage_delta([sample(10, 8192, 100), sample(20, 4096, 50)], "svc_write_bytes"))

    def test_file_allocation_can_shrink_and_survive_process_exit(self):
        rows = [sample(10, 8192, 100), sample(20, 4096, 0, svc_pid="0", svc_start_ticks="", svc_write_bytes="")]
        self.assertEqual(report.storage_delta(rows, "db_allocated_bytes"), -4096)
        self.assertIsNone(report.storage_delta(rows, "svc_write_bytes"))

    def test_restart_in_middle_invalidates_endpoints(self):
        rows = [sample(10, 4096, 0), sample(15, 4096, 0, svc_start_ticks="99"), sample(20, 8192, 100)]
        self.assertIsNone(report.storage_delta(rows, "db_allocated_bytes"))

    def test_run_requires_boundary_coverage(self):
        rows = [sample(11, 4096, 0), sample(19, 8192, 100)]
        self.assertEqual(report.storage_window(rows, 10, 20), rows)
        self.assertEqual(report.storage_window(rows, 1, 20), [])
        self.assertEqual(report.storage_window(rows, 10, 30), [])
        self.assertEqual(report.storage_window(rows, 10, None), [])

    def test_sparse_file_size_and_tsv_rows(self):
        with tempfile.TemporaryDirectory() as tmp:
            p = Path(tmp) / "sparse"
            with p.open("wb") as f:
                f.truncate(32 * 2**20)
            facts = measure.file_metrics(p)
            self.assertEqual(facts["apparent_bytes"], 32 * 2**20)
            self.assertLess(facts["allocated_bytes"], facts["apparent_bytes"])
            p.write_bytes(b"one\ntwo")
            self.assertEqual(measure.file_metrics(p, rows=True)["rows"], 2)

    def test_import_receipt_preserves_success_and_failure(self):
        for code in (0, 7):
            with self.subTest(code=code), tempfile.TemporaryDirectory() as tmp:
                folder = Path(tmp)
                for name in ("users.tsv", "posts.tsv", "likes.tsv"):
                    (folder / name).write_text("1\tdata\n")
                importer = folder / "import"
                importer.write_text(f'#!/bin/sh\nprintf data > "$2"\nexit {code}\n')
                importer.chmod(0o755)
                proc = subprocess.run([sys.executable, str(ROOT / "seed/measure.py"), str(folder),
                                       str(folder / "feed.stardust"), str(importer)], capture_output=True, text=True)
                self.assertEqual(proc.returncode, code, proc.stderr)
                record = json.loads((folder / "seed-metrics.json").read_text())
                self.assertEqual(record["tsv_bytes"], 21)
                self.assertEqual(record["import"]["exit_code"], code)
                self.assertGreater(record["import"]["peak_rss_bytes"], 0)
                self.assertEqual(record["database"]["apparent_bytes"], 4)
                self.assertEqual("sha256" in record["database"], code == 0)

    def test_legacy_report_does_not_invent_storage_measurements(self):
        with tempfile.TemporaryDirectory() as tmp:
            page = report.session_report(report.load_session(tmp))
            self.assertIn("Not collected in this session", page)
            self.assertNotIn("session allocation change", page)

    def test_session_baseline_is_run_copy_not_seed_or_previous_run(self):
        with tempfile.TemporaryDirectory() as tmp:
            s = report.load_session(tmp)
            s["storage"] = [sample(1, 1000000, 0, phase="before_reset", db_id="1:1"),
                            sample(10, 4096, 0, phase="session_start", seed_allocated_bytes="1000000"),
                            sample(20, 4096, 2**30, phase="session_end")]
            page = report.storage_report(s, [])
            self.assertIn("+0.00 MiB", page)
            self.assertIn("1.000 GiB", page)
            self.assertNotIn("Session growth unavailable", page)


if __name__ == "__main__":
    unittest.main()
