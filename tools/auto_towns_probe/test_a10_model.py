import unittest

from run import model_a10_observation, rects_touch


def trace():
    pos = {'x': -192, 'y': -32, 'z': 128}
    target = {'x': -512, 'y': -32, 'z': 448}
    return [
        {'kind': 'wt_a10_geometry', 'fixture_version': 1},
        {'kind': 'wt_a10_surface', 'site': 's', 'minp': pos, 'valid': 1, 'site_state': 'inspecting'},
        {'kind': 'wt_planner', 'state': 'enter', 'minp': pos},
        {'kind': 'wt_a10_planner', 'state': 'entry', 'site': {'id': 's',
         'center': {'x': -510, 'z': 517},
         'activation_rect': {'x1': -933, 'z1': 94, 'x2': -87, 'z2': 940}}, 'minp': pos,
         'fresh_state': 'inspecting'},
        {'kind': 'wt_a10_planner', 'state': 'declined', 'site': 's', 'inactive_after': 'declined'},
        {'kind': 'wt_a10_competing', 'state': 'request', 'site': 's', 'minp': target},
        {'kind': 'wt_request', 'minp': {'x': -510, 'z': 517}},
        {'kind': 'wt_planner', 'state': 'exit'},
        {'kind': 'wt_a10_competing', 'state': 'callback', 'site': 's', 'minp': target,
         'maxp': {'x': -433, 'y': 47, 'z': 527}, 'valid': 1,
         'before': 'declined', 'after': 'declined', 'activations': 0},
        {'kind': 'wt_generated', 'minp': target},
    ]


class ModelA10Tests(unittest.TestCase):
    def test_inclusive_boundaries_and_one_node_near_misses(self):
        r = {'x1': -423, 'x2': 423, 'z1': -423, 'z2': 423}
        for x, z, expected in [(-423, 0, True), (423, 0, True), (0, -423, True), (0, 423, True),
                               (-424, 0, False), (424, 0, False), (0, -424, False), (0, 424, False)]:
            self.assertEqual(rects_touch(r, {'x1': x, 'x2': x, 'z1': z, 'z2': z}), expected)

    def test_complete_after_exit_is_still_inconclusive(self):
        out = model_a10_observation(trace())
        self.assertTrue(out['complete'])
        self.assertEqual(out['callback_relation'], 'after_planner')
        self.assertEqual(out['evidence_status'], 'inconclusive')

    def test_during_planner_is_classified(self):
        events = trace()
        events[7], events[8] = events[8], events[7]
        self.assertEqual(model_a10_observation(events)['callback_relation'], 'during_planner')

    def test_missing_trigger_or_callback_fails(self):
        for index in (1, 8):
            events = trace(); events.pop(index)
            self.assertFalse(model_a10_observation(events)['complete'])

    def test_wrong_decline_or_callback_fails(self):
        for key, value in [('before', 'contacted'), ('after', 'inspecting'), ('activations', 1)]:
            events = trace(); events[-2][key] = value
            self.assertFalse(model_a10_observation(events)['complete'])

    def test_decline_after_request_fails(self):
        events = trace(); events[4], events[5] = events[5], events[4]
        self.assertFalse(model_a10_observation(events)['complete'])

    def test_wrong_trigger_fails(self):
        events = trace(); events[1]['minp'] = {'x': 1}
        self.assertFalse(model_a10_observation(events)['complete'])

    def test_earlier_request_and_malformed_events_fail_closed(self):
        events = trace(); events.insert(4, {'kind': 'wt_request', 'minp': {'x': 0, 'z': 0}})
        self.assertFalse(model_a10_observation(events)['complete'])
        events = trace(); del events[3]['site']['activation_rect']
        self.assertFalse(model_a10_observation(events)['complete'])


if __name__ == '__main__':
    unittest.main()
