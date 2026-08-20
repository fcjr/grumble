-- Builds a demo-only meetings database for App Store screenshots. The real
-- database must never be listed in a public screenshot, so this wipes every
-- meeting and seeds invented ones instead. Run it against a COPY, then swap
-- the copy in; see README.md.

DELETE FROM segments;
DELETE FROM speakers;
DELETE FROM meetings;

INSERT INTO meetings (id, startedAt, endedAt, sourceBundleId, title, summary, audioDir, state, createdAt, updatedAt) VALUES
 (9001, '2026-08-18 10:00:00.000', '2026-08-18 10:04:12.000', 'us.zoom.xos', 'Onboarding Flow Review',
  'The team moved the permission prompt to after the first dictation, which cut onboarding drop-off from 40% to 12%. Open items: banner copy that says what a declined permission actually breaks, and menu bar progress for the first-launch model download. Sam has a build ready tomorrow afternoon.',
  '2026-08-18T14-00-00Z-demo', 'done', '2026-08-18 10:00:00.000', '2026-08-18 10:04:20.000'),
 (9002, '2026-08-17 15:30:00.000', '2026-08-17 16:12:40.000', 'us.zoom.xos', 'Weekly Design Sync',
  'Walked the new empty states and settled on one illustration style across the app.',
  '2026-08-17T15-30-00Z-demo', 'done', '2026-08-17 15:30:00.000', '2026-08-17 16:13:00.000'),
 (9003, '2026-08-17 09:15:00.000', '2026-08-17 09:41:05.000', 'com.microsoft.teams2', 'Support Triage',
  'Cleared the weekend queue. Two reports of the hotkey being claimed by another app, both resolved by rebinding.',
  '2026-08-17T09-15-00Z-demo', 'done', '2026-08-17 09:15:00.000', '2026-08-17 09:41:30.000'),
 (9004, '2026-08-14 13:00:00.000', '2026-08-14 14:02:18.000', 'us.zoom.xos', 'Sprint Planning',
  'Committed to the transcript search work and pushed the export format to next cycle.',
  '2026-08-14T13-00-00Z-demo', 'done', '2026-08-14 13:00:00.000', '2026-08-14 14:02:40.000'),
 (9005, '2026-08-12 11:00:00.000', '2026-08-12 11:35:52.000', 'com.apple.FaceTime', 'Roadmap Check-in',
  'Agreed to hold the release until the onboarding numbers come back from the test build.',
  '2026-08-12T11-00-00Z-demo', 'done', '2026-08-12 11:00:00.000', '2026-08-12 11:36:10.000'),
 (9006, '2026-08-11 16:45:00.000', '2026-08-11 17:09:31.000', 'com.tinyspeck.slackmacgap', 'Docs Review',
  'Rewrote the permissions page around what breaks without each grant rather than how to enable it.',
  '2026-08-11T16-45-00Z-demo', 'done', '2026-08-11 16:45:00.000', '2026-08-11 17:09:50.000');

INSERT INTO speakers (id, meetingId, slot, displayName, namedBy) VALUES
 (9001, 9001, 'me',   'You',    'auto'),
 (9002, 9001, 'spk0', 'Sam',    'auto'),
 (9003, 9001, 'spk1', 'Jordan', 'auto');

INSERT INTO segments (meetingId, speakerId, startMs, endMs, text) VALUES
 (9001, 9001,   1200,  10400, 'Let''s start with the onboarding flow. Where did we land on the permission step?'),
 (9001, 9002,  11100,  22600, 'We moved it to after the first dictation, so people see the thing work before macOS asks them for anything.'),
 (9001, 9003,  23400,  32900, 'Drop-off went from about forty percent down to twelve in the test build.'),
 (9001, 9001,  33600,  41200, 'That is a big jump. Did we check what happens when someone declines?'),
 (9001, 9002,  42000,  53800, 'There is a banner now, and clicking it opens the right settings pane directly instead of the top level.'),
 (9001, 9003,  54600,  66100, 'I would like the banner copy to say what actually breaks, not just that a permission is missing.'),
 (9001, 9001,  66900,  75300, 'Agreed. Write it as one sentence and we will review it on Thursday.'),
 (9001, 9002,  76200,  86400, 'The other open question is the speech model download on first launch.'),
 (9001, 9003,  87100,  98900, 'It is around six hundred megabytes, so we should show the progress somewhere people can see it.'),
 (9001, 9001,  99700, 108200, 'Put it in the menu bar, and let people keep working while it finishes.'),
 (9001, 9002, 109000, 117600, 'I can have a build for you tomorrow afternoon.'),
 (9001, 9001, 118300, 126800, 'Perfect. Let us pick the rest up after the release goes out.');
