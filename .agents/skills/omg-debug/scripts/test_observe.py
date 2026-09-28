import contextlib
import csv
import io
import json
import pathlib
import tempfile
import unittest
from types import SimpleNamespace

import observe


class ObserveTests(unittest.TestCase):
    def test_footprint_and_cpu_units(self):
        text = """omg [42]: Footprint: 568 MB
 157 MB 0 B 0 B 31 Malloc Small
 108 MB 0 B 0 B 12 Malloc Large
 117 MB 0 B 0 B 59 IOSurface
  50 MB 0 B 0 B 308 Owned physical footprint (unmapped) (graphics)
  76 MB 0 B 0 B 372 IOAccelerator (graphics)
 568 MB 80 MB 27 MB 10900 TOTAL
"""
        sample = observe.parse_footprint(text)
        self.assertEqual(sample['footprint_mb'], 568)
        self.assertEqual(sample['iosurface_regions'], 59)
        self.assertEqual(sample['graphics_unmapped_mb'], 50)
        self.assertEqual(observe.cpu_seconds('2:03.50'), 123.5)
        self.assertEqual(observe.cpu_seconds('1-02:03:04.5'), 93784.5)
        with self.assertRaises(ValueError):
            observe.parse_footprint('no TOTAL')

    def test_rotated_events_sort_and_report_current_run_only(self):
        with tempfile.TemporaryDirectory() as root:
            directory = pathlib.Path(root)
            directory.joinpath('events.previous.jsonl').write_text('\n'.join(json.dumps(e) for e in [
                {'time': '2026-09-28T12:05:00Z', 'event': 'split_added', 'surfaces': 2, 'tabs': 1, 'windows': 1},
                {'time': '2026-09-28T11:00:00Z', 'event': 'start', 'surfaces': 1, 'tabs': 1, 'windows': 1},
            ]))
            directory.joinpath('events.jsonl').write_text('\n'.join(json.dumps(e) for e in [
                {'time': '2026-09-28T12:02:00Z', 'event': 'start', 'surfaces': 1, 'tabs': 1, 'windows': 1},
                {'time': '2026-09-28T12:06:00Z', 'event': 'split_removed', 'surfaces': 1, 'tabs': 1, 'windows': 1},
                {'time': '2026-09-28T11:50:00Z', 'event': 'tab_created', 'surfaces': 1, 'tabs': 1, 'windows': 1},
            ]))
            csv_path = directory / 'system-samples.csv'
            with csv_path.open('w', newline='') as file:
                writer = csv.DictWriter(file, fieldnames=observe.FIELDS)
                writer.writeheader()
                for minute, size in [(0, 400), (3, 500), (5, 440), (6, 420)]:
                    writer.writerow({'time': f'2026-09-28T12:{minute:02}:00+00:00',
                                     'pid': 42, 'footprint_mb': size, 'malloc_small_mb': 100,
                                     'malloc_large_mb': 100, 'iosurface_mb': 50,
                                     'iosurface_regions': 5, 'graphics_unmapped_mb': 20,
                                     'ioaccelerator_mb': 10})
            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                observe.report(SimpleNamespace(csv=csv_path, events_dir=directory, max_events=40))
            report = output.getvalue()
            self.assertIn('split_added', report)
            self.assertIn('split_removed', report)
            self.assertNotIn('tab_created', report)
            self.assertIn('baseline: 2026-09-28T12:03:00+00:00', report)
            self.assertIn('peak: 2026-09-28T12:03:00+00:00', report)

    def test_rejects_naive_timestamp(self):
        with self.assertRaises(ValueError):
            observe.timestamp('2026-09-28T12:00:00')

    def test_report_rejects_mixed_processes(self):
        with tempfile.TemporaryDirectory() as root:
            path = pathlib.Path(root) / 'system-samples.csv'
            with path.open('w', newline='') as file:
                writer = csv.DictWriter(file, fieldnames=observe.FIELDS)
                writer.writeheader()
                for pid in (42, 43):
                    writer.writerow({'time': '2026-09-28T12:00:00Z',
                                     'pid': pid, 'footprint_mb': 500})
            with self.assertRaisesRegex(ValueError, 'multiple processes'):
                observe.report(SimpleNamespace(csv=path, events_dir=path.parent, max_events=40))


if __name__ == '__main__':
    unittest.main()
