// Offline generator after the exact oracle has been installed under build/.
// npm install --prefix build/dependency-audit/reference --ignore-scripts --no-audit --no-fund --save-exact ts-fsrs@5.4.2
// node scripts/generate_fsrs_fixture.cjs > Packages/CardsKit/Tests/CardsInfrastructureTests/Fixtures/fsrs6-reference.json
const { fsrs, createEmptyCard, Rating } = require('../build/dependency-audit/reference/node_modules/ts-fsrs');
const metadata = require('../build/dependency-audit/reference/node_modules/ts-fsrs/package.json');
if (metadata.version !== '5.4.2') throw new Error('Expected ts-fsrs 5.4.2');
const integrity = 'sha512-z4qop4pzTcyTzuJ566d9EaX/4bZZzhYfeaPImfVr+xcYT65c5oBgFDijUhCE/D+C78eaolHIhKRZ04/RwF+v2g==';
const lock = require('../build/dependency-audit/reference/package-lock.json');
if (lock.packages['node_modules/ts-fsrs'].integrity !== integrity) throw new Error('Oracle integrity mismatch');
const parameters = {
  request_retention: 0.9, maximum_interval: 36500,
  w: [0.212,1.2931,2.3065,8.2956,6.4133,0.8334,3.0194,0.001,1.8722,0.1666,0.796,1.4835,0.0614,0.2629,1.6483,0.6014,1.8729,0.5425,0.0912,0.0658,0.1542],
  enable_fuzz: false, enable_short_term: true,
  learning_steps: ['1m', '10m'], relearning_steps: ['10m'],
};
const scheduler = fsrs(parameters);
const now = new Date('2025-01-01T12:00:00Z');
const newCard = createEmptyCard(now);
const learning = scheduler.next(newCard, now, Rating.Good).card;
const review = scheduler.next(newCard, now, Rating.Easy).card;
const relearning = scheduler.next(review, review.due, Rating.Again).card;
const cases = [
  ['new', newCard, now],
  ['learning', learning, learning.due],
  ['review', review, review.due],
  ['relearning', relearning, relearning.due],
  ['overdue', review, new Date(review.due.getTime() + 30 * 86400000)],
  ['learning-step-zero', scheduler.next(newCard, now, Rating.Again).card, new Date(now.getTime() + 60000)],
  ['same-day-review', review, new Date(now.getTime() + 600000)],
  ['utc-midnight-review', review, new Date('2025-01-02T00:00:00Z')],
  ['overdue-relearning', relearning, new Date(relearning.due.getTime() + 3 * 86400000)],
];
function snapshot(card) {
  return { ...card, due: card.due.getTime()/1000,
    last_review: card.last_review ? card.last_review.getTime()/1000 : null };
}
console.log(JSON.stringify({
  oracle: { package: 'ts-fsrs', version: '5.4.2',
    revision: 'bb71e35a2f5af5a5ac6cce9ef7c41ad24855721d',
    integrity },
  parameters,
  cases: cases.map(([name, card, time]) => ({name, input: snapshot(card), now: time.getTime()/1000,
    outputs: [1,2,3,4].map(rating => ({ rating, card: snapshot(scheduler.next(card, time, rating).card) }))})),
}, null, 2));
