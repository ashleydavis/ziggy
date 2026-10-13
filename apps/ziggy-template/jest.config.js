export default {
    preset: 'ts-jest',
    modulePathIgnorePatterns: [
        "<rootDir>/dist/",
        "<rootDir>/build/",
        // The dev mode smoke tests copy the app into tmp while they run, and its tests are not this app's.
        "<rootDir>/tmp/",
    ],
};
