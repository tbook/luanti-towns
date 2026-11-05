"""Focused checks for controlled A10 event validation."""
import unittest

from run import controlled_a10_observation, inactive_trigger_a10_observation


def complete_events(callback_ms=30):
    site = {'x': -192, 'y': -32, 'z': 128}
    target = {'x': 10000, 'y': 0, 'z': 10000}
    chunk = {'x': 9968, 'y': -32, 'z': 9968}
    request = 'r12'
    return [
        {'kind': 'wt_synthetic', 'state': 'reserve', 'minp': site, 't_ms': 5},
        {'kind': 'wt_planner', 'state': 'enter', 'minp': site, 't_ms': 10},
        {'kind': 'wt_synthetic', 'state': 'planner_entry', 'reserved': True,
         'minp': site, 't_ms': 10},
        {'kind': 'wt_control', 'state': 'request', 't_ms': 10},
        {'kind': 'wt_request', 'minp': target, 'maxp': target,
         'request': request, 't_ms': 10},
        {'kind': 'wt_control', 'state': 'wait_end', 't_ms': 13},
        {'kind': 'wt_planner', 'state': 'exit', 't_ms': 29},
        {'kind': 'wt_generated', 'minp': chunk, 't_ms': callback_ms},
        {'kind': 'wt_emerge', 'action': 'generated', 'block': {'x': 625, 'y': 0, 'z': 625},
         'request': request, 't_ms': callback_ms},
    ]


def inactive_trigger_events():
    pos = {'x': -192, 'y': -32, 'z': 128}
    return [
        {'kind': 'wt_test', 'state': 'before_forceload', 'pos': pos,
         'node': 'mcl_villages:structblock', 't_ms': 10},
        {'kind': 'wt_test', 'state': 'forceload', 'pos': pos,
         'single_block': True, 'ok': True, 't_ms': 10},
        {'kind': 'wt_planner', 'state': 'enter', 'minp': pos, 't_ms': 11},
        {'kind': 'wt_planner', 'state': 'exit', 'planned': True, 't_ms': 30},
    ]


class ControlledA10ObservationTests(unittest.TestCase):
    def test_empty_event_stream_is_incomplete(self):
        observation = controlled_a10_observation([])
        self.assertEqual(observation['instrumentation_status'], 'incomplete')
        self.assertFalse(observation['required_events_observed_in_order'])
        self.assertIn('synthetic reservation marker', observation['missing_or_invalid'])

    def test_complete_fixture_reports_after_planner_and_keeps_a10_inconclusive(self):
        observation = controlled_a10_observation(complete_events())
        self.assertEqual(observation['instrumentation_status'], 'complete')
        self.assertEqual(observation['callback_relation'], 'after_planner')
        self.assertTrue(observation['required_events_observed_in_order'])
        self.assertEqual(observation['evidence_status'], 'inconclusive')

    def test_missing_generated_callback_is_incomplete(self):
        events = [e for e in complete_events() if e['kind'] != 'wt_generated']
        observation = controlled_a10_observation(events)
        self.assertEqual(observation['instrumentation_status'], 'incomplete')
        self.assertFalse(observation['required_events_observed_in_order'])
        self.assertIn('competing generated-chunk callback', observation['missing_or_invalid'])

    def test_competing_callback_during_planner_is_classified(self):
        observation = controlled_a10_observation(complete_events(callback_ms=20))
        self.assertTrue(observation['required_events_observed_in_order'])
        self.assertEqual(observation['callback_relation'], 'during_planner')

    def test_reservation_after_planner_entry_fails_order_check(self):
        events = complete_events()
        events[0]['t_ms'] = 11
        observation = controlled_a10_observation(events)
        self.assertEqual(observation['instrumentation_status'], 'incomplete')
        self.assertIn('timestamps in reservation/request/callback order', observation['missing_or_invalid'])


class InactiveTriggerA10ObservationTests(unittest.TestCase):
    def test_structblock_single_forceload_and_matching_planner_pass(self):
        observation = inactive_trigger_a10_observation(inactive_trigger_events())
        self.assertEqual(observation['instrumentation_status'], 'complete')
        self.assertTrue(observation['required_events_observed_in_order'])
        self.assertEqual(observation['evidence_status'], 'inconclusive')

    def test_missing_structblock_fails_inconclusive(self):
        events = inactive_trigger_events()
        events[0]['node'] = 'air'
        observation = inactive_trigger_a10_observation(events)
        self.assertEqual(observation['instrumentation_status'], 'incomplete')
        self.assertFalse(observation['required_events_observed_in_order'])
        self.assertIn('expected structblock at trigger position before forceload', observation['missing_or_invalid'])

    def test_no_matching_planner_entry_fails(self):
        events = inactive_trigger_events()
        events[2]['minp'] = {'x': -112, 'y': -32, 'z': 128}
        observation = inactive_trigger_a10_observation(events)
        self.assertIn('exactly one planner entry matching trigger chunk', observation['missing_or_invalid'])

    def test_multiple_forceloads_fail_single_block_contract(self):
        events = inactive_trigger_events()
        events.append(dict(events[1]))
        observation = inactive_trigger_a10_observation(events)
        self.assertIn('exactly one single-block forceload event', observation['missing_or_invalid'])

    def test_failed_forceload_is_incomplete(self):
        events = inactive_trigger_events()
        events[1]['ok'] = False
        observation = inactive_trigger_a10_observation(events)
        self.assertIn('successful single-block forceload at trigger position', observation['missing_or_invalid'])


if __name__ == '__main__':
    unittest.main()
