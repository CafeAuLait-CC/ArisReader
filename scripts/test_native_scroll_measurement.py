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

    def test_reaching_the_end_early_does_not_measure_idle_time_as_scrolling(self):
        with self.assertRaises(ValueError): measurement.summarize(self.trace(), expected_distance=1000)

    def test_occlusion_cannot_be_counted_as_presented(self):
        trace = self.trace()
        trace[2]['presented'] = 0
        with self.assertRaises(ValueError): measurement.summarize(trace)

    def presentation_trace(self):
        trace = self.trace()
        trace[2].update(sequence=1, y=10)
        trace[4].update(sequence=2, y=90)
        # Callback arrival order differs from presentation order.
        trace.extend([dict(kind='presentation', time=.95, callback_time=1.2, surface=1, sequence=2, y=90),
                      dict(kind='presentation', time=.25, callback_time=1.3, surface=1, sequence=1, y=10)])
        return trace

    def test_actual_presentation_uses_host_times_and_full_window(self):
        result = measurement.summarize(self.presentation_trace())
        self.assertEqual(result['presented_fps'], 2)
        self.assertEqual(result['presentation_gap_max_ms'], 700)
        self.assertEqual(result['motion_presented_frames'], 2)
        self.assertEqual(result['presentation_measurement'], 'complete')

    def test_missing_callback_is_unknown_and_never_claims_fps_or_drop(self):
        result = measurement.summarize(self.presentation_trace()[:-1])
        self.assertEqual(result['presentation_callbacks_missing'], 1)
        self.assertEqual(result['presentation_drops_reported'], 0)
        self.assertIsNone(result['presented_fps'])
        self.assertIsNone(result['presentation_gap_max_ms'])

    def test_zero_timestamp_is_reported_drop_not_presentation(self):
        trace = self.presentation_trace()
        trace[-1]['time'] = 0
        result = measurement.summarize(trace)
        self.assertEqual(result['presentation_drops_reported'], 1)
        self.assertEqual(result['presented_frames'], 1)
        self.assertEqual(result['presented_fps'], 1)
        self.assertEqual(result['presentation_gap_max_ms'], 950)

    def test_all_zero_timestamps_are_unavailable_not_zero_fps_or_all_drops(self):
        trace = self.presentation_trace()
        trace[-1]['time'] = trace[-2]['time'] = 0
        result = measurement.summarize(trace)
        self.assertIn('unavailable', result['presentation_measurement'])
        self.assertEqual(result['presentation_zero_timestamps'], 2)
        self.assertIsNone(result['presentation_drops_reported'])
        self.assertIsNone(result['presented_frames'])
        self.assertIsNone(result['presented_fps'])
        self.assertIsNone(result['presentation_gap_max_ms'])

    def test_duplicate_callback_rejected_and_wrong_surface_ignored(self):
        trace = self.presentation_trace()
        trace.append(dict(trace[-1], surface=2))
        self.assertEqual(measurement.summarize(trace)['presented_frames'], 2)
        trace.append(dict(trace[-2]))
        with self.assertRaises(ValueError): measurement.summarize(trace)

    def test_late_presentation_is_covered_but_not_counted_in_window(self):
        trace = self.presentation_trace()
        trace[-2]['time'] = 1.05
        result = measurement.summarize(trace)
        self.assertEqual(result['presentation_measurement'], 'complete')
        self.assertEqual(result['presentations_outside_window'], 1)
        self.assertEqual(result['presented_fps'], 1)

    def test_submission_only_trace_never_claims_actual_fps(self):
        result = measurement.summarize(self.trace())
        self.assertIn('unavailable', result['presentation_measurement'])
        self.assertNotIn('presented_fps', result)


if __name__ == '__main__': unittest.main()
