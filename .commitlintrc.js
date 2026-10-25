/**
 * Custom commitlint config. Change TEMPLATE to your own ticket prefix.
 * Expected format: [TEMPLATE-{number}] {type}: {description}
 * Example: [TEMPLATE-42] fix: resolve hover flicker on subsection cards
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
        /^\[TEMPLATE-\d+\]\s+(feat|fix|chore|docs|refactor|test|style|perf|ci):\s+.+$/,
      headerCorrespondence: [],
    },
  },
  plugins: [
    {
      rules: {
        'sean-format': (parsed) => {
          const { header } = parsed;
          const pattern =
            /^\[TEMPLATE-\d+\]\s+(feat|fix|chore|docs|refactor|test|style|perf|ci):\s+.+$/;
          if (!header || !pattern.test(header)) {
            return [
              false,
              `Commit message must match: [TEMPLATE-N] type: description\nValid types: ${VALID_TYPES.join(', ')}\nExample: [TEMPLATE-42] fix: resolve hover flicker`,
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
