"""Checks that measurement summaries reject incomplete or vacuous traces."""
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('measure_native_scroll', Path(__file__).with_name('measure-native-scroll.py'))
measurement = importlib.util.module_from_spec(spec)
spec.loader.exec_module(measurement)


class SummaryTests(unittest.TestCase):
    def trace(self):
        return [dict(kind='start', time=0),
                dict(kind='tick', time=.1, y=10, pending=2),
                dict(kind='frame', time=.2, surface=1, presented=1, cpu_us=1000),
                dict(kind='tick', time=.9, y=90, pending=1),
                dict(kind='frame', time=.9, surface=1, presented=1, cpu_us=2000),
                dict(kind='end', time=1)]

    def test_intervals_include_start_and_end_stalls(self):
        trace = self.trace()
        trace[2]['time'] = .8
        result = measurement.summarize(trace)
        self.assertEqual(result['submission_gap_max_ms'], 800)
        self.assertEqual(result['pending_tiles_max'], 2)
        self.assertEqual(result['draw_cpu_p95_ms'], 2)

    def test_incomplete_or_stalled_trace_is_not_a_measurement(self):
        with self.assertRaises(ValueError): measurement.summarize(self.trace()[:-1])
        trace = self.trace()
        trace[3]['y'] = 10
        with self.assertRaises(ValueError): measurement.summarize(trace)

    def test_occlusion_cannot_be_counted_as_presented(self):
        trace = self.trace()
        trace[2]['presented'] = 0
        with self.assertRaises(ValueError): measurement.summarize(trace)


if __name__ == '__main__': unittest.main()
