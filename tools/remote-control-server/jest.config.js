export default {
    preset: "ts-jest",
    testEnvironment: "node",
    modulePathIgnorePatterns: [
        "dist",
    ],
    testMatch: [
        "**/src/**/*.test.ts",
    ],
    testPathIgnorePatterns: [
        "/node_modules/",
        "/dist/",
    ],
};
