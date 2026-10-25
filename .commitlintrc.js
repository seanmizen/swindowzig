/**
 * Custom commitlint config. Change the ticket prefix.
 * Expected format: [SWZ-{number}] {type}: {description}
 * Example: [SWZ-42] fix: resolve hover flicker on subsection cards
 */

const VALID_TYPES = [
  'feat',
  'fix',
  'chore',
  'docs',
  'refactor',
  'test',
  'style',
  'perf',
  'ci',
];

export default {
  parserPreset: {
    parserOpts: {
      headerPattern:
        /^\[SWZ-\d+\]\s+(feat|fix|chore|docs|refactor|test|style|perf|ci):\s+.+$/,
      headerCorrespondence: [],
    },
  },
  plugins: [
    {
      rules: {
        'sean-format': (parsed) => {
          const { header } = parsed;
          const pattern =
            /^\[SWZ-\d+\]\s+(feat|fix|chore|docs|refactor|test|style|perf|ci):\s+.+$/;
          if (!header || !pattern.test(header)) {
            return [
              false,
              `Commit message must match: [SWZ-N] type: description\nValid types: ${VALID_TYPES.join(', ')}\nExample: [SWZ-42] fix: resolve hover flicker`,
            ];
          }
          return [true];
        },
      },
    },
  ],
  rules: {
    'sean-format': [2, 'always'],
  },
};
