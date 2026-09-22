/**
 * Compatibility entry point for operators or imports using the historical
 * helper name. New automation should use write-world-features.ts.
 */
import * as path from "node:path";
import { pathToFileURL } from "node:url";

export * from "./write-world-features";
import { writeWorldFeatureManifest } from "./write-world-features";

if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) {
    writeWorldFeatureManifest();
}
