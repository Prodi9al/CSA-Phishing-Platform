import js from "@eslint/js";

export default [
    js.configs.recommended,
    {
        files: ["relay.js"],
        languageOptions: {
            globals: {
                require: "readonly",
                process: "readonly",
                __dirname: "readonly",
                console: "readonly",
                URL: "readonly",
                fetch: "readonly",
                setTimeout: "readonly",
                Date: "readonly",
                Map: "readonly",
                Set: "readonly",
                JSON: "readonly"
            }
        },
        rules: {
            "no-unused-vars": "warn",
            "no-undef": "warn"
        }
    }
];